#include "pkgarchive.h"
#include "util.h"
#include "paths.h"
#include "rootfs.h"
#include <iostream>
#include <memory>
#include <vector>
#include <climits>
#include <sys/stat.h>
#include <unistd.h>
#include <archive.h>
#include <archive_entry.h>

#define DEFAULT_BYTES_PER_BLOCK (20 * 512)

namespace {

struct archive_closer {
	void operator()(struct archive* a) const { archive_read_free(a); }
};
typedef unique_ptr<struct archive, archive_closer> archive_ptr;

archive_ptr open_archive(const string& filename)
{
	archive_ptr ar(archive_read_new());
	struct archive* a = ar.get();

	archive_read_support_filter_gzip(a);
	archive_read_support_filter_bzip2(a);
	archive_read_support_filter_xz(a);
	archive_read_support_filter_lzip(a);
	archive_read_support_filter_zstd(a);
	archive_read_support_filter_lz4(a);
	archive_read_support_filter_lzma(a);
	archive_read_support_format_tar(a);

	if (archive_read_open_filename(a, filename.c_str(), DEFAULT_BYTES_PER_BLOCK) != ARCHIVE_OK)
		throw runtime_error("could not open " + filename + ": " + archive_error_string(a));

	return ar;
}

// Turns a member path into the form stored in the database: no leading "./",
// no "." components or repeated slashes, directories end in '/'. Returns ""
// for the archive root ("." or "./"). Throws for paths that would escape the
// installation root, contain control characters (the database is line based)
// or point into the package database itself.
string normalize(const string& path, bool is_dir)
{
	for (string::size_type i = 0; i < path.size(); i++)
		if ((unsigned char)path[i] < 0x20 || path[i] == 0x7f)
			throw runtime_error("refusing path with control characters in package");

	if (path.empty() || path[0] == '/')
		throw runtime_error("refusing unsafe path in package: '" + path + "'");

	string p;
	vector<string> parts = split(path, "/");
	for (size_t i = 0; i < parts.size(); i++) {
		if (parts[i] == "..")
			throw runtime_error("refusing unsafe path in package: '" + path + "'");
		if (parts[i] == ".")
			continue;
		// split() trims blanks, so check the raw component is not blank-padded
		p += (p.empty() ? "" : "/") + parts[i];
	}

	if (p.empty())
		return "";

	if (p == DB_DIR || starts_with(p, DB_DIR "/") || p == STATE_DIR || starts_with(p, STATE_DIR "/"))
		throw runtime_error("refusing path inside the package database: '" + path + "'");

	if (is_dir)
		p += '/';

	return p;
}

string read_entry_data(struct archive* a, const string& filename)
{
	string data;
	char buf[4096];
	la_ssize_t n;

	while ((n = archive_read_data(a, buf, sizeof(buf))) > 0) {
		data.append(buf, n);
		if (data.size() > 1024 * 1024)
			throw runtime_error("metadata of " + filename + " is too large");
	}
	if (n < 0)
		throw runtime_error("could not read " + filename + ": " + archive_error_string(a));

	return data;
}

} // namespace

