#ifndef PKGARCHIVE_H
#define PKGARCHIVE_H

#include "meta.h"
#include "txn.h"
#include <string>
#include <set>

using namespace std;

struct package_t {
	pkgmeta meta;
	set<string> files;      // normalised member paths, directories end in '/'
	string install_script;  // the .INSTALL member (never installed as a file), "" if none
	unsigned long long bytes;       // total size of the regular files once extracted
	unsigned long long entries;     // number of members (each takes at least a block or an inode)
};

// Scans the whole archive. Throws if the package has no .META member.
package_t pkg_open(const string& filename);

// Reads only the metadata. Fast when .META is the first member (tatami-mkpkg does so).
pkgmeta pkg_read_meta(const string& filename);

// Extracts the package below 'root' (which must be absolute and end in '/').
// A file in config_list (the UPGRADE rules saying NO: configuration files) that
// already exists and differs from the package's version is renamed to <file>.old
// and the package's version is installed; an identical one is left alone. Files in
// non_install_list are skipped.
//
// Everything that is created or overwritten is recorded in 'tx' first. The
// first error of any kind (a file that cannot be written, a corrupt or
// truncated archive, ...) stops the extraction and is thrown; the caller then
// calls tx.rollback() to put the filesystem back exactly as it was.
void pkg_install(const string& utilname, const string& root, const string& filename,
		 const set<string>& keep_list, const set<string>& non_install_list,
		 txn& tx);

#endif /* PKGARCHIVE_H */
