#include "txn.h"
#include "db.h"
#include "paths.h"
#include "util.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <unistd.h>

#define JOURNAL_FILE    "var/lib/tatami/transaction.journal"

txn::txn(const string& root)
	: root_(root), journal_(root + JOURNAL_FILE), fd_(-1), counter_(0)
{
}

txn::~txn()
{
	if (fd_ != -1)
		close(fd_);
}

void txn::append(const string& line)
{
	if (fd_ == -1)
		throw runtime_error("transaction journal is not open");

	const string text = line + "\n";
	size_t done = 0;
	while (done < text.size()) {
		ssize_t n = write(fd_, text.data() + done, text.size() - done);
		if (n == -1) {
			if (errno == EINTR)
				continue;
			throw runtime_error_with_errno("could not write " + journal_);
		}
		done += n;
	}
}

void txn::begin(const string& name, const string& version)
{
	mkdir_p(root_ + PKG_DIR);
	fd_ = open(journal_.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0600);
	if (fd_ == -1)
		throw runtime_error_with_errno("could not create " + journal_);

	recs_.clear();
	counter_ = 0;
	append("P\t" + name + "\t" + version);
	if (fsync(fd_) == -1)
		throw runtime_error_with_errno("could not synchronize " + journal_);
}

// Every action is journalled before it is carried out, so after a crash the
// journal never describes less than what was done.
void txn::created(const string& path)
{
	append("C\t" + path);
	record r = { 'C', path, "", 0, 0, 0 };
	recs_.push_back(r);
}

string txn::backup(const string& path)
{
	const string::size_type slash = path.rfind('/');
	const string bak = path.substr(0, slash + 1) + ".tatami-bak." + itos(getpid()) + "." + itos(counter_++);

	append("B\t" + path + "\t" + bak);
	record r = { 'B', path, bak, 0, 0, 0 };
	recs_.push_back(r);

	if (rename(path.c_str(), bak.c_str()) == -1)
		throw runtime_error_with_errno("could not move " + path + " out of the way");

	return bak;
}

void txn::dir_meta(const string& path, const struct stat& st)
{
	ostringstream line;
	line << "M\t" << path << "\t" << oct << (st.st_mode & 07777) << dec << "\t" << st.st_uid << "\t" << st.st_gid;
	append(line.str());
	record r = { 'M', path, "", st.st_mode & 07777, st.st_uid, st.st_gid };
	recs_.push_back(r);
}

void txn::defer_delete(const string& path)
{
	append("D\t" + path);
	record r = { 'D', path, "", 0, 0, 0 };
	recs_.push_back(r);
}

// Undo, newest first: children are removed before their parent directories.
void txn::undo(const vector<record>& recs)
{
	for (vector<record>::const_reverse_iterator i = recs.rbegin(); i != recs.rend(); ++i) {
		struct stat st;

		switch (i->type) {
		case 'C':
			if (lstat(i->path.c_str(), &st) == -1)
				break;
			if (S_ISDIR(st.st_mode)) {
				if (rmdir(i->path.c_str()) == -1 && errno != ENOTEMPTY)
					cerr << "tatami: warning: could not remove " << i->path << ": " << strerror(errno) << endl;
			} else if (unlink(i->path.c_str()) == -1) {
				cerr << "tatami: warning: could not remove " << i->path << ": " << strerror(errno) << endl;
			}
			break;

		case 'B':
			// The backup only exists if the rename happened
			if (lstat(i->bak.c_str(), &st) == -1)
				break;
			if (lstat(i->path.c_str(), &st) == 0 && !S_ISDIR(st.st_mode))
				unlink(i->path.c_str());        // whatever the extraction left there
			if (rename(i->bak.c_str(), i->path.c_str()) == -1)
				cerr << "tatami: warning: could not restore " << i->path << " (saved as "
				     << i->bak << "): " << strerror(errno) << endl;
			break;

		case 'M':
			if (stat(i->path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
				if (chown(i->path.c_str(), i->uid, i->gid) == -1 && errno != EPERM)
					cerr << "tatami: warning: could not restore owner of " << i->path << endl;
				if (chmod(i->path.c_str(), i->mode) == -1)
					cerr << "tatami: warning: could not restore mode of " << i->path << endl;
			}
			break;

		default:
			break;
		}
	}
}

// Commit side: deferred deletions (children first), then the backups
void txn::finish(const vector<record>& recs)
{
	for (vector<record>::const_reverse_iterator i = recs.rbegin(); i != recs.rend(); ++i) {
		if (i->type == 'D') {
			struct stat st;
			if (lstat(i->path.c_str(), &st) == -1)
				continue;
			if (remove(i->path.c_str()) == -1 && errno != ENOTEMPTY)
				cerr << "tatami: warning: could not remove " << i->path << ": " << strerror(errno) << endl;
		}
	}
	for (vector<record>::const_iterator i = recs.begin(); i != recs.end(); ++i)
		if (i->type == 'B')
			unlink(i->bak.c_str());
}

void txn::close_journal(bool remove_it)
{
	if (fd_ != -1) {
		close(fd_);
		fd_ = -1;
	}
	if (remove_it)
		unlink(journal_.c_str());
}

void txn::rollback()
{
	undo(recs_);
	close_journal(true);
	recs_.clear();
}

void txn::commit()
{
	finish(recs_);
	close_journal(true);
	recs_.clear();
}

bool txn::recover(const string& root, ostream& out)
{
	const string journal = root + JOURNAL_FILE;
	ifstream in(journal.c_str());
	if (!in)
		return false;

	vector<record> recs;
	string name, version, line;

	while (getline(in, line)) {
		vector<string> f;
		string::size_type pos = 0;
		for (;;) {
			string::size_type tab = line.find('\t', pos);
			f.push_back(line.substr(pos, tab == string::npos ? string::npos : tab - pos));
			if (tab == string::npos)
				break;
			pos = tab + 1;
		}
		if (f.size() == 3 && f[0] == "P") {
			name = f[1];
			version = f[2];
		} else if (f.size() == 2 && (f[0] == "C" || f[0] == "D")) {
			record r = { f[0][0], f[1], "", 0, 0, 0 };
			recs.push_back(r);
		} else if (f.size() == 3 && f[0] == "B") {
			record r = { 'B', f[1], f[2], 0, 0, 0 };
			recs.push_back(r);
		} else if (f.size() == 5 && f[0] == "M") {
			record r = { 'M', f[1], "", (mode_t)strtoul(f[2].c_str(), 0, 8),
				     (uid_t)strtoul(f[3].c_str(), 0, 10), (gid_t)strtoul(f[4].c_str(), 0, 10) };
			recs.push_back(r);
		}
		// a torn last line is simply ignored
	}
	in.close();

	// The database commit is the commit point: if it already lists the new
	// version the installation is finished, otherwise it is undone.
	bool committed = false;
	if (!name.empty()) {
		database db(root);
		db.open(false);
		committed = db.has(name) && db.packages().find(name)->second.version == version;
	}

	if (committed) {
		finish(recs);
		out << "tatami: finished an interrupted installation of " << name << " " << version << endl;
	} else {
		undo(recs);
		out << "tatami: rolled back an interrupted installation"
		    << (name.empty() ? string() : " of " + name + " " + version) << endl;
	}

	unlink(journal.c_str());
	return true;
}
