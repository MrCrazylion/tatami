#include "commands.h"
#include "db.h"
#include "engine.h"
#include "meta.h"
#include "paths.h"
#include "pkgarchive.h"
#include "repos.h"
#include "resolver.h"
#include "sign.h"
#include "rootfs.h"
#include "txn.h"
#include "util.h"
#include <algorithm>
#include <cstdio>
#include <iostream>
#include <iterator>
#include <fstream>
#include <map>
#include <set>
#include <dirent.h>
#include <regex.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

namespace {

//
// Helpers
//

bool is_package_file(const context& ctx, const string& arg)
{
	return arg.find('/') != string::npos ||
		has_package_extension(arg, package_extensions(ctx.cfg.pkg_ext));
}

struct regex_guard {
	regex_t re;
	explicit regex_guard(const string& pattern, int flags) {
		if (regcomp(&re, pattern.c_str(), REG_EXTENDED | REG_NOSUB | flags))
			throw runtime_error("error compiling regular expression '" + pattern + "'");
	}
	~regex_guard() { regfree(&re); }
	bool matches(const string& s) const { return !regexec(&re, s.c_str(), 0, 0, 0); }
private:
	regex_guard(const regex_guard&);
	regex_guard& operator=(const regex_guard&);
};

void require_args(const context& ctx, const char* what)
{
	if (ctx.args.empty())
		throw runtime_error(string("no ") + what + " specified");
}

void print_list(const string& title, const vector<string>& items)
{
	if (items.empty())
		return;

	cout << title << endl;
	string line = " ";
	for (size_t i = 0; i < items.size(); i++) {
		if (line.size() + items[i].size() + 1 > 78 && line.size() > 1) {
			cout << line << endl;
			line = " ";
		}
		line += " " + items[i];
	}
	cout << line << endl;
}

bool confirm(const context& ctx)
{
	if (ctx.opt.yes)
		return true;

	if (!isatty(STDIN_FILENO)) {
		cerr << "tatami: not running interactively, use -y to proceed without asking" << endl;
		return false;
	}

	cout << "Do you want to continue? [Y/n] " << flush;
	string answer;
	if (!getline(cin, answer))
		return false;
	answer = trim(answer);
	return answer.empty() || answer[0] == 'y' || answer[0] == 'Y';
}

//
// Repositories
//
// A repository is a directory of packages. If it holds a repo.solv (written by
// 'tatami index') that binary index is loaded; otherwise the packages are
// scanned, which is slower but always right. The directories come from
// REPO_DIRS in the configuration (plain paths or file:// URLs); without any the
// default is <root>/var/lib/tatami/packages.
//

// The repositories to use: repos.conf / repos.d of the root if they list any,
// else REPO_DIRS of tatami.conf, else the local default directory. Only an
// explicitly configured http(s)/ftp URL is ever fetched; everything else is read
// straight from disk and never starts FETCHCMD.
vector<repo_spec> repositories(const context& ctx)
{
	vector<repo_spec> repos = read_repo_config(ctx.opt.root);
	if (!repos.empty())
		return repos;

	const vector<string>& specs = ctx.cfg.repo_dirs;
	for (size_t i = 0; i < specs.size(); i++)
		repos.push_back(make_repo_spec(ctx.opt.root, "repo" + itos(i + 1), specs[i]));

	if (repos.empty())
		repos.push_back(make_repo_spec(ctx.opt.root, "local", root_resolve(ctx.opt.root, DEFAULT_REPO_REL)));

	return repos;
}

// Reads the .META of every package in 'dir'. Packages that cannot be read are
// skipped with a warning.
vector<pkgmeta> scan_dir(const context& ctx, const string& dir)
{
	vector<pkgmeta> index;
	const vector<string> exts = package_extensions(ctx.cfg.pkg_ext);
	set<string> seen;

	DIR* d = opendir(dir.c_str());
	if (!d)
		throw runtime_error("could not read repository " + dir + ": " + strerror(errno));

	vector<string> names;
	struct dirent* de;
	while ((de = readdir(d)))
		if (has_package_extension(de->d_name, exts))
			names.push_back(de->d_name);
	closedir(d);
	sort(names.begin(), names.end());

	for (size_t i = 0; i < names.size(); i++) {
		try {
			const string path = real_path(dir + "/" + names[i]);
			struct stat st;
			if (stat(path.c_str(), &st) == -1 || !S_ISREG(st.st_mode))
				continue;
			pkgmeta meta = pkg_read_meta(path);
			meta.filename = path;
			meta.size = st.st_size;
			string fname, fversion, farch;
			if (!split_package_filename(path, exts, fname, fversion, farch) ||
			    fname != meta.name || fversion != meta.version ||
			    (!meta.arch.empty() && canonical_arch(farch) != canonical_arch(meta.arch)))
				cerr << "tatami: warning: " << path << " is named differently from its contents ("
				     << meta.name << "_" << meta.version << "_"
				     << (meta.arch.empty() ? string("<arch>") : canonical_arch(meta.arch))
				     << ".<ext>); the contents are used" << endl;
			if (!seen.insert(meta.name + "_" + meta.version + "_" + canonical_arch(meta.arch)).second) {
				cerr << "tatami: warning: skipping " << path << ": " << meta.name << " "
				     << meta.version << " is already in the repository" << endl;
				continue;
			}
			index.push_back(meta);
		} catch (runtime_error& e) {
			cerr << "tatami: warning: skipping " << dir << "/" << names[i] << ": " << e.what() << endl;
		}
	}

	return index;
}

bool newer_than(const struct stat& a, const struct stat& b)
{
	return a.st_mtim.tv_sec > b.st_mtim.tv_sec ||
	       (a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec > b.st_mtim.tv_nsec);
}

// Writes <dir>/repo.solv for the packages of 'dir'; returns how many
size_t index_dir(const context& ctx, const string& dir)
{
	vector<pkgmeta> entries = scan_dir(ctx, dir);
	const string solv = dir + "/repo.solv";
	const string tmp = solv + ".tmp";

	resolver::write_solv(dir, entries, tmp);
	if (rename(tmp.c_str(), solv.c_str()) == -1) {
		const int e = errno;
		unlink(tmp.c_str());
		throw runtime_error_with_errno("could not write " + solv, e);
	}
	// The index must not look older than the directory it was just written to
	utimensat(AT_FDCWD, solv.c_str(), 0, 0);

	return entries.size();
}

//
// Signatures. Only things that come over the network are checked: <file>.sig is
// fetched next to every remote repo.solv and package and verified with the Ed25519
// key PUBKEY of tatami.conf, before the file is used. Local paths and file://
// repositories are trusted and are never checked. A remote repository without a
// PUBKEY is refused, unless the configuration says PUBKEY = none.
//

bool signatures_wanted(const context& ctx)
{
	return ctx.cfg.pubkey != "none";
}

void require_pubkey(const context& ctx, const repo_spec& r)
{
	if (signatures_wanted(ctx) && !ctx.cfg.have_pubkey)
		throw signature_error("repository " + r.name + " (" + r.url + ") is remote but PUBKEY is not set in tatami.conf: "
				      "set PUBKEY = <public key> to verify its signatures, or PUBKEY = none to accept unsigned data");
}

// Fetches <url>.sig to <dest>; a failure means there is no usable signature
void fetch_signature(const context& ctx, const string& url, const string& dest)
{
	try {
		fetch_url(ctx.cfg.fetchcmd, url + ".sig", dest);
	} catch (runtime_error& e) {
		throw signature_error(string("cannot get the signature of ") + url + ": " + e.what());
	}
}

// Adds every configured repository to the solver
void load_repositories(const context& ctx, resolver& res)
{
	const vector<repo_spec> repos = repositories(ctx);

	for (size_t i = 0; i < repos.size(); i++) {
		const repo_spec& r = repos[i];

		if (r.remote) {
			// the index fetched by 'tatami update'
			const string solv = r.dir + "/repo.solv";
			if (!file_exists(solv)) {
				cerr << "tatami: warning: repository " << r.name << " (" << r.url
				     << ") has not been fetched yet, run 'tatami update'" << endl;
				continue;
			}
			// the cached index is checked again: the key may have changed since 'update'
			// An index that cannot be authenticated is left out, never used. (Not an error
			// of the command: installing a local package file does not depend on it.)
			try {
				if (signatures_wanted(ctx)) {
					require_pubkey(ctx, r);
					verify_file(solv, solv + ".sig", ctx.cfg.pubkey_bytes);
				}
			} catch (signature_error& e) {
				cerr << "tatami: warning: ignoring repository " << r.name << ": " << e.what() << endl;
				continue;
			}
			res.add_repo_solv(r.url, solv);
			continue;
		}

		const string& dir = r.dir;
		struct stat dst;
		if (stat(dir.c_str(), &dst) == -1 || !S_ISDIR(dst.st_mode)) {
			cerr << "tatami: warning: could not read repository " << dir << ": " << strerror(errno) << endl;
			continue;
		}

		const string solv = dir + "/repo.solv";
		struct stat sst;
		if (stat(solv.c_str(), &sst) == 0) {
			if (!newer_than(dst, sst)) {
				res.add_repo_solv(dir, solv);
				continue;
			}
			cerr << "tatami: warning: " << solv << " is older than the packages in " << dir
			     << ", scanning them instead (run 'tatami index " << dir << "')" << endl;
		}
		res.add_repo(dir, scan_dir(ctx, dir));
	}
}

// Fetches the package of a plan step that lives in a remote repository into
// <root>/var/cache/tatami/packages and returns the local file. A file already
// in the cache that holds the right package is reused.
string fetch_package(const context& ctx, const plan_step& st)
{
	const string url = st.filename;
	const string file = url.substr(url.rfind('/') + 1);
	if (file.empty() || file[0] == '.' || file.find_first_of("\n\r") != string::npos)
		throw runtime_error("invalid package file name in " + url);

	const string dir = root_resolve(ctx.opt.root, PKG_CACHE);
	mkdir_p(dir);
	const string cached = dir + "/" + file;

	const bool signed_ = signatures_wanted(ctx);
	if (signed_ && !ctx.cfg.have_pubkey)
		throw signature_error("package " + url + " is remote but PUBKEY is not set in tatami.conf: "
				      "set PUBKEY = <public key>, or PUBKEY = none to accept unsigned packages");

	// a cached copy is only reused if its signature still verifies
	if (file_exists(cached)) {
		try {
			if (signed_)
				verify_file(cached, cached + ".sig", ctx.cfg.pubkey_bytes);
			pkgmeta m = pkg_read_meta(cached);
			if (m.name == st.name && m.version == st.version)
				return cached;
		} catch (runtime_error&) {
		}
		unlink(cached.c_str());
		unlink((cached + ".sig").c_str());
	}

	cout << "Downloading " << file << "..." << endl;
	const string part = cached + ".part";
	fetch_url(ctx.cfg.fetchcmd, url, part, true);
	if (signed_) {
		// nothing leaves the .part names until the signature has been verified
		try {
			fetch_signature(ctx, url, part + ".sig");
			verify_file(part, part + ".sig", ctx.cfg.pubkey_bytes);
		} catch (runtime_error&) {
			unlink(part.c_str());
			unlink((part + ".sig").c_str());
			throw;
		}
		if (rename((part + ".sig").c_str(), (cached + ".sig").c_str()) == -1) {
			const int e = errno;
			unlink(part.c_str());
			unlink((part + ".sig").c_str());
			throw runtime_error_with_errno("could not store " + cached + ".sig", e);
		}
	}
	if (rename(part.c_str(), cached.c_str()) == -1) {
		const int e = errno;
		unlink(part.c_str());
		throw runtime_error_with_errno("could not store " + cached, e);
	}
	return cached;
}

// Everything a command needs: database (locked), solver loaded with the
// installed packages and the repositories.
struct session {
	unique_ptr<db_lock> lock;
	database db;
	unique_ptr<resolver> res;
	vector<pkgmeta> index;          // what the repositories offer

