#include "pack.h"
#include "meta.h"
#include "util.h"
#include <algorithm>
#include <iostream>
#include <map>
#include <memory>
#include <vector>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <archive.h>
#include <archive_entry.h>

namespace {

struct writer_closer {
	void operator()(struct archive* a) const { archive_write_free(a); }
};
struct disk_closer {
	void operator()(struct archive* a) const { archive_read_free(a); }
};
struct entry_closer {
	void operator()(struct archive_entry* e) const { archive_entry_free(e); }
};

void collect(const string& base, const string& rel, vector<string>& out)
{
	const string dir = rel.empty() ? base : base + "/" + rel;
	DIR* d = opendir(dir.c_str());
	if (!d)
		throw runtime_error_with_errno("could not read directory " + dir);

	vector<string> names;
	struct dirent* de;
	while ((de = readdir(d))) {
		const string n = de->d_name;
		if (n != "." && n != "..")
			names.push_back(n);
	}
	closedir(d);

	for (size_t i = 0; i < names.size(); i++) {
		const string r = rel.empty() ? names[i] : rel + "/" + names[i];
		struct stat st;
		if (lstat((base + "/" + r).c_str(), &st) == -1)
			throw runtime_error_with_errno("could not stat " + base + "/" + r);
		out.push_back(r);
		if (S_ISDIR(st.st_mode))
			collect(base, r, out);
	}
}

// Option string for a compression module: a sensible, high level for each
const char* level_option(const string& comp)
{
	if (comp == "gz")   return "gzip:compression-level=9";
	if (comp == "zst")  return "zstd:compression-level=19";
	if (comp == "xz")   return "xz:compression-level=6";
	if (comp == "lzma") return "lzma:compression-level=6";
	if (comp == "bz2")  return "bzip2:compression-level=9";
	if (comp == "lz4")  return "lz4:compression-level=9";
	return 0;
}

void add_filter(struct archive* a, const string& comp)
{
	int r;

	if (comp == "gz")        r = archive_write_add_filter_gzip(a);
	else if (comp == "zst")  r = archive_write_add_filter_zstd(a);
	else if (comp == "xz")   r = archive_write_add_filter_xz(a);
	else if (comp == "lzma") r = archive_write_add_filter_lzma(a);
	else if (comp == "bz2")  r = archive_write_add_filter_bzip2(a);
	else if (comp == "lz4")  r = archive_write_add_filter_lz4(a);
	else if (comp == "none") r = archive_write_add_filter_none(a);
	else
		throw runtime_error("unknown compression '" + comp + "' (use gz, zst, xz, bz2, lz4, lzma or none)");

	// Anything but a plain success means libarchive would hand the data to an
	// external program: that is not what a self-contained tatami does
	if (r != ARCHIVE_OK)
		throw runtime_error("this tatami was built without " + comp + " compression");

	if (level_option(comp))
		archive_write_set_options(a, level_option(comp));
}

void write_file_data(struct archive* a, const string& path)
{
	int fd = open(path.c_str(), O_RDONLY);
	if (fd == -1)
		throw runtime_error_with_errno("could not open " + path);

	char buf[65536];
	ssize_t n;
	while ((n = read(fd, buf, sizeof(buf))) > 0) {
		if (archive_write_data(a, buf, n) < 0) {
			close(fd);
			throw runtime_error(string("could not write the archive: ") + archive_error_string(a));
		}
	}
	int e = errno;
	close(fd);
	if (n < 0)
		throw runtime_error_with_errno("could not read " + path, e);
}

} // namespace

void pack_archive(const string& comp, const string& meta_file, const string& src, const string& output)
{
	unique_ptr<struct archive, writer_closer> out(archive_write_new());
	struct archive* a = out.get();

	add_filter(a, comp);
	archive_write_set_format_pax_restricted(a);
	if (archive_write_open_filename(a, output.c_str()) != ARCHIVE_OK)
		throw runtime_error("could not create " + output + ": " + archive_error_string(a));

	unique_ptr<struct archive, disk_closer> disk(archive_read_disk_new());

	// .META first, so that tatami can read it without scanning the archive
	{
		struct stat st;
		if (stat(meta_file.c_str(), &st) == -1)
			throw runtime_error_with_errno("could not read " + meta_file);

		unique_ptr<struct archive_entry, entry_closer> e(archive_entry_new());
		archive_entry_set_pathname(e.get(), META_FILE);
		archive_entry_set_filetype(e.get(), AE_IFREG);
		archive_entry_set_perm(e.get(), 0644);
		archive_entry_set_size(e.get(), st.st_size);
		archive_entry_set_mtime(e.get(), st.st_mtime, 0);
		archive_entry_set_uid(e.get(), 0);
		archive_entry_set_gid(e.get(), 0);
		if (archive_write_header(a, e.get()) != ARCHIVE_OK)
			throw runtime_error(string("could not write the archive: ") + archive_error_string(a));
		write_file_data(a, meta_file);
	}

	vector<string> paths;
	collect(src, "", paths);
	sort(paths.begin(), paths.end());

	map<pair<dev_t, ino_t>, string> hardlinks;

	for (size_t i = 0; i < paths.size(); i++) {
		const string full = src + "/" + paths[i];
		struct stat st;
		if (lstat(full.c_str(), &st) == -1)
			throw runtime_error_with_errno("could not stat " + full);

		if (paths[i] == META_FILE)
			continue;       // tatami writes its own

		if (S_ISSOCK(st.st_mode)) {
			cerr << "tatami: warning: skipping socket " << paths[i] << endl;
			continue;
		}

		unique_ptr<struct archive_entry, entry_closer> e(archive_entry_new());
		archive_entry_copy_sourcepath(e.get(), full.c_str());
		archive_entry_copy_pathname(e.get(), (paths[i] + (S_ISDIR(st.st_mode) ? "/" : "")).c_str());
		if (archive_read_disk_entry_from_file(disk.get(), e.get(), -1, &st) != ARCHIVE_OK)
			throw runtime_error("could not read " + full + ": " + archive_error_string(disk.get()));

		// numeric owners only: the build user's names mean nothing elsewhere
		archive_entry_set_uname(e.get(), "");
		archive_entry_set_gname(e.get(), "");

		bool data = S_ISREG(st.st_mode);
		if (data && st.st_nlink > 1) {
			const pair<dev_t, ino_t> id(st.st_dev, st.st_ino);
			map<pair<dev_t, ino_t>, string>::const_iterator f = hardlinks.find(id);
			if (f != hardlinks.end()) {
				archive_entry_set_hardlink(e.get(), f->second.c_str());
				archive_entry_set_size(e.get(), 0);
				data = false;
			} else {
				hardlinks[id] = paths[i];
			}
		}

		if (archive_write_header(a, e.get()) != ARCHIVE_OK)
			throw runtime_error(string("could not write the archive: ") + archive_error_string(a));
		if (data && st.st_size > 0)
			write_file_data(a, full);
	}

	if (archive_write_close(a) != ARCHIVE_OK)
		throw runtime_error(string("could not finish the archive: ") + archive_error_string(a));
}
