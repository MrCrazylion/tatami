#include "engine.h"
#include "pkgarchive.h"
#include "paths.h"
#include "util.h"
#include <iostream>
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
	: db_(db), force_(force)
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

void engine::install(const string& filename)
{
	package_t package = pkg_open(filename);
	const string& name = package.meta.name;
	const bool installed = db_.has(name);

	pkgrecord rec;
	rec.version = package.meta.version;
	rec.files = package.files;

	set<string> non_install_files = apply_install_rules(rec.files);
	set<string> conflicting_files = db_.find_conflicts(name, rec.files);

	if (!conflicting_files.empty()) {
		if (force_) {
			set<string> keep_list;
			if (installed) // Don't remove files matching the rules in configuration
				keep_list = make_keep_list(conflicting_files);
			db_.rm_files(conflicting_files, keep_list); // Remove unwanted conflicts
		} else {
			copy(conflicting_files.begin(), conflicting_files.end(), ostream_iterator<string>(cerr, "\n"));
			throw runtime_error("listed file(s) already installed (use -f to ignore and overwrite)");
		}
	}

	set<string> keep_list;

	if (installed) {
		keep_list = make_keep_list(rec.files);
		db_.rm_pkg(name, keep_list);
	}

	db_.add_pkg(name, rec, package.meta);
	db_.commit();

	try {
		pkg_install(UTILNAME, db_.root(), filename, keep_list, non_install_files, installed);
	} catch (runtime_error& e) {
		if (!installed) {
			db_.rm_pkg(name);
			db_.commit();
			throw runtime_error(string("installing ") + name + " failed: " + e.what());
		}
		cerr << UTILNAME << ": " << e.what() << endl;
	}
}

void engine::remove(const string& name)
{
	if (!db_.has(name))
		throw runtime_error("package " + name + " not installed");

	db_.rm_pkg(name);
	db_.commit();
}

void engine::ldconfig() const
{
	// Only execute ldconfig if /etc/ld.so.conf exists
	if (!file_exists(db_.root() + LDCONFIG_CONF) || access(LDCONFIG, X_OK) != 0)
		return;

	pid_t pid = fork();

	if (pid == -1)
		throw runtime_error_with_errno("fork() failed");

	if (pid == 0) {
		execl(LDCONFIG, LDCONFIG, "-r", db_.root().c_str(), (char*)0);
		cerr << UTILNAME << ": could not execute " << LDCONFIG << ": " << strerror(errno) << endl;
		_exit(EXIT_FAILURE);
	}

	if (waitpid(pid, 0, 0) == -1)
		throw runtime_error_with_errno("waitpid() failed");
}
