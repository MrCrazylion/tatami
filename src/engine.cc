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

set<string> engine::make_keep_list(const set<string>& files) const
{
	set<string> keep_list;

	for (set<string>::const_iterator i = files.begin(); i != files.end(); ++i) {
		// The last matching rule wins
		for (vector<compiled_rule>::const_reverse_iterator j = rules_.rbegin(); j != rules_.rend(); ++j) {
			if (j->event == UPGRADE && rule_applies(*j, *i)) {
				if (!j->action)
					keep_list.insert(keep_list.end(), *i);
				break;
			}
		}
	}

	return keep_list;
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

void engine::install(const string& filename, bool requested)
{
	package_t package = pkg_open(filename);
	const string& name = package.meta.name;
	const bool installed = db_.has(name);

	pkgrecord rec;
	rec.version = package.meta.version;
	rec.files = package.files;

	set<string> non_install_files = apply_install_rules(rec.files);
	set<string> conflicting_files = db_.find_conflicts(name, rec.files);

	if (!conflicting_files.empty() && !force_) {
		copy(conflicting_files.begin(), conflicting_files.end(), ostream_iterator<string>(cerr, "\n"));
		throw runtime_error("listed file(s) already installed (use -f to ignore and overwrite)");
	}

	set<string> keep_list;
	if (installed)
		keep_list = make_keep_list(rec.files);

	// A package that is already installed keeps its reason, unless the user now
	// asks for it explicitly. One that is not installed yet is explicit only if
	// the user asked for it.
	string reason = requested ? REASON_EXPLICIT : REASON_DEPENDENCY;
	if (installed && !requested)
		reason = db_.reason(name);

	// Files of the old version that the new one no longer has are deleted only
	// once everything else succeeded
	set<string> stale = db_.stale_files(name, rec.files);

	txn tx(db_.path(JOURNAL_FILE));
	tx.begin(name, rec.version);

	try {
		pkg_install(UTILNAME, db_.root(), filename, keep_list, non_install_files, tx);

		// -f: the new package takes the files over from their previous owners
		// (their on-disk copy is simply overwritten by the extraction)
		if (!conflicting_files.empty())
			db_.unreference(conflicting_files);

		for (set<string>::const_iterator i = stale.begin(); i != stale.end(); ++i) {
			const string path = db_.path(*i);
			struct stat st;
			// a directory entry that is a symbolic link here is the base system's, not ours
			if ((*i)[i->length() - 1] == '/' && lstat(path.c_str(), &st) == 0 && S_ISLNK(st.st_mode))
				continue;
			tx.defer_delete(path);
		}

		db_.add_pkg(name, rec, package.meta, reason);
		db_.commit();
	} catch (runtime_error& e) {
		tx.rollback();
		db_.open(true);         // forget the changes made in memory
		throw runtime_error("installing " + name + " " + rec.version + " failed, nothing was changed: " + e.what());
	}

	tx.commit();

	// What this installation changed on the system: the new files and the old
	// version's files that are gone
	set<string> changed = rec.files;
	changed.insert(stale.begin(), stale.end());
	hooks_.record(installed ? "upgrade" : "install", changed);
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

void engine::remove(const string& name)
{
	if (!db_.has(name))
		throw runtime_error("package " + name + " not installed");

	const set<string> files = db_.packages().find(name)->second.files;

	db_.rm_pkg(name);
	db_.commit();

	hooks_.record("remove", files);
}
