#ifndef RESOLVER_H
#define RESOLVER_H

#include "db.h"
#include "meta.h"
#include <string>
#include <vector>
#include <map>
#include <set>

extern "C" {
#include <solv/pool.h>
#include <solv/repo.h>
#include <solv/solver.h>
#include <solv/transaction.h>
#include <solv/queue.h>
}

using namespace std;

struct plan_step {
	enum kind_t { INSTALL, UPGRADE, REMOVE } kind;
	string name;
	string version;
	string old_version;     // UPGRADE: the installed version being replaced
	string filename;        // INSTALL/UPGRADE: package file to extract
	string checksum;        // INSTALL/UPGRADE: SHA-256 of the file from the index (hex), if it has one
	string note;            // REMOVE: why ("no longer needed", "replaced by x", ...)
};

// Dependency solver built on libsolv. Dependencies, conflicts, provides and
// replaces from package metadata are mapped onto libsolv relations; installed
// packages form the "installed" repository.
class resolver {
public:
	// 'arch' is the architecture policy of the target system: "aarch64", or a
	// list "x86_64:i686" for a multilib system. Packages of any other
	// architecture are refused; noarch ones fit everywhere.
	explicit resolver(const string& arch);
	~resolver();

	void add_installed(const packages_t& packages, const database& db);

	// A repository directory: 'entries' are its packages (their filename is
	// the full path). Earlier repositories win when a version is in several.
	void add_repo(const string& dir, const vector<pkgmeta>& entries);
	// The same from the binary index repo.solv written by write_solv()
	void add_repo_solv(const string& dir, const string& solv_file);
	// Writes the binary libsolv index of a repository directory
	static void write_solv(const string& dir, const vector<pkgmeta>& entries, const string& solv_file);

	// Every package of every repository (not the installed ones), rebuilt from
	// what libsolv holds
	vector<pkgmeta> available_meta() const;
	// Adds a package given on the command line, returns its solvable id
	Id add_local(const pkgmeta& meta);

	// Names of the packages the user asked to install (the candidates of every
	// request, which includes providers of virtual names). Packages installed
	// for any other reason are dependencies.
	const set<string>& requested_names() const { return requested_; }

	// Job construction. Names may be 'name', 'name=version' or a provided name.
	void want_install(const string& spec);
	void want_install_solvable(Id p);
	// Removes the package, everything that depends on it, and every dependency
	// that is then no longer needed by an explicitly installed package
	// (SOLVER_ERASE with SOLVER_CLEANDEPS; explicit packages are handed to
	// libsolv as SOLVER_USERINSTALLED).
	void want_erase(const string& name);
	void want_upgrade_all();

	// Returns true if a solution was found; otherwise problems() explains why
	bool solve();
	const vector<string>& problems() const { return problems_; }
	vector<plan_step> plan() const;

	// Why the newest available version of an installed package is not being
	// installed (empty if it is not blocked or nothing newer exists)
	vector<string> explain_not_upgraded(const string& name);

	// Highest available version of 'name' (not installed repo), "" if none
	string best_available(const string& name) const;
	// True if version a is newer than version b
	bool newer(const string& a, const string& b) const;

private:
	resolver(const resolver&);
	resolver& operator=(const resolver&);

	Id add_solvable(Repo* repo, const pkgmeta& meta);
	Repo* new_repo(const string& dir);
	string solvable_file(Id p) const;
	void prepare();
	void clear_solution();
	void make_jobs(Queue* jobs) const;
	void collect_problems(Solver* solv, vector<string>& out) const;
	string downgrade_hint();
	Id best_available_id(const string& name) const;
	Id parse_dep(const string& text);
	Id parse_one_dep(const string& text);

	Pool* pool_;
	Repo* installed_;
	vector<Repo*> repos_;                   // repositories, best first
	map<Repo*, string> repo_dir_;           // where their relative file names start
	Repo* local_;
	Queue job_;
	Solver* solv_;
	Transaction* trans_;
	vector<string> problems_;
	string arch_;
	bool ready_;
	bool erasing_;
	set<string> requested_;                 // see requested_names()
	set<string> erase_targets_;
	map<string, bool> dependency_;          // installed package -> installed as a dependency
	vector<Id> explicit_ids_;               // installed packages the user asked for
};

#endif /* RESOLVER_H */
