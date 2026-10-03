#include "pkgarchive.h"
#include "util.h"
#include "paths.h"
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

	if (p == PKG_DIR || starts_with(p, PKG_DIR "/"))
		throw runtime_error("refusing path inside the package database: '" + path + "'");

	if (is_dir)
		p += '/';

	return p;
}

// True if 'path' (below absroot) can be written without leaving the root
// through a symbolic link.
bool inside_root(const string& absroot, const string& path)
{
	if (absroot.empty())
		return true;	// the real root: nothing to escape from

	string cur = absroot;
	vector<string> parts = split(path.substr(absroot.size()), "/");

	// All components except the last one are directories we write through
	for (size_t i = 0; i + 1 < parts.size(); i++) {
		cur += "/" + parts[i];
		struct stat st;
		if (lstat(cur.c_str(), &st) == -1)
			return errno == ENOENT || errno == ENOTDIR;
		if (S_ISLNK(st.st_mode)) {
			char buf[PATH_MAX];
			if (!realpath(cur.c_str(), buf))
				return false;
			cur = buf;
			if (cur != absroot && !starts_with(cur, absroot + "/"))
				return false;
		}
	}

	return true;
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
		 const set<string>& keep_list, const set<string>& non_install_list,
		 txn& tx)
{
	archive_ptr ar = open_archive(filename);
	struct archive* a = ar.get();
	struct archive_entry* entry;
	unsigned int i = 0;
	int r;

	if (chdir(root.c_str()) == -1)
		throw runtime_error_with_errno("could not change directory to " + root);

	// Absolute root without trailing slash ("" for "/")
	string absroot = root;
	while (!absroot.empty() && absroot[absroot.size() - 1] == '/')
		absroot.erase(absroot.size() - 1);

	const string reject_dir = trim_filename(absroot + "/" + PKG_REJECTED);

	for (; (r = archive_read_next_header(a, &entry)) == ARCHIVE_OK || r == ARCHIVE_WARN; ++i) {
		mode_t mode = archive_entry_mode(entry);
		const string archive_filename = normalize(archive_entry_pathname(entry), S_ISDIR(mode));

		if (archive_filename.empty())
			continue;	// archive root

		if (archive_filename == META_FILE) {
			archive_read_data_skip(a);
			continue;
		}

		const string original_filename = trim_filename(absroot + "/" + archive_filename);
		string real_filename = original_filename;

		// Check if file is filtered out via INSTALL rules
		if (non_install_list.find(archive_filename) != non_install_list.end()) {
			cout << utilname << ": ignoring " << archive_filename << endl;
			if (S_ISREG(mode))
				archive_read_data_skip(a);
			continue;
		}

		// Check if file should be rejected
		if (file_exists(real_filename) && keep_list.find(archive_filename) != keep_list.end())
			real_filename = trim_filename(reject_dir + "/" + archive_filename);

		if (!inside_root(absroot, real_filename))
			throw runtime_error("refusing to install " + archive_filename +
					    ": it would be written outside of the installation root through a symbolic link");

		prepare_target(tx, absroot, real_filename, mode);

		archive_entry_set_pathname(entry, real_filename.c_str());

		// Hard links are resolved relative to the working directory (the root)
		const char* hardlink = archive_entry_hardlink(entry);
		if (hardlink)
			archive_entry_set_hardlink(entry, normalize(hardlink, false).c_str());

		// Extract file
		int flags = ARCHIVE_EXTRACT_OWNER | ARCHIVE_EXTRACT_PERM |
			    ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_UNLINK;

		if (archive_read_extract(a, entry, flags) != ARCHIVE_OK) {
			const char* msg = archive_error_string(a);
			throw runtime_error("could not install " + archive_filename + ": " + (msg ? msg : "unknown error"));
		}

		// Check rejected file
		if (real_filename != original_filename) {
			bool remove_file = false;

			if (S_ISDIR(mode))
				remove_file = permissions_equal(real_filename, original_filename);
			else
				remove_file = permissions_equal(real_filename, original_filename) &&
					(file_empty(real_filename) || file_equal(real_filename, original_filename));

			// Remove rejected file or signal about its existence
			if (remove_file)
				file_remove(reject_dir, real_filename);
			else
				cout << utilname << ": rejecting " << archive_filename << ", keeping existing version" << endl;
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
