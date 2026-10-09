#ifndef DB_H
#define DB_H

#include "meta.h"
#include <string>
#include <set>
#include <map>
#include <dirent.h>

using namespace std;

struct pkgrecord {
	string version;
	set<string> files;
};

typedef map<string, pkgrecord> packages_t;

// Advisory lock on the database directory (shared or exclusive, non-blocking)
class db_lock {
public:
	db_lock(const string& root, bool exclusive);
	~db_lock();
private:
	db_lock(const db_lock&);
	db_lock& operator=(const db_lock&);
	DIR* dir;
};

// The installed-package database: a plain text file with one record per
// package (name, version, files, blank line) plus one metadata file per
// package. Same on-disk idea and crash-safe commit as pkgutils.
class database {
public:
	// 'root' must be an absolute directory; it is normalised to end in '/'
	explicit database(const string& root);

	void open(bool create);
	void commit();

	const string& root() const { return root_; }
	// Absolute host path of 'rel' (relative to the root), confined to the root
	string path(const string& rel) const;
	const packages_t& packages() const { return packages_; }
	bool has(const string& name) const { return packages_.find(name) != packages_.end(); }
	const pkgmeta* meta(const string& name) const;

	// 'reason' is REASON_EXPLICIT or REASON_DEPENDENCY
	void add_pkg(const string& name, const pkgrecord& rec, const pkgmeta& meta, const string& reason);

	// Install reason of an installed package; unknown means explicit
	string reason(const string& name) const;
	void set_reason(const string& name, const string& reason);

	// Files of the installed version of 'name' that the new file set no longer
	// contains and no other package owns: they are deleted after an upgrade
	set<string> stale_files(const string& name, const set<string>& new_files) const;

	// Drops the given files from the file lists of all packages (database
	// only, nothing is deleted from disk)
	void unreference(const set<string>& files);

	// Forgets a package (database only, in memory until commit(); its files stay
	// on disk until the transaction that removes it commits)
	void drop_pkg(const string& name);

	// Every file listed by any installed package
	set<string> owned_files() const;

	// Files of 'files' that another package owns or that already exist on disk. Files
	// in 'doomed' (to be deleted when the running transaction commits) do not count
	// as existing.
	set<string> find_conflicts(const string& name, const set<string>& files,
				   const set<string>& doomed = set<string>()) const;

private:
	string root_;
	packages_t packages_;
	map<string, pkgmeta> metas_;
};

#endif /* DB_H */
