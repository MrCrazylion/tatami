#ifndef HOOKS_H
#define HOOKS_H

#include <memory>
#include <regex.h>
#include <set>
#include <string>
#include <vector>

using namespace std;

// Post-transaction hooks: nothing about what to run after an installation is
// built into tatami. A hook is a file <root>/etc/tatami/hooks.d/NAME.hook:
//
//   # run ldconfig when libraries or its configuration changed
//   Trigger   = ^usr/lib/            regular expression (POSIX extended) on the
//   Trigger   = ^etc/ld\.so\.conf    changed paths, relative to the root; a
//                                    directory ends in '/'. Several allowed.
//   Operation = install upgrade remove     optional, default: all
//   Needs     = etc/ld.so.conf       optional: skip unless this path exists in the root
//   Exec      = /sbin/ldconfig -r %ROOT%     the command: quotes work, no shell
//
// A hook runs at most once per transaction, after the database commit, and
// only if one of the paths the transaction added, changed or removed matches.
// %ROOT% is replaced by the installation root; TATAMI_ROOT is set too.
// A failing hook is reported but does not undo the transaction.
// Splits a command line into words (quotes and backslashes work, no shell)
vector<string> split_command(const string& line);

class hook_runner {
public:
	// 'root' is the absolute installation root
	explicit hook_runner(const string& root);

	// Reads and checks the hook files now, so that a malformed one stops the
	// transaction before anything was changed. Throws runtime_error.
	void load();

	// Records the paths one package operation changed. 'op' is "install",
	// "upgrade" or "remove".
	void record(const string& op, const set<string>& files);

	// Runs the hooks the recorded changes trigger. Returns the number that failed.
	int run();

private:
	struct hook_t {
		string name;
		vector<string> triggers;
		vector<shared_ptr<regex_t> > regexes;
		set<string> ops;
		string needs;
		string exec;
	};

	bool triggered(const hook_t& hook) const;

	string root_;
	bool loaded_;
	vector<hook_t> hooks_;
	vector<pair<string, string> > changes_;         // (operation, path)
};

// Splits a command line into words the way a shell would for quotes and
// backslashes, without any expansion (public for tests)
vector<string> split_command(const string& line);

#endif /* HOOKS_H */
