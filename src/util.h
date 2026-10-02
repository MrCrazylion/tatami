//
//  tatami
//
//  Utility helpers shared by all modules. Several of these are carried over
//  from pkgutils (Copyright (c) 2000-2005 Per Liden, 2006-2021 CRUX team).
//

#ifndef UTIL_H
#define UTIL_H

#include <string>
#include <vector>
#include <stdexcept>
#include <cerrno>
#include <cstring>
#include <sys/types.h>

using namespace std;

class runtime_error_with_errno : public runtime_error {
public:
	explicit runtime_error_with_errno(const string& msg)
		: runtime_error(msg + string(": ") + strerror(errno)) {}
	explicit runtime_error_with_errno(const string& msg, int e)
		: runtime_error(msg + string(": ") + strerror(e)) {}
};

string trim(const string& s);
string trim_filename(const string& filename);
vector<string> split(const string& s, const string& delims);
bool starts_with(const string& s, const string& prefix);
bool ends_with(const string& s, const string& suffix);
string itos(unsigned long long value);

// Splits "<dir>/<name>_<version>.<ext>" at the last '_' before the extension
// (names and versions may not contain '_', so this is unambiguous). Returns
// false if the file name does not have that form.
bool split_package_filename(const string& filename, const string& ext,
			    string& name, string& version);

bool file_exists(const string& filename);
bool file_empty(const string& filename);
bool file_equal(const string& file1, const string& file2);
bool permissions_equal(const string& file1, const string& file2);
void file_remove(const string& basedir, const string& filename);
void mkdir_p(const string& path, mode_t mode = 0755);
string real_path(const string& path);

#endif /* UTIL_H */