package_t pkg_open(const string& filename)
{
	package_t result;
	result.bytes = 0;
	result.entries = 0;
	archive_ptr ar = open_archive(filename);
	struct archive* a = ar.get();
	struct archive_entry* entry;
	bool have_meta = false;
	unsigned int i = 0;

	for (; archive_read_next_header(a, &entry) == ARCHIVE_OK; ++i) {
		mode_t mode = archive_entry_mode(entry);
		string name = normalize(archive_entry_pathname(entry), S_ISDIR(mode));

		if (name == META_FILE) {
			result.meta = parse_meta(read_entry_data(a, filename));
			have_meta = true;
			continue;
		}

		if (!name.empty())
			result.files.insert(result.files.end(), name);

		result.entries++;
		if (S_ISREG(mode) && archive_entry_size_is_set(entry) && archive_entry_size(entry) > 0)
			result.bytes += (unsigned long long)archive_entry_size(entry);

		if (S_ISREG(mode) && archive_read_data_skip(a) != ARCHIVE_OK)
			throw runtime_error("could not read " + filename + ": " + archive_error_string(a));
	}

	if (i == 0) {
		if (archive_errno(a) == 0)
			throw runtime_error("empty package " + filename);
		else
			throw runtime_error("could not read " + filename + ": " + archive_error_string(a));
	}
	if (archive_errno(a) != 0 && archive_errno(a) != ARCHIVE_EOF)
		throw runtime_error("could not read " + filename + ": " + archive_error_string(a));

	if (!have_meta)
		throw runtime_error(filename + " is not a tatami package (no " META_FILE " member)");

	try {
		result.meta.filename = "";
		result.meta.reason = "";        // decided by tatami, never by the package
		validate_meta(result.meta);
	} catch (runtime_error& e) {
		throw runtime_error(filename + ": " + e.what());
	}

	if (result.files.empty())
		throw runtime_error("package " + filename + " contains no files");

	return result;
}

pkgmeta pkg_read_meta(const string& filename)
{
	archive_ptr ar = open_archive(filename);
	struct archive* a = ar.get();
	struct archive_entry* entry;

	while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
		mode_t mode = archive_entry_mode(entry);
		string name = normalize(archive_entry_pathname(entry), S_ISDIR(mode));

		if (name == META_FILE) {
			pkgmeta meta = parse_meta(read_entry_data(a, filename));
			meta.filename = "";
			meta.reason = "";
			validate_meta(meta);
			return meta;
		}

		if (S_ISREG(mode) && archive_read_data_skip(a) != ARCHIVE_OK)
			throw runtime_error("could not read " + filename + ": " + archive_error_string(a));
	}

	throw runtime_error(filename + " is not a tatami package (no " META_FILE " member)");
}

// Records what extracting 'path' is going to change, before it happens.
static void prepare_target(txn& tx, const string& absroot, const string& entry_path, mode_t entry_mode)
{
	string path = entry_path;
	while (path.size() > 1 && path[path.size() - 1] == '/')
		path.erase(path.size() - 1);

	// Parent directories that do not exist yet are created by libarchive
	vector<string> missing;
	string dir = path;
	for (;;) {
		string::size_type slash = dir.rfind('/');
		if (slash == string::npos)
			break;
		dir.erase(slash);
		if (dir.size() <= absroot.size() || file_exists(dir))
			break;
		missing.push_back(dir);
	}
	for (vector<string>::reverse_iterator i = missing.rbegin(); i != missing.rend(); ++i)
		tx.created(*i);

	struct stat st;
	if (lstat(path.c_str(), &st) == -1) {
		tx.created(path);
		return;
	}

	if (S_ISLNK(st.st_mode) && S_ISDIR(entry_mode)) {
		// A symbolic link to a directory (/lib -> usr/lib) is accepted by libarchive
		// as the directory: it stays a link, and the directory behind it is what
		// the extraction may touch.
		struct stat target;
		if (stat(path.c_str(), &target) == 0 && S_ISDIR(target.st_mode)) {
			tx.dir_meta(path, target);
			return;
		}
	}

	if (S_ISDIR(st.st_mode)) {
		// An existing directory stays; only its mode and owner may change.
		// A directory where a file is to be written is left to libarchive,
		// which refuses it, and that fails the installation.
		if (S_ISDIR(entry_mode))
			tx.dir_meta(path, st);
		return;
	}

	tx.backup(path);        // replaced: keep the original for a rollback
}

