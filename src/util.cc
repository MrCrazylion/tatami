#include "util.h"
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <climits>
#include <cctype>
#include <sys/stat.h>
#include <sys/param.h>
#include <unistd.h>
#include <libgen.h>

string trim(const string& s)
{
	const char* ws = " \t\r\n";
	string::size_type b = s.find_first_not_of(ws);
	if (b == string::npos)
		return "";
	string::size_type e = s.find_last_not_of(ws);
	return s.substr(b, e - b + 1);
}

string trim_filename(const string& filename)
{
	string search("//");
	string result = filename;

	for (string::size_type pos = result.find(search); pos != string::npos; pos = result.find(search))
		result.replace(pos, search.size(), "/");

	return result;
}

vector<string> split(const string& s, const string& delims)
{
	vector<string> result;
	string::size_type pos = 0;

	while (pos < s.size()) {
		string::size_type end = s.find_first_of(delims, pos);
		if (end == string::npos)
			end = s.size();
		string item = trim(s.substr(pos, end - pos));
		if (!item.empty())
			result.push_back(item);
		pos = end + 1;
	}

	return result;
}

bool starts_with(const string& s, const string& prefix)
{
	return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(const string& s, const string& suffix)
{
	return s.size() >= suffix.size() &&
		s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

string itos(unsigned long long value)
{
	return to_string(value);
}

vector<string> package_extensions(const string& configured)
{
	vector<string> exts;

	if (!configured.empty()) {
		exts.push_back(configured);
	} else {
		const char* comps[] = { "zst", "xz", "gz", "bz2", "lz4", "lzma" };
		for (size_t i = 0; i < sizeof(comps) / sizeof(comps[0]); i++)
			exts.push_back(string("tar.") + comps[i]);
	}

	return exts;
}

// Length of the extension the file name ends in, 0 if none matches
static size_t extension_length(const string& base, const vector<string>& exts)
{
	for (size_t i = 0; i < exts.size(); i++) {
		const string suffix = "." + exts[i];
		if (base.size() > suffix.size() && ends_with(base, suffix))
			return suffix.size();
	}
	return 0;
}

bool has_package_extension(const string& filename, const vector<string>& exts)
{
	return extension_length(filename, exts) != 0;
}

bool split_package_filename(const string& filename, const vector<string>& exts,
			    string& name, string& version, string& arch)
{
	string base = filename.substr(filename.rfind('/') == string::npos ? 0 : filename.rfind('/') + 1);

	const size_t ext = extension_length(base, exts);
	if (!ext)
		return false;
	base.erase(base.size() - ext);

	const string::size_type first = base.find('_');
	if (first == string::npos || first == 0)
		return false;
	const string::size_type second = base.find('_', first + 1);
	if (second == string::npos || second == first + 1 || second + 1 == base.size())
		return false;

	name = base.substr(0, first);
	version = base.substr(first + 1, second - first - 1);
	arch = base.substr(second + 1);
	return true;
}

string canonical_arch(const string& arch)
{
	string a = trim(arch);
	for (string::size_type i = 0; i < a.size(); i++)
		a[i] = tolower((unsigned char)a[i]);
	return (a == "noarch" || a == "all" || a == "any") ? "noarch" : trim(arch);
}

bool file_exists(const string& filename)
{
	struct stat buf;
	return !lstat(filename.c_str(), &buf);
}

bool file_empty(const string& filename)
{
	struct stat buf;

	if (lstat(filename.c_str(), &buf) == -1)
		return false;

	return (S_ISREG(buf.st_mode) && buf.st_size == 0);
}

bool file_equal(const string& file1, const string& file2)
{
	struct stat buf1, buf2;

	if (lstat(file1.c_str(), &buf1) == -1)
		return false;

	if (lstat(file2.c_str(), &buf2) == -1)
		return false;

	// Regular files
	if (S_ISREG(buf1.st_mode) && S_ISREG(buf2.st_mode)) {
		ifstream f1(file1.c_str(), ios::binary);
		ifstream f2(file2.c_str(), ios::binary);

		if (!f1 || !f2)
			return false;

		for (;;) {
			char buffer1[4096];
			char buffer2[4096];
			f1.read(buffer1, sizeof(buffer1));
			f2.read(buffer2, sizeof(buffer2));
			if (f1.gcount() != f2.gcount() ||
			    memcmp(buffer1, buffer2, f1.gcount()))
				return false;
			if (f1.eof() || f2.eof())
				return f1.eof() == f2.eof();
		}
	}
	// Symlinks
	else if (S_ISLNK(buf1.st_mode) && S_ISLNK(buf2.st_mode)) {
		char symlink1[MAXPATHLEN];
		char symlink2[MAXPATHLEN];

		memset(symlink1, 0, MAXPATHLEN);
		memset(symlink2, 0, MAXPATHLEN);

		if (readlink(file1.c_str(), symlink1, MAXPATHLEN - 1) == -1)
			return false;

		if (readlink(file2.c_str(), symlink2, MAXPATHLEN - 1) == -1)
			return false;

		return !strncmp(symlink1, symlink2, MAXPATHLEN);
	}
	// Character and block devices
	else if ((S_ISCHR(buf1.st_mode) && S_ISCHR(buf2.st_mode)) ||
	         (S_ISBLK(buf1.st_mode) && S_ISBLK(buf2.st_mode))) {
		return buf1.st_rdev == buf2.st_rdev;
	}

	return false;
}

bool permissions_equal(const string& file1, const string& file2)
{
	struct stat buf1;
	struct stat buf2;

	if (lstat(file1.c_str(), &buf1) == -1)
		return false;

	if (lstat(file2.c_str(), &buf2) == -1)
		return false;

	return (buf1.st_mode == buf2.st_mode) &&
		(buf1.st_uid == buf2.st_uid) &&
		(buf1.st_gid == buf2.st_gid);
}

void mkdir_p(const string& path, mode_t mode)
{
	string::size_type pos = 0;

	while (pos != string::npos) {
		pos = path.find('/', pos + 1);
		string part = path.substr(0, pos);
		if (part.empty())
			continue;
		if (mkdir(part.c_str(), mode) == -1 && errno != EEXIST)
			throw runtime_error_with_errno("could not create directory " + part);
	}

	struct stat buf;
	if (stat(path.c_str(), &buf) == -1 || !S_ISDIR(buf.st_mode))
		throw runtime_error(path + " is not a directory");
}

string real_path(const string& path)
{
	char buf[PATH_MAX];

	if (!realpath(path.c_str(), buf))
		throw runtime_error_with_errno("could not resolve " + path);

	return buf;
}
