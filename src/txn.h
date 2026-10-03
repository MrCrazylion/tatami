#ifndef TXN_H
#define TXN_H

#include <string>
#include <vector>
#include <ostream>
#include <sys/stat.h>
#include <sys/types.h>

using namespace std;

// Undo log of one package installation. Everything the extraction changes on
// disk is recorded first:
//   - a path that did not exist (file, symlink, directory, and the parent
//     directories libarchive creates on the way) is removed again on rollback,
//     bottom-up;
//   - an existing file that is about to be overwritten is renamed aside (in
//     its own directory, so on the same filesystem) and renamed back on
//     rollback;
//   - an existing directory whose mode/owner the extraction changes gets them
//     restored.
// Files of the previous version that are no longer part of the package are
// not deleted up front but deferred until the database was committed.
//
// The log is also written to a journal file below var/lib/tatami, so an
// installation interrupted by a crash or power loss is undone (or, if the
// database was already committed, finished) the next time tatami runs.
class txn {
public:
	// 'root' is the absolute installation root and ends in '/'
	explicit txn(const string& root);
	~txn();

	// Starts the journal for installing 'name' 'version'
	void begin(const string& name, const string& version);

	void created(const string& path);
	// Moves an existing file out of the way and returns where it went
	string backup(const string& path);
	void dir_meta(const string& path, const struct stat& st);
	// Path to delete once the transaction is committed
	void defer_delete(const string& path);

	// Undoes everything, restoring the filesystem to its state at begin()
	void rollback();
	// Called after the database was committed: performs the deferred deletions,
	// drops the backups and the journal
	void commit();

	// Handles a journal left behind by an interrupted run. Returns true (and
	// says what it did on 'out') if there was one.
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

	string root_;
	string journal_;
	int fd_;
	unsigned int counter_;
	vector<record> recs_;
};

#endif /* TXN_H */