void pkg_install(const string& utilname, const string& root, const string& filename,
		 const set<string>& config_list, const set<string>& non_install_list,
		 txn& tx)
{
	archive_ptr ar = open_archive(filename);
	struct archive* a = ar.get();
	struct archive_entry* entry;
	unsigned int i = 0;
	int r;

	// Absolute root without trailing slash ("" for "/")
	string absroot = root;
	while (!absroot.empty() && absroot[absroot.size() - 1] == '/')
		absroot.erase(absroot.size() - 1);

	// Every destination is worked out with root_resolve(): symbolic links in the
	// root (a usr-merged /lib -> usr/lib, even an absolute one) are followed
	// inside the root, never to the host, so nothing is written outside of it.
	// The extraction itself then only sees paths without links in their parents.

	for (; (r = archive_read_next_header(a, &entry)) == ARCHIVE_OK || r == ARCHIVE_WARN; ++i) {
		mode_t mode = archive_entry_mode(entry);
		const string archive_filename = normalize(archive_entry_pathname(entry), S_ISDIR(mode));

		if (archive_filename.empty())
			continue;	// archive root

		if (archive_filename == META_FILE) {
			archive_read_data_skip(a);
			continue;
		}

		const string original_filename = root_resolve(absroot, archive_filename);
		string real_filename = original_filename;

		// Check if file is filtered out via INSTALL rules
		if (non_install_list.find(archive_filename) != non_install_list.end()) {
			cout << utilname << ": ignoring " << archive_filename << endl;
			if (S_ISREG(mode))
				archive_read_data_skip(a);
			continue;
		}

		// A configuration file (UPGRADE rule saying NO) that exists already and is a
		// regular file: the new version is extracted next to it first. If it is
		// identical it is dropped; otherwise the existing file becomes <file>.old
		// and the new one takes its place.
		struct stat est;
		const bool config_file = S_ISREG(mode) && config_list.find(archive_filename) != config_list.end() &&
					 lstat(original_filename.c_str(), &est) == 0 && S_ISREG(est.st_mode);
		const string extract_to = config_file ? original_filename + ".tatami-new." + itos(getpid()) : original_filename;

		prepare_target(tx, absroot, extract_to, mode);

		archive_entry_set_pathname(entry, extract_to.c_str());

		// Hard link targets are paths inside the root too
		const char* hardlink = archive_entry_hardlink(entry);
		if (hardlink)
			archive_entry_set_hardlink(entry, root_resolve(absroot, normalize(hardlink, false)).c_str());

		// Extract file
		int flags = ARCHIVE_EXTRACT_OWNER | ARCHIVE_EXTRACT_PERM |
			    ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_UNLINK;

		if (archive_read_extract(a, entry, flags) != ARCHIVE_OK) {
			const char* msg = archive_error_string(a);
			throw runtime_error("could not install " + archive_filename + ": " + (msg ? msg : "unknown error"));
		}

		if (config_file) {
			if (permissions_equal(extract_to, original_filename) &&
			    (file_empty(extract_to) ? file_empty(original_filename) : file_equal(extract_to, original_filename))) {
				// nothing changed: the existing file stays as it is
				unlink(extract_to.c_str());
				continue;
			}

			// The previous .old file, if any, is replaced; a rollback brings it back
			const string old = original_filename + ".old";
			struct stat ost;
			if (lstat(old.c_str(), &ost) == 0)
				tx.backup(old);
			tx.save_old(original_filename);
			tx.created(original_filename);
			if (rename(extract_to.c_str(), original_filename.c_str()) == -1)
				throw runtime_error_with_errno("could not install " + archive_filename);
			cout << utilname << ": " << archive_filename << " differs from the existing file, "
			     << "which was saved as " << archive_filename << ".old" << endl;
		}
	}

	// The loop ends at the end of the archive (ARCHIVE_EOF); anything else is
	// a corrupt or truncated archive and must not count as a finished install
	if (r != ARCHIVE_EOF) {
		const char* msg = archive_error_string(a);
		throw runtime_error("could not read " + filename + ": " + (msg ? msg : "corrupt archive"));
	}

	if (i == 0)
		throw runtime_error("empty package");
}
