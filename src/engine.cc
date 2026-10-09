#include "engine.h"
#include "pkgarchive.h"
#include "txn.h"
#include "paths.h"
#include "rootfs.h"
#include "util.h"
#include <iostream>
#include <sys/stat.h>
#include <iterator>
#include <algorithm>
#include <sys/wait.h>
#include <csignal>
#include <sys/statvfs.h>
#include <unistd.h>

static const char* UTILNAME = "tatami";

static void free_regex(regex_t* re)
{
	regfree(re);
	delete re;
}

engine::engine(const config_t& cfg, database& db, bool force)
	: db_(db), force_(force), hooks_(db.root())
{
	for (vector<rule_t>::const_iterator i = cfg.rules.begin(); i != cfg.rules.end(); ++i) {
		compiled_rule rule;
		regex_t* re = new regex_t;
		if (regcomp(re, i->pattern.c_str(), REG_EXTENDED | REG_NOSUB)) {
			delete re;
			throw runtime_error("error compiling regular expression '" + i->pattern + "', aborting");
		}
		rule.event = i->event;
		rule.action = i->action;
		rule.re = shared_ptr<regex_t>(re, free_regex);
		rules_.push_back(rule);
	}
}

bool engine::rule_applies(const compiled_rule& rule, const string& file) const
{
	return !regexec(rule.re.get(), file.c_str(), 0, 0, 0);
}

set<string> engine::make_config_list(const set<string>& files) const
{
	set<string> config_list;

	for (set<string>::const_iterator i = files.begin(); i != files.end(); ++i) {
		// The last matching rule wins
		for (vector<compiled_rule>::const_reverse_iterator j = rules_.rbegin(); j != rules_.rend(); ++j) {
			if (j->event == UPGRADE && rule_applies(*j, *i)) {
				if (!j->action)
					config_list.insert(config_list.end(), *i);
				break;
			}
		}
	}

	return config_list;
}

set<string> engine::apply_install_rules(set<string>& files) const
{
	set<string> install_set;
	set<string> non_install_set;

	for (set<string>::const_iterator i = files.begin(); i != files.end(); ++i) {
		bool install_file = true;

		for (vector<compiled_rule>::const_reverse_iterator j = rules_.rbegin(); j != rules_.rend(); ++j) {
			if (j->event == INSTALL && rule_applies(*j, *i)) {
				install_file = j->action;
				break;
			}
		}

		if (install_file)
			install_set.insert(install_set.end(), *i);
		else
			non_install_set.insert(*i);
	}

	files = install_set;
	return non_install_set;
}

void engine::begin()
{
	if (tx_)
		throw runtime_error("a transaction is already open");
	tx_.reset(new txn(db_.path(JOURNAL_FILE)));
	tx_->begin();
	post_scripts_.clear();
	doomed_.clear();
	hook_log_.clear();
}

static string mib(unsigned long long bytes)
{
	return itos((bytes + (1 << 20) - 1) >> 20) + " MiB";
}

void engine::check_disk_space(const vector<string>& package_files)
{
	struct statvfs vfs;
	if (statvfs(db_.root().c_str(), &vfs) == -1 || vfs.f_frsize == 0)
		return;

	// Upgrades free their old files only at the commit, so every package counts in full.
	// Each file wastes about half a block on top of its size.
	unsigned long long need = 0;
	for (size_t i = 0; i < package_files.size(); i++) {
		const package_t p = pkg_open(package_files[i]);
		need += p.bytes + p.entries * (vfs.f_frsize / 2);
	}
	// small safety margin: 5% and 8 MiB (journal, database, backups' metadata)
	need += need / 20 + (8ULL << 20);

	const unsigned long long have = (unsigned long long)vfs.f_bavail * vfs.f_frsize;
	if (need > have)
		throw runtime_error("not enough disk space on " + db_.root() + ": " + mib(need) +
				    " needed (including a safety margin), " + mib(have) + " available. "
				    "Nothing has been changed.");
}

