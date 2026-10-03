#include "commands.h"
#include "db.h"
#include "engine.h"
#include "meta.h"
#include "paths.h"
#include "pkgarchive.h"
#include "resolver.h"
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

namespace {

//
// Helpers
//

bool is_package_file(const context& ctx, const string& arg)
{
	return arg.find('/') != string::npos || ends_with(arg, "." + ctx.cfg.pkg_ext);
}

string index_path(const context& ctx)
{
	return trim_filename(ctx.opt.root + "/" + PKG_INDEX);
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
// Repository index
//

// Scans the configured repositories. Returns the number of readable ones in
// 'readable'. Unreadable packages are skipped with a warning.
vector<pkgmeta> scan_repos(const context& ctx, bool verbose, size_t& readable)
{
	vector<pkgmeta> index;
	const string suffix = "." + ctx.cfg.pkg_ext;
	set<string> seen;

	readable = 0;
	for (size_t r = 0; r < ctx.cfg.repo_dirs.size(); r++) {
		const string& dir = ctx.cfg.repo_dirs[r];
		DIR* d = opendir(dir.c_str());
		if (!d) {
			cerr << "tatami: warning: could not read repository " << dir << ": " << strerror(errno) << endl;
			continue;
		}
		readable++;

		vector<string> names;
		struct dirent* de;
		while ((de = readdir(d)))
			if (ends_with(de->d_name, suffix) && string(de->d_name).size() > suffix.size())
				names.push_back(de->d_name);
		closedir(d);
		sort(names.begin(), names.end());

		size_t count = 0;
		for (size_t i = 0; i < names.size(); i++) {
			try {
				const string path = real_path(dir + "/" + names[i]);
				struct stat st;
				if (stat(path.c_str(), &st) == -1 || !S_ISREG(st.st_mode))
					continue;
				pkgmeta meta = pkg_read_meta(path);
				meta.filename = path;
				meta.size = st.st_size;
				string fname, fversion;
				if (!split_package_filename(path, ctx.cfg.pkg_ext, fname, fversion) ||
				    fname != meta.name || fversion != meta.version)
					cerr << "tatami: warning: " << path << " is named differently from its contents ("
					     << meta.name << "_" << meta.version << "." << ctx.cfg.pkg_ext
					     << "); the contents are used" << endl;
				if (!seen.insert(meta.name + "_" + meta.version).second) {
					cerr << "tatami: warning: skipping " << path << ": " << meta.name << " "
					     << meta.version << " is already in the index" << endl;
					continue;
				}
				index.push_back(meta);
				count++;
			} catch (runtime_error& e) {
				cerr << "tatami: warning: skipping " << dir << "/" << names[i] << ": " << e.what() << endl;
			}
		}
		if (verbose)
			cout << "Repository " << dir << ": " << count << " package" << (count == 1 ? "" : "s") << endl;
	}

	return index;
}

void write_index(const context& ctx, const vector<pkgmeta>& index)
{
	const string path = index_path(ctx);
	const string tmp = path + ".tmp";
	mkdir_p(trim_filename(ctx.opt.root + "/" + PKG_DIR));

	ofstream out(tmp.c_str());
	for (size_t i = 0; i < index.size(); i++)
		out << format_meta(index[i]) << "\n";
	out.close();
	if (!out) {
		int e = errno;
		unlink(tmp.c_str());
		throw runtime_error_with_errno("could not write " + path, e);
	}
	if (rename(tmp.c_str(), path.c_str()) == -1) {
		int e = errno;
		unlink(tmp.c_str());
		throw runtime_error_with_errno("could not write " + path, e);
	}
}

// The index is stale when it is missing or a repository directory changed
// (package added or removed) after it was written.
bool index_stale(const context& ctx)
{
	struct stat ist;
	if (stat(index_path(ctx).c_str(), &ist) == -1)
		return true;

	for (size_t r = 0; r < ctx.cfg.repo_dirs.size(); r++) {
		struct stat dst;
		if (stat(ctx.cfg.repo_dirs[r].c_str(), &dst) == -1)
			continue;
		if (dst.st_mtime >= ist.st_mtime)
			return true;
	}

	return false;
}

// Everything a command needs: database (locked), solver loaded with the
// installed packages and the repository index. The index is refreshed
// automatically when the repositories changed, so no separate 'update' is
// needed before install/upgrade/search.
struct session {
	unique_ptr<db_lock> lock;
	database db;
	unique_ptr<resolver> res;
	vector<pkgmeta> index;

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
			if (index_stale(ctx)) {
				size_t readable;
				index = scan_repos(ctx, false, readable);
				// Persist it when we are allowed to; otherwise use it in memory
				if (exclusive && readable) {
					write_index(ctx, index);
					cerr << "tatami: package index refreshed (" << index.size() << " packages)" << endl;
				}
			} else {
				index = read_index(index_path(ctx));
			}
			res->add_available(index);
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
		if (st.kind == plan_step::REMOVE)
			continue;
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

	engine eng(ctx.cfg, s.db, ctx.opt.force);
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
	}

	eng.ldconfig();
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
					throw runtime_error(string(e.what()) + " (the package index is empty, try 'tatami update')");
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
// update: build the repository index explicitly
//

void cmd_update(context& ctx)
{
	if (ctx.opt.simulate) {
		size_t readable;
		vector<pkgmeta> index = scan_repos(ctx, true, readable);
		cout << "Would update the package index: " << index.size() << " package"
		     << (index.size() == 1 ? "" : "s") << " available" << endl;
		return;
	}

	db_lock lock(ctx.opt.root, true);
	size_t readable;
	vector<pkgmeta> index = scan_repos(ctx, true, readable);

	// Never replace a good index by an empty one because nothing was readable
	if (!readable)
		throw runtime_error("none of the repositories could be read, keeping the old package index");

	write_index(ctx, index);
	cout << "Package index updated: " << index.size() << " package" << (index.size() == 1 ? "" : "s") << " available" << endl;
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
	{ "update",  0,      "update",                   "build the package index from the configured repositories", true,  cmd_update },
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