	session(const context& ctx, bool exclusive, bool need_index)
		: db(ctx.opt.root)
	{
		lock.reset(new db_lock(ctx.opt.root, exclusive));
		// A previous run killed in the middle of an installation left a journal:
		// undo (or finish) it before anything else looks at the system
		if (exclusive)
			txn::recover(db.root(), cerr);
		db.open(exclusive);
		res.reset(new resolver(ctx.arch));
		res->add_installed(db.packages(), db);
		if (need_index) {
			load_repositories(ctx, *res);
			index = res->available_meta();
		}
	}
};

//
// Transactions (install, remove, upgrade)
//

// Packages the user asked for that are already installed, but only as a
// dependency, become explicit: they must survive the removal of whatever
// pulled them in.
void mark_requested_explicit(const context& ctx, session& s)
{
	if (ctx.opt.simulate)
		return;

	const set<string>& requested = s.res->requested_names();
	engine eng(ctx.cfg, s.db, ctx.opt.force);
	for (set<string>::const_iterator i = requested.begin(); i != requested.end(); ++i) {
		if (s.db.has(*i) && s.db.reason(*i) == REASON_DEPENDENCY) {
			eng.mark_explicit(*i);
			cout << *i << " is now marked as manually installed." << endl;
		}
	}
}

void run_transaction(const context& ctx, session& s, const char* verb,
		     const vector<string>& check_names = vector<string>())
{
	if (!s.res->solve()) {
		cerr << "tatami: unable to " << verb << ", the dependency solver reports:" << endl;
		const vector<string>& problems = s.res->problems();
		for (size_t i = 0; i < problems.size(); i++)
			cerr << "  - " << problems[i] << endl;
		throw runtime_error("unmet dependencies");
	}

	vector<plan_step> plan = s.res->plan();
	if (plan.empty()) {
		// An installed package with a newer version available that is not
		// being upgraded is held back by something: say what.
		for (size_t i = 0; i < check_names.size(); i++) {
			if (!s.db.has(check_names[i]))
				continue;
			vector<string> why = s.res->explain_not_upgraded(check_names[i]);
			if (why.empty())
				continue;
			cerr << "tatami: " << check_names[i] << " cannot be upgraded to "
			     << s.res->best_available(check_names[i]) << ":" << endl;
			for (size_t k = 0; k < why.size(); k++)
				cerr << "  - " << why[k] << endl;
		}
		mark_requested_explicit(ctx, s);
		cout << "Nothing to do." << endl;
		return;
	}

	vector<string> added, upgraded, downgraded, removed;
	for (size_t i = 0; i < plan.size(); i++) {
		const plan_step& st = plan[i];
		switch (st.kind) {
		case plan_step::INSTALL:
			added.push_back(st.name + " (" + st.version + ")");
			break;
		case plan_step::UPGRADE: {
			const string text = st.name + " (" + st.old_version + " -> " + st.version + ")";
			if (!st.old_version.empty() && s.res->newer(st.old_version, st.version))
				downgraded.push_back(text);
			else
				upgraded.push_back(text);
			break;
		}
		case plan_step::REMOVE:
			removed.push_back(st.name + " (" + st.version + ")" +
					  (st.note.empty() ? "" : " [" + st.note + "]"));
			break;
		}
	}

	print_list("The following NEW packages will be installed:", added);
	print_list("The following packages will be upgraded:", upgraded);
	print_list("The following packages will be DOWNGRADED:", downgraded);
	print_list("The following packages will be REMOVED:", removed);
	cout << added.size() << " to install, " << (upgraded.size() + downgraded.size())
	     << " to upgrade, " << removed.size() << " to remove." << endl;

	// Make sure every package file is there (and is what the index says)
	// before touching the system (read-only, so also done when simulating).
	for (size_t i = 0; i < plan.size(); i++) {
		const plan_step& st = plan[i];
		if (st.kind == plan_step::REMOVE || is_remote_url(st.filename))
			continue;       // remote ones are downloaded after the confirmation
		if (st.filename.empty() || !file_exists(st.filename))
			throw runtime_error("package file for " + st.name + " " + st.version +
					    " not found: " + st.filename + " (try 'tatami update')");
		pkgmeta m = pkg_read_meta(st.filename);
		if (m.name != st.name || m.version != st.version)
			throw runtime_error(st.filename + " does not contain " + st.name + " " +
					    st.version + " (try 'tatami update')");
	}

	if (ctx.opt.simulate)
		return;

	if (!confirm(ctx))
		throw runtime_error("aborted");

	// Remote packages are downloaded (and checked) before the system is touched
	for (size_t i = 0; i < plan.size(); i++) {
		plan_step& st = plan[i];
		if (st.kind == plan_step::REMOVE || !is_remote_url(st.filename))
			continue;
		st.filename = fetch_package(ctx, st);
		pkgmeta m = pkg_read_meta(st.filename);
		if (m.name != st.name || m.version != st.version) {
			unlink(st.filename.c_str());
			throw runtime_error("the downloaded file does not contain " + st.name + " " +
					    st.version + " (try 'tatami update')");
		}
	}

	engine eng(ctx.cfg, s.db, ctx.opt.force);
	eng.check_hooks();      // a malformed hook must stop us before the system is changed

	// All or nothing: a failure anywhere undoes every package of this run
	eng.begin();
	size_t done = 0;
	try {
		for (size_t i = 0; i < plan.size(); i++) {
			const plan_step& st = plan[i];
			switch (st.kind) {
			case plan_step::INSTALL:
				cout << "Installing " << st.name << " (" << st.version << ")..." << endl;
				eng.install(st.filename, s.res->requested_names().count(st.name) > 0);
				break;
			case plan_step::UPGRADE:
				cout << "Upgrading " << st.name << " (" << st.old_version << " -> " << st.version << ")..." << endl;
				eng.install(st.filename, s.res->requested_names().count(st.name) > 0);
				break;
			case plan_step::REMOVE:
				cout << "Removing " << st.name << " (" << st.version << ")..." << endl;
				eng.remove(st.name);
				break;
			}
			done++;
		}
		eng.commit();
	} catch (runtime_error& e) {
		cerr << "tatami: " << e.what() << endl;
		cerr << "tatami: rolling back the whole transaction (" << done << " of " << plan.size()
		     << " steps had been done)..." << endl;
		eng.rollback();
		throw runtime_error("the transaction failed, nothing was changed");
	}

	eng.run_hooks();
	mark_requested_explicit(ctx, s);
	cout << "Done." << endl;
}

void cmd_install(context& ctx)
{
	require_args(ctx, "package");
	session s(ctx, !ctx.opt.simulate, true);
	vector<string> names;

	for (size_t i = 0; i < ctx.args.size(); i++) {
		const string& arg = ctx.args[i];
		if (arg.find('=') == string::npos && !is_package_file(ctx, arg))
			names.push_back(arg);
		if (is_package_file(ctx, arg)) {
			if (!file_exists(arg))
				throw runtime_error("package file " + arg + " not found");
			const string path = real_path(arg);
			pkgmeta meta = pkg_read_meta(path);
			meta.filename = path;
			s.res->want_install_solvable(s.res->add_local(meta));
		} else {
			try {
				s.res->want_install(arg);
			} catch (runtime_error& e) {
				if (s.index.empty() && string(e.what()).find("unable to locate") == 0)
					throw runtime_error(string(e.what()) + " (no repository offers any package: check REPO_DIRS in tatami.conf)");
				throw;
			}
		}
	}

	run_transaction(ctx, s, "install", names);
}

void cmd_remove(context& ctx)
{
	require_args(ctx, "package");
	session s(ctx, !ctx.opt.simulate, false);

	for (size_t i = 0; i < ctx.args.size(); i++)
		s.res->want_erase(ctx.args[i]);

	run_transaction(ctx, s, "remove");
}

void cmd_upgrade(context& ctx)
{
	session s(ctx, !ctx.opt.simulate, true);
	s.res->want_upgrade_all();

	vector<string> names;
	for (packages_t::const_iterator i = s.db.packages().begin(); i != s.db.packages().end(); ++i)
		names.push_back(i->first);
	run_transaction(ctx, s, "upgrade", names);
}

//
// index / update: write the binary repository index
//

void cmd_index(context& ctx)
{
	require_args(ctx, "repository directory");

	for (size_t i = 0; i < ctx.args.size(); i++) {
		string dir = ctx.args[i];
		if (starts_with(dir, "file://"))
			dir.erase(0, 7);
		if (dir.find("://") != string::npos)
			throw runtime_error("cannot index " + dir + ": only a local directory can be indexed");
		const size_t n = index_dir(ctx, dir);
		cout << "Indexed " << n << " package" << (n == 1 ? "" : "s") << " in " << dir << "/repo.solv" << endl;
	}
}

// Downloads the repo.solv of a remote repository into the cache
void update_remote(const context& ctx, const repo_spec& r)
{
	const string solv = r.dir + "/repo.solv";
	const string part = solv + ".part";

	mkdir_p(r.dir);
	require_pubkey(ctx, r);
	fetch_url(ctx.cfg.fetchcmd, r.url + "/repo.solv", part, true);

	// the signature comes first: an index that does not verify is never looked at
	const bool check_sig = signatures_wanted(ctx);
	if (check_sig) {
		try {
			fetch_signature(ctx, r.url + "/repo.solv", part + ".sig");
			verify_file(part, part + ".sig", ctx.cfg.pubkey_bytes);
		} catch (runtime_error&) {
			unlink(part.c_str());
			unlink((part + ".sig").c_str());
			throw;
		}
	}

	// whatever came back must be a real index (without -f curl saves error pages too)
	try {
		resolver check("noarch");
		check.add_repo_solv(r.url, part);
	} catch (runtime_error& e) {
		unlink(part.c_str());
		unlink((part + ".sig").c_str());
		throw runtime_error(r.url + "/repo.solv is not a valid index: " + e.what());
	}
	// the signature is stored first: an index without its signature is never trusted
	if (check_sig && rename((part + ".sig").c_str(), (solv + ".sig").c_str()) == -1) {
		const int e = errno;
		unlink(part.c_str());
		unlink((part + ".sig").c_str());
		throw runtime_error_with_errno("could not write " + solv + ".sig", e);
	}
	if (rename(part.c_str(), solv.c_str()) == -1) {
		const int e = errno;
		unlink(part.c_str());
		throw runtime_error_with_errno("could not write " + solv, e);
	}
}

void cmd_update(context& ctx)
{
	const vector<repo_spec> repos = repositories(ctx);

	for (size_t i = 0; i < repos.size(); i++) {
		const repo_spec& r = repos[i];
		try {
			if (r.remote) {
				if (ctx.opt.simulate) {
					cout << "Would fetch " << r.url << "/repo.solv" << endl;
				} else {
					cout << "Fetching " << r.name << " (" << r.url << ")..." << endl;
					update_remote(ctx, r);
				}
			} else if (ctx.opt.simulate) {
				const size_t n = scan_dir(ctx, r.dir).size();
				cout << "Would index " << n << " package" << (n == 1 ? "" : "s") << " in " << r.dir << endl;
			} else {
				const size_t n = index_dir(ctx, r.dir);
				cout << "Indexed " << n << " package" << (n == 1 ? "" : "s") << " in " << r.dir << "/repo.solv" << endl;
			}
		} catch (signature_error&) {
			throw;          // an unverifiable repository is not skipped: abort
		} catch (runtime_error& e) {
			cerr << "tatami: warning: " << r.name << ": " << e.what() << endl;
		}
	}
}

//
// Queries: search, show, list, files, owns
//

// Newest entry per package name
map<string, pkgmeta> newest(const resolver& res, const vector<pkgmeta>& index)
{
	map<string, pkgmeta> result;

	for (size_t i = 0; i < index.size(); i++) {
		map<string, pkgmeta>::iterator f = result.find(index[i].name);
		if (f == result.end())
			result[index[i].name] = index[i];
		else if (res.newer(index[i].version, f->second.version))
			f->second = index[i];
	}

	return result;
}

string installed_version(const session& s, const string& name)
{
	packages_t::const_iterator i = s.db.packages().find(name);
	return i == s.db.packages().end() ? "" : i->second.version;
}

void cmd_search(context& ctx)
{
	require_args(ctx, "search pattern");
	session s(ctx, false, true);
	regex_guard re(ctx.args[0], REG_ICASE);

	map<string, pkgmeta> avail = newest(*s.res, s.index);
	map<string, pkgmeta> all = avail;

	// Installed packages that are not in the index
	for (packages_t::const_iterator i = s.db.packages().begin(); i != s.db.packages().end(); ++i) {
		if (all.find(i->first) == all.end()) {
			pkgmeta m;
			if (const pkgmeta* stored = s.db.meta(i->first))
				m = *stored;
			m.name = i->first;
			m.version = i->second.version;
			all[i->first] = m;
		}
	}

	size_t found = 0;
	for (map<string, pkgmeta>::const_iterator i = all.begin(); i != all.end(); ++i) {
		if (!re.matches(i->first) && !re.matches(i->second.description))
			continue;
		const string inst = installed_version(s, i->first);
		cout << i->first << "/" << i->second.version;
		if (!inst.empty())
			cout << (inst == i->second.version ? " [installed]" : " [installed: " + inst + "]");
		cout << endl;
		if (!i->second.description.empty())
			cout << "  " << i->second.description << endl;
		found++;
	}

	if (!found)
		cout << "No packages found." << endl;
}

void print_field(const char* key, const string& value)
{
	if (!value.empty())
		cout << key << ": " << value << endl;
}

void cmd_show(context& ctx)
{
	require_args(ctx, "package");
	session s(ctx, false, true);
	bool first = true;

	for (size_t a = 0; a < ctx.args.size(); a++) {
		const string& name = ctx.args[a];
		const pkgmeta* shown = 0;
		pkgmeta best;
		pkgmeta inst;

		const string iv = installed_version(s, name);
		if (!iv.empty()) {
			if (const pkgmeta* stored = s.db.meta(name))
				inst = *stored;
			inst.name = name;
			inst.version = iv;
		}

		bool have_avail = false;
		for (size_t i = 0; i < s.index.size(); i++) {
			if (s.index[i].name == name && (!have_avail || s.res->newer(s.index[i].version, best.version))) {
				best = s.index[i];
				have_avail = true;
			}
		}

		if (have_avail)
			shown = &best;
		else if (!iv.empty())
			shown = &inst;
		else
			throw runtime_error("unable to locate package " + name);

		if (!first)
			cout << endl;
		first = false;

		print_field("Package", shown->name);
		print_field("Version", shown->version);
		print_field("Architecture", shown->arch);
		print_field("Description", shown->description);
		print_field("Depends", shown->depends);
		print_field("Conflicts", shown->conflicts);
		print_field("Provides", shown->provides);
		print_field("Replaces", shown->replaces);
		if (shown->size)
			print_field("Size", itos(shown->size) + " bytes");
		print_field("Filename", shown->filename);
		cout << "Status: " << (iv.empty() ? "not installed" : "installed (" + iv + ")") << endl;
		if (!iv.empty())
			cout << "Installed: " << (s.db.reason(name) == REASON_DEPENDENCY
						? "automatically, as a dependency" : "manually, by request") << endl;
	}
}

// list: what is installed, straight from the database. The repository index
// is only read for --available and --upgradable, so a removed package never
// shows up here just because it is still available.
void cmd_list(context& ctx)
{
	const bool need_index = ctx.opt.available_only || ctx.opt.upgradable_only;
	session s(ctx, false, need_index);
	regex_guard re(ctx.args.empty() ? "" : ctx.args[0], 0);
	map<string, pkgmeta> avail = newest(*s.res, s.index);
	set<string> names;

	if (ctx.opt.available_only) {
		for (map<string, pkgmeta>::const_iterator i = avail.begin(); i != avail.end(); ++i)
			names.insert(i->first);
	} else {
		for (packages_t::const_iterator i = s.db.packages().begin(); i != s.db.packages().end(); ++i)
			names.insert(i->first);
	}

	size_t shown = 0;
	for (set<string>::const_iterator i = names.begin(); i != names.end(); ++i) {
		if (!ctx.args.empty() && !re.matches(*i))
			continue;

		const string inst = installed_version(s, *i);
		map<string, pkgmeta>::const_iterator a = avail.find(*i);
		const bool upgradable = !inst.empty() && a != avail.end() && s.res->newer(a->second.version, inst);

		if (ctx.opt.upgradable_only && !upgradable)
			continue;

		if (ctx.opt.available_only) {
			cout << *i << "/" << a->second.version;
			if (!inst.empty())
				cout << (inst == a->second.version ? " [installed]" : " [installed: " + inst + "]");
			cout << endl;
		} else {
			cout << *i << "/" << inst << " [installed";
			if (upgradable)
				cout << ", upgradable to " << a->second.version;
			cout << "]" << endl;
		}
		shown++;
	}

	if (!shown && isatty(STDOUT_FILENO))
		cout << "No packages found." << endl;
}

void cmd_files(context& ctx)
{
	require_args(ctx, "package");
	const string& arg = ctx.args[0];
	set<string> files;

	database db(ctx.opt.root);
	db_lock lock(ctx.opt.root, false);
	db.open(false);

	if (db.has(arg)) {
		files = db.packages().find(arg)->second.files;
	} else if (file_exists(arg)) {
		files = pkg_open(arg).files;
	} else {
		throw runtime_error(arg + " is neither an installed package nor a package file");
	}

	copy(files.begin(), files.end(), ostream_iterator<string>(cout, "\n"));
}

void cmd_owns(context& ctx)
{
	require_args(ctx, "path pattern");
	database db(ctx.opt.root);
	db_lock lock(ctx.opt.root, false);
	db.open(false);
	regex_guard re(ctx.args[0], 0);

	vector<pair<string, string> > result;
	size_t width = string("Package").size();

	for (packages_t::const_iterator i = db.packages().begin(); i != db.packages().end(); ++i) {
		for (set<string>::const_iterator j = i->second.files.begin(); j != i->second.files.end(); ++j) {
			if (re.matches('/' + *j)) {
				result.push_back(make_pair(i->first, *j));
				width = max(width, i->first.size());
			}
		}
	}

	if (result.empty()) {
		cout << "tatami: no owner(s) found" << endl;
		return;
	}

	cout << left;
	cout.width(width + 2);
	cout << "Package" << "File" << endl;
	for (size_t i = 0; i < result.size(); i++) {
		cout.width(width + 2);
		cout << result[i].first << result[i].second << endl;
	}
}

const command_t commands[] = {
	{ "update",  0,      "update",                   "index local repositories, fetch remote ones (FETCHCMD)",       false, cmd_update },
	{ "index",   0,      "index <dir>...",           "write the repo.solv index of repository directories",      false, cmd_index },
	{ "install", "add",  "install <pkg|file>...",    "install packages (and their dependencies) or upgrade them", true,  cmd_install },
	{ "remove",  "rm",   "remove <package>...",      "remove packages, their dependents and unused dependencies", true,  cmd_remove },
	{ "upgrade", 0,      "upgrade",                  "upgrade all installed packages",                           true,  cmd_upgrade },
	{ "search",  0,      "search <regex>",           "search the repository index (names and descriptions)",     false, cmd_search },
	{ "show",    "info", "show <package>...",        "show package details",                                     false, cmd_show },
	{ "list",    "ls",   "list [regex]",             "list installed packages (--upgradable, --available)",      false, cmd_list },
	{ "files",   0,      "files <package|file>",     "list the files of an installed package or a package file", false, cmd_files },
	{ "owns",    0,      "owns <regex>",             "find the package owning files matching the pattern",       false, cmd_owns },
};

} // namespace

const command_t* find_command(const string& name)
{
	for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
		if (name == commands[i].name || (commands[i].alias && name == commands[i].alias))
			return &commands[i];
	return 0;
}

const command_t* all_commands(size_t& count)
{
	count = sizeof(commands) / sizeof(commands[0]);
	return commands;
}