void engine::discard_when_committed(const string& cached_file)
{
	cache_files_.push_back(cached_file);
}

// The script is written to a private temporary file, then bash sources it and calls
// the one function with the version. No shell command line is built from package data.
bool engine::run_script(const string& script, const char* function, const string& version) const
{
	char path[] = "/tmp/tatami-install-XXXXXX";
	const int fd = mkstemp(path);
	if (fd == -1)
		throw runtime_error_with_errno("could not create a temporary file for the install script");

	size_t done = 0;
	while (done < script.size()) {
		const ssize_t n = write(fd, script.data() + done, script.size() - done);
		if (n == -1 && errno == EINTR)
			continue;
		if (n <= 0) {
			const int e = errno;
			close(fd);
			unlink(path);
			throw runtime_error_with_errno("could not write the install script", e);
		}
		done += (size_t)n;
	}
	close(fd);

	const string code = string("source \"$1\" || exit 1; if declare -F ") + function +
			    " >/dev/null; then " + function + " \"$2\"; fi";
	cout.flush();
	cerr.flush();
	pid_t pid = fork();
	if (pid == -1) {
		const int e = errno;
		unlink(path);
		throw runtime_error_with_errno("could not run the install script", e);
	}
	if (pid == 0) {
		setenv("TATAMI_ROOT", db_.root().c_str(), 1);
		execlp("bash", "bash", "-c", code.c_str(), "tatami-install", path, version.c_str(), (char*)0);
		cerr << "tatami: could not run bash: " << strerror(errno) << endl;
		_exit(127);
	}

	int status = 0;
	while (waitpid(pid, &status, 0) == -1 && errno == EINTR)
		;
	unlink(path);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

void engine::install(const string& filename, bool requested)
{
	if (!tx_)
		throw runtime_error("internal error: install outside of a transaction");

	package_t package = pkg_open(filename);
	const string& name = package.meta.name;
	const bool installed = db_.has(name);

	pkgrecord rec;
	rec.version = package.meta.version;
	rec.files = package.files;

	set<string> non_install_files = apply_install_rules(rec.files);
	// files of packages removed earlier in this run are still on disk, but are not in the way
	set<string> conflicting_files = db_.find_conflicts(name, rec.files, doomed_);

	if (!conflicting_files.empty() && !force_) {
		copy(conflicting_files.begin(), conflicting_files.end(), ostream_iterator<string>(cerr, "\n"));
		throw runtime_error("listed file(s) already installed (use -f to ignore and overwrite)");
	}

	set<string> config_list;
	if (installed)
		config_list = make_config_list(rec.files);

	// A package that is already installed keeps its reason, unless the user now
	// asks for it explicitly. One that is not installed yet is explicit only if
	// the user asked for it.
	string reason = requested ? REASON_EXPLICIT : REASON_DEPENDENCY;
	if (installed && !requested)
		reason = db_.reason(name);

	// Files of the old version that the new one no longer has are deleted only
	// when the whole transaction commits
	set<string> stale = db_.stale_files(name, rec.files);

	try {
		tx_->note_install(name, rec.version);
		// pre_install: before anything of this package is extracted; a failure stops
		// the whole transaction (and so rolls it back)
		if (!package.install_script.empty()) {
			cout << "Running pre_install of " << name << "..." << endl;
			if (!run_script(package.install_script, "pre_install", rec.version))
				throw runtime_error("pre_install of " + name + " failed");
		}
		pkg_install(UTILNAME, db_.root(), filename, config_list, non_install_files, *tx_);

		// -f: the new package takes the files over from their previous owners
		// (their on-disk copy is simply overwritten by the extraction)
		if (!conflicting_files.empty())
			db_.unreference(conflicting_files);

		db_.add_pkg(name, rec, package.meta, reason);
		if (!package.install_script.empty()) {
			post_script ps = { name, rec.version, package.install_script };
			post_scripts_.push_back(ps);
		}
	} catch (runtime_error& e) {
		throw runtime_error("installing " + name + " " + rec.version + " failed: " + e.what());
	}

	doomed_.insert(stale.begin(), stale.end());

	// What this installation changes on the system: the new files and the old
	// version's files that are going away
	set<string> changed = rec.files;
	changed.insert(stale.begin(), stale.end());
	hook_log_.push_back(make_pair(string(installed ? "upgrade" : "install"), changed));
}

void engine::remove(const string& name)
{
	if (!tx_)
		throw runtime_error("internal error: remove outside of a transaction");
	if (!db_.has(name))
		throw runtime_error("package " + name + " not installed");

	const set<string> files = db_.packages().find(name)->second.files;

	tx_->note_remove(name);
	db_.drop_pkg(name);
	doomed_.insert(files.begin(), files.end());
	hook_log_.push_back(make_pair(string("remove"), files));
}

// Kills the process like a power cut would, for the crash recovery tests:
// TATAMI_CRASH_AT=extracted (before the database commit) or =committed (after it)
static void crash_point(const char* stage)
{
	const char* at = getenv("TATAMI_CRASH_AT");
	if (at && string(at) == stage)
		kill(getpid(), SIGKILL);
}

void engine::commit()
{
	if (!tx_)
		throw runtime_error("internal error: commit outside of a transaction");

	// What goes: everything that was removed or dropped and that no package of the
	// final state owns (a new package may have taken a file over)
	const set<string> owned = db_.owned_files();
	for (set<string>::const_iterator i = doomed_.begin(); i != doomed_.end(); ++i) {
		if (owned.find(*i) != owned.end())
			continue;
		const string path = db_.path(*i);
		struct stat st;
		// a directory entry that is a symbolic link here is the base system's, not ours
		if ((*i)[i->length() - 1] == '/' && lstat(path.c_str(), &st) == 0 && S_ISLNK(st.st_mode))
			continue;
		tx_->defer_delete(path);
	}

	tx_->commit_point();
	crash_point("extracted");
	db_.commit();
	crash_point("committed");
	tx_->commit();
	tx_.reset();

	for (size_t i = 0; i < hook_log_.size(); i++)
		hooks_.record(hook_log_[i].first, hook_log_[i].second);
	hook_log_.clear();
	doomed_.clear();

	// post_install: the files are committed, so a failure is only reported
	for (size_t i = 0; i < post_scripts_.size(); i++) {
		cout << "Running post_install of " << post_scripts_[i].name << "..." << endl;
		try {
			if (!run_script(post_scripts_[i].text, "post_install", post_scripts_[i].version))
				cerr << "tatami: warning: post_install of " << post_scripts_[i].name << " failed" << endl;
		} catch (runtime_error& e) {
			cerr << "tatami: warning: post_install of " << post_scripts_[i].name << ": " << e.what() << endl;
		}
	}
	post_scripts_.clear();

	// The transaction is done: the packages it downloaded are no longer needed
	const string cache = db_.path(PKG_CACHE) + "/";
	for (size_t i = 0; i < cache_files_.size(); i++) {
		const string& f = cache_files_[i];
		if (f.compare(0, cache.size(), cache) != 0 || f.find("/", cache.size()) != string::npos)
			continue;       // never anything outside the cache directory
		unlink(f.c_str());
		unlink((f + ".sig").c_str());
	}
	cache_files_.clear();
}

void engine::rollback()
{
	if (!tx_)
		return;
	tx_->rollback();
	tx_.reset();
	db_.open(true);         // forget the changes made in memory
	hook_log_.clear();
	doomed_.clear();
	post_scripts_.clear();
	cache_files_.clear();   // the cache is left as it is: a retry does not download again
}

void engine::check_hooks()
{
	hooks_.load();
}

int engine::run_hooks()
{
	return hooks_.run();
}

void engine::mark_explicit(const string& name)
{
	if (!db_.has(name))
		throw runtime_error("package " + name + " not installed");
	db_.set_reason(name, REASON_EXPLICIT);
	db_.commit();
}
