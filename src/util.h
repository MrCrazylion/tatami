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

// The extensions a package file may have. If one was configured (PKG_EXT) it is
// the only one; otherwise every tar.<compression> tatami can read.
vector<string> package_extensions(const string& configured);
bool has_package_extension(const string& filename, const vector<string>& exts);

// Splits "<dir>/<name>_<version>_<arch>.<ext>" into its parts. Names and
// versions may not contain '_' (an architecture may: x86_64), so the first two
// underscores are the separators: libfoo-dev_2.0-1_x86_64.tar.zst is name
// "libfoo-dev", version "2.0-1", architecture "x86_64". Returns false if the
// file name does not have that form.
bool split_package_filename(const string& filename, const vector<string>& exts,
			    string& name, string& version, string& arch);

// "noarch", "all" and "any" (any case) are the same: not tied to an architecture
string canonical_arch(const string& arch);

bool file_exists(const string& filename);
bool file_empty(const string& filename);
bool file_equal(const string& file1, const string& file2);
bool permissions_equal(const string& file1, const string& file2);
void file_remove(const string& basedir, const string& filename);
void mkdir_p(const string& path, mode_t mode = 0755);
string real_path(const string& path);

#endif /* UTIL_H */
