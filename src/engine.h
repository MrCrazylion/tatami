#ifndef ENGINE_H
#define ENGINE_H

#include "config.h"
#include "db.h"
#include "hooks.h"
#include "txn.h"
#include <regex.h>
#include <memory>
#include <set>
#include <string>
#include <vector>

using namespace std;

// Applies single package operations to the installed system. This is the
// pkgadd/pkgrm logic of pkgutils: INSTALL/UPGRADE rules, conflict handling,
// rejected files and the database commit protocol.
class engine {
public:
	engine(const config_t& cfg, database& db, bool force);

	// A transaction is every install, upgrade and removal of one run, all or nothing:
	//
	//   begin();  install(...); remove(...); ...  commit();     // or rollback()
	//
	// install() and remove() only extract files (every change recorded in the
	// undo journal) and change the database in memory. Nothing is deleted and
	// nothing is committed until commit(), which makes the whole run visible at
	// once: deferred deletions are journalled, the database is written, then the
	// old files go. If anything fails, rollback() restores every file touched by
	// the run and forgets the in-memory database changes. A run killed in the
	// middle is undone by txn::recover() the next time tatami starts.
	void begin();

	// Throws if the filesystem of the root has not enough free space to extract
	// these package files (plus a safety margin). Call it before begin(): then
	// nothing has been touched yet. Does nothing if the space cannot be determined.
	void check_disk_space(const vector<string>& package_files);

	// Files of the download cache that were used by this transaction: they are
	// deleted (with their .sig) when the transaction commits, and left alone if it
	// is rolled back. Only files inside the cache directory are ever deleted.
	void discard_when_committed(const string& cached_file);

	// Installs or upgrades (if the package is already installed) a package file.
	// 'requested' is true if the user asked for this package, false if it is
	// only installed to satisfy a dependency.
	void install(const string& filename, bool requested);
	void remove(const string& name);

	// Commits the transaction. Throws (and leaves the transaction to rollback())
	// if the database cannot be written.
	void commit();

	// Undoes the transaction: restores the filesystem, reloads the database.
	// Does nothing when no transaction is open.
	void rollback();

	// Checks the hook files; call before changing anything
	void check_hooks();

	// Runs the hooks the changes made so far trigger (see hooks.h). Call it once,
	// after the whole transaction was committed. Returns the number that failed.
	int run_hooks();

	// Marks an installed package as explicitly installed (it is no longer
	// removed automatically when nothing depends on it)
	void mark_explicit(const string& name);

private:
	struct compiled_rule {
		rule_event_t event;
		bool action;
		shared_ptr<regex_t> re;
	};

	set<string> make_keep_list(const set<string>& files) const;
	set<string> apply_install_rules(set<string>& files) const;
	bool rule_applies(const compiled_rule& rule, const string& file) const;

	database& db_;
	bool force_;
	unique_ptr<txn> tx_;                    // the open transaction
	vector<string> cache_files_;            // downloaded packages to delete after the commit
	set<string> doomed_;                    // files to delete at commit unless a package still owns them
	vector<pair<string, set<string> > > hook_log_;  // (operation, files), given to the hooks at commit
	hook_runner hooks_;
	vector<compiled_rule> rules_;
};

#endif /* ENGINE_H */
