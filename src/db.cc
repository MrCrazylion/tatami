#include "db.h"
#include "util.h"
#include "paths.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <algorithm>
#include <cstdio>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>

db_lock::db_lock(const string& root, bool exclusive)
	: dir(0)
{
	const string dirname = trim_filename(root + "/" + PKG_DIR);

	if (exclusive)
		mkdir_p(dirname);

	if (!(dir = opendir(dirname.c_str()))) {
		// A read-only command on a root without a database has nothing to lock
		if (!exclusive && errno == ENOENT)
			return;
		throw runtime_error_with_errno("could not read directory " + dirname);
	}

	if (flock(dirfd(dir), (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == -1) {
		int e = errno;
		closedir(dir);
		dir = 0;
		if (e == EWOULDBLOCK)
			throw runtime_error("package database is currently locked by another process");
		else
			throw runtime_error_with_errno("could not lock directory " + dirname, e);
	}
}

db_lock::~db_lock()
{
	if (dir) {
		flock(dirfd(dir), LOCK_UN);
		closedir(dir);
	}
}

database::database(const string& root)
	: root_(trim_filename(root + "/"))
{
}

const pkgmeta* database::meta(const string& name) const
{
	map<string, pkgmeta>::const_iterator i = metas_.find(name);
	return i == metas_.end() ? 0 : &i->second;
}

void database::open(bool create)
{
	const string filename = root_ + PKG_DB;

	packages_.clear();
	metas_.clear();

	ifstream in(filename.c_str());
	if (!in) {
		if (file_exists(filename))
			throw runtime_error_with_errno("could not open " + filename);
		if (create) {
			mkdir_p(root_ + PKG_DIR);
			FILE* f = fopen(filename.c_str(), "a");
			if (!f)
				throw runtime_error_with_errno("could not create " + filename);
			fclose(f);
		}
		return;	// no database yet: nothing installed
	}

	string name;
	while (getline(in, name)) {
		if (name.empty())
			continue;	// stray blank line between records

		// Read record
		pkgrecord rec;
		getline(in, rec.version);
		for (;;) {
			string file;
			if (!getline(in, file) || file.empty())
				break; // End of record
			rec.files.insert(rec.files.end(), file);
		}
		if (!rec.files.empty())
			packages_[name] = rec;
	}

	// Load stored metadata of installed packages
	for (packages_t::const_iterator i = packages_.begin(); i != packages_.end(); ++i) {
		ifstream mf((root_ + PKG_META_DIR + "/" + i->first).c_str());
		if (!mf)
			continue;
		pkgmeta m;
		try {
			if (read_meta_block(mf, m) && m.name == i->first) {
				m.version = i->second.version;
				metas_[i->first] = m;
			}
		} catch (runtime_error&) {
			// Unreadable metadata: treat the package as having none
		}
	}
}

void database::commit()
{
	const string dbfilename = root_ + PKG_DB;
	const string dbfilename_new = dbfilename + ".incomplete_transaction";
	const string dbfilename_bak = dbfilename + ".backup";

	mkdir_p(root_ + PKG_DIR);

	// Remove failed transaction (if it exists)
	if (unlink(dbfilename_new.c_str()) == -1 && errno != ENOENT)
		throw runtime_error_with_errno("could not remove " + dbfilename_new);

	// Write new database
	FILE* f = fopen(dbfilename_new.c_str(), "w");
	if (!f)
		throw runtime_error_with_errno("could not create " + dbfilename_new);
	fchmod(fileno(f), 0444);

	bool ok = true;
	for (packages_t::const_iterator i = packages_.begin(); ok && i != packages_.end(); ++i) {
		if (i->second.files.empty())
			continue;
		ok = fprintf(f, "%s\n%s\n", i->first.c_str(), i->second.version.c_str()) >= 0;
		for (set<string>::const_iterator j = i->second.files.begin(); ok && j != i->second.files.end(); ++j)
			ok = fprintf(f, "%s\n", j->c_str()) >= 0;
		if (ok)
			ok = fputc('\n', f) != EOF;
	}

	// Make sure the new database was successfully written and synchronize it to disk
	if (!ok || fflush(f) == EOF) {
		fclose(f);
		throw runtime_error("could not write " + dbfilename_new);
	}
	if (fsync(fileno(f)) == -1) {
		int e = errno;
		fclose(f);
		throw runtime_error_with_errno("could not synchronize " + dbfilename_new, e);
	}
	if (fclose(f) == EOF)
		throw runtime_error_with_errno("could not write " + dbfilename_new);

	// Metadata store: write metadata of installed packages, drop stale entries
	mkdir_p(root_ + PKG_META_DIR);
	for (map<string, pkgmeta>::const_iterator i = metas_.begin(); i != metas_.end(); ++i) {
		if (!has(i->first))
			continue;
		const string path = root_ + PKG_META_DIR + "/" + i->first;
		const string tmp = path + ".tmp";
		ofstream out(tmp.c_str());
		out << format_meta(i->second);
		out.close();
		if (!out || rename(tmp.c_str(), path.c_str()) == -1) {
			unlink(tmp.c_str());
			throw runtime_error_with_errno("could not write " + path);
		}
	}

	// Relink database backup
	if (file_exists(dbfilename)) {
		if (unlink(dbfilename_bak.c_str()) == -1 && errno != ENOENT)
			throw runtime_error_with_errno("could not remove " + dbfilename_bak);
		if (link(dbfilename.c_str(), dbfilename_bak.c_str()) == -1)
			throw runtime_error_with_errno("could not create " + dbfilename_bak);
	}

	// Move new database into place
	if (rename(dbfilename_new.c_str(), dbfilename.c_str()) == -1)
		throw runtime_error_with_errno("could not rename " + dbfilename_new + " to " + dbfilename);

	DIR* d = opendir((root_ + PKG_META_DIR).c_str());
	if (d) {
		vector<string> stale;
		struct dirent* de;
		while ((de = readdir(d))) {
			const string n = de->d_name;
			if (n != "." && n != ".." && !has(n))
				stale.push_back(n);
		}
		closedir(d);
		for (vector<string>::const_iterator i = stale.begin(); i != stale.end(); ++i)
			unlink((root_ + PKG_META_DIR + "/" + *i).c_str());
	}
}

void database::add_pkg(const string& name, const pkgrecord& rec, const pkgmeta& meta)
{
	packages_[name] = rec;
	pkgmeta m = meta;
	m.filename = "";
	m.size = 0;
	m.version = rec.version;
	metas_[name] = m;
}

void database::remove_files(const set<string>& files) const
{
	// Reverse order: directory contents are removed before the directory
	for (set<string>::const_reverse_iterator i = files.rbegin(); i != files.rend(); ++i) {
		const string filename = root_ + *i;
		if (file_exists(filename) && remove(filename.c_str()) == -1) {
			if (errno == ENOTEMPTY)
				continue;
			cerr << "tatami: could not remove " << filename << ": " << strerror(errno) << endl;
		}
	}
}

void database::rm_pkg(const string& name, const set<string>& keep_list)
{
	packages_t::iterator pkg = packages_.find(name);
	if (pkg == packages_.end())
		return;

	set<string> files = pkg->second.files;
	packages_.erase(pkg);
	metas_.erase(name);

	// Don't delete files found in the keep list
	for (set<string>::const_iterator i = keep_list.begin(); i != keep_list.end(); ++i)
		files.erase(*i);

	// Don't delete files that still have references
	for (packages_t::const_iterator i = packages_.begin(); i != packages_.end(); ++i)
		for (set<string>::const_iterator j = i->second.files.begin(); j != i->second.files.end(); ++j)
			files.erase(*j);

	remove_files(files);
}

void database::rm_files(set<string> files, const set<string>& keep_list)
{
	// Remove all references
	for (packages_t::iterator i = packages_.begin(); i != packages_.end(); ++i)
		for (set<string>::const_iterator j = files.begin(); j != files.end(); ++j)
			i->second.files.erase(*j);

	// Don't delete files found in the keep list
	for (set<string>::const_iterator i = keep_list.begin(); i != keep_list.end(); ++i)
		files.erase(*i);

	remove_files(files);
}

set<string> database::find_conflicts(const string& name, const set<string>& pkgfiles) const
{
	set<string> files;

	// Find conflicting files in database
	for (packages_t::const_iterator i = packages_.begin(); i != packages_.end(); ++i) {
		if (i->first != name) {
			set_intersection(pkgfiles.begin(), pkgfiles.end(),
					 i->second.files.begin(), i->second.files.end(),
					 inserter(files, files.end()));
		}
	}

	// Find conflicting files in filesystem
	for (set<string>::const_iterator i = pkgfiles.begin(); i != pkgfiles.end(); ++i) {
		if (file_exists(root_ + *i))
			files.insert(*i);
	}

	// Exclude directories
	for (set<string>::iterator i = files.begin(); i != files.end(); ) {
		if ((*i)[i->length() - 1] == '/')
			files.erase(i++);
		else
			++i;
	}

	// If this is an upgrade, remove files already owned by this package
	packages_t::const_iterator self = packages_.find(name);
	if (self != packages_.end()) {
		for (set<string>::const_iterator i = self->second.files.begin(); i != self->second.files.end(); ++i)
			files.erase(*i);
	}

	return files;
}
