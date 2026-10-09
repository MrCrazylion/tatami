#ifndef META_H
#define META_H

#include <string>
#include <istream>
#include <vector>

using namespace std;

#define META_FILE       ".META"         // metadata member inside every package

// Why an installed package is on the system. "explicit": the user asked for it
// (or the reason is unknown, as for packages installed before tracking existed:
// those are never removed automatically). "dependency": it was only pulled in
// to satisfy the dependencies of other packages and goes away with the last
// package that needs it.
#define REASON_EXPLICIT         "explicit"
#define REASON_DEPENDENCY       "dependency"

// Package metadata. The same "key: value" text format is used inside a
// package (.META), in the repository index and in the installed-package store.
struct pkgmeta {
	string name;
	string version;
	string arch;
	string description;
	string depends;         // "a, b (>= 1.0), c | d"
	string conflicts;
	string provides;
	string replaces;
	string filename;        // index only: absolute path of the package file
	unsigned long long size;        // index only: size of the package file
	string checksum;        // index only: SHA-256 of the package file, in hex (remote packages are checked against it)
	string reason;          // installed packages only: REASON_EXPLICIT or REASON_DEPENDENCY

	pkgmeta() : size(0) {}
};

// Reads the next block of "key: value" lines (blocks are separated by blank
// lines). Returns false at end of input.
bool read_meta_block(istream& in, pkgmeta& meta);
pkgmeta parse_meta(const string& text);
string format_meta(const pkgmeta& meta);

// Throws runtime_error if name or version are missing or malformed.
void validate_meta(const pkgmeta& meta);


#endif /* META_H */
