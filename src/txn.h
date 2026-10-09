#ifndef TXN_H
#define TXN_H

#include <string>
#include <vector>
#include <ostream>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

// Undo log of one whole run (all the installations, upgrades and removals of a
// plan). Everything the run changes on disk is recorded first:
//   - a path that did not exist (file, symlink, directory, and the parent
//     directories libarchive creates on the way) is removed again on rollback,
//     bottom-up;
//   - an existing file that is about to be overwritten is renamed aside (in
//     its own directory, so on the same filesystem) and renamed back on
//     rollback;
//   - an existing directory whose mode/owner the extraction changes gets them
//     restored.
// Files that are no longer wanted (removed packages, files an upgrade dropped)
// are not deleted up front but deferred until the database was committed.
// The database itself is only changed in memory until then; one commit makes
// the whole run visible, one rollback undoes all of it.
//
// The log is also written to a journal file below var/lib/tatami, so a run
// interrupted by a crash, SIGKILL or power loss is undone (or, if it got as far
// as the database commit, finished) the next time tatami runs:
//   T                    start of a run
//   I name version       a package is installed or upgraded
//   R name               a package is removed
//   C/B/M/D ...          the file actions described above
//   K                    all work is done, the database commit follows
// Without a K the database cannot have been committed: the run is rolled back.
// With a K the database decides: if it lists the result of every I and R the
// run is finished, otherwise it is rolled back.
class txn {
public:
	// 'journal' is the absolute host path of the journal file
	explicit txn(const string& journal);
	~txn();

	// Starts the journal of a run
	void begin();

	// What the run does to the package database (journalled so that a crash can
	// tell afterwards whether the commit happened)
	void note_install(const string& name, const string& version);
	void note_remove(const string& name);

	// Call after everything was extracted and the deferred deletions were
	// recorded, right before the database is committed
	void commit_point();

	void created(const string& path);
	// Moves an existing file out of the way and returns where it went
	string backup(const string& path);
	void dir_meta(const string& path, const struct stat& st);
	// Path to delete once the transaction is committed
	void defer_delete(const string& path);

	// Undoes everything, restoring the filesystem to its state at begin()
	void rollback();
	// Called after the database was committed: performs the deferred deletions,
	// drops the backups and the journal. (Also what recover() does when it finds
	// that the database was committed.)
	void commit();

	// Handles a journal left behind by an interrupted run in the installation
	// root 'root'. Returns true (and says what it did on 'out') if there was one.
	static bool recover(const string& root, ostream& out);

private:
	struct record {
		char type;              // 'C' created, 'B' backup, 'M' dir meta, 'D' deferred delete
		string path;
		string bak;
		mode_t mode;
		uid_t uid;
		gid_t gid;
	};

	txn(const txn&);
	txn& operator=(const txn&);

	void append(const string& line);
	static void undo(const vector<record>& recs);
	static void finish(const vector<record>& recs);
	void close_journal(bool remove_it);

	string journal_;
	int fd_;
	unsigned int counter_;
	vector<record> recs_;
};

#endif /* TXN_H */
