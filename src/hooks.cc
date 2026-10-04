#include "hooks.h"
#include "paths.h"
#include "rootfs.h"
#include "util.h"
#include <algorithm>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sys/wait.h>
#include <unistd.h>

static void free_regex(regex_t* re)
{
	regfree(re);
	delete re;
}

vector<string> split_command(const string& line)
{
	vector<string> words;
	string word;
	bool in_word = false;
	char quote = 0;

	for (string::size_type i = 0; i < line.size(); i++) {
		const char c = line[i];

		if (quote == '\'') {
			if (c == '\'')
				quote = 0;
			else
				word += c;
		} else if (quote == '"') {
			if (c == '"')
				quote = 0;
			else if (c == '\\' && i + 1 < line.size() && (line[i + 1] == '"' || line[i + 1] == '\\'))
				word += line[++i];
			else
				word += c;
		} else if (c == '\'' || c == '"') {
			quote = c;
			in_word = true;
		} else if (c == '\\' && i + 1 < line.size()) {
			word += line[++i];
			in_word = true;
		} else if (c == ' ' || c == '\t') {
			if (in_word) {
				words.push_back(word);
				word.clear();
				in_word = false;
			}
		} else {
			word += c;
			in_word = true;
		}
	}

	if (quote)
		throw runtime_error("unterminated quote in: " + line);
	if (in_word)
		words.push_back(word);

	return words;
}

hook_runner::hook_runner(const string& root)
	: root_(root), loaded_(false)
{
	while (root_.size() > 1 && root_[root_.size() - 1] == '/')
		root_.erase(root_.size() - 1);
}

void hook_runner::record(const string& op, const set<string>& files)
{
	for (set<string>::const_iterator i = files.begin(); i != files.end(); ++i)
		changes_.push_back(make_pair(op, *i));
}

void hook_runner::load()
{
	if (loaded_)
		return;
	loaded_ = true;

	const string dir = root_resolve(root_, HOOKS_DIR);
	DIR* d = opendir(dir.c_str());
	if (!d)
		return;         // no hooks configured

	vector<string> names;
	struct dirent* de;
	while ((de = readdir(d))) {
		const string n = de->d_name;
		if (ends_with(n, ".hook") && n.size() > 5)
			names.push_back(n);
	}
	closedir(d);
	sort(names.begin(), names.end());

	for (size_t f = 0; f < names.size(); f++) {
		const string file = dir + "/" + names[f];
		ifstream in(file.c_str());
		if (!in)
			throw runtime_error("could not read " + file);

		hook_t hook;
		hook.name = names[f].substr(0, names[f].size() - 5);

		string line;
		unsigned int lineno = 0;
		while (getline(in, line)) {
			lineno++;
			line = trim(line);
			if (line.empty() || line[0] == '#')
				continue;

			const string where = file + ":" + itos(lineno) + ": ";
			const string::size_type eq = line.find('=');
			if (eq == string::npos)
				throw runtime_error(where + "expected 'Key = value'");

			string key = trim(line.substr(0, eq));
			const string value = trim(line.substr(eq + 1));
			for (string::size_type k = 0; k < key.size(); k++)
				key[k] = tolower((unsigned char)key[k]);

			if (key == "trigger") {
				shared_ptr<regex_t> re(new regex_t, free_regex);
				if (regcomp(re.get(), value.c_str(), REG_EXTENDED | REG_NOSUB))
					throw runtime_error(where + "error compiling regular expression '" + value + "'");
				hook.triggers.push_back(value);
				hook.regexes.push_back(re);
			} else if (key == "operation") {
				vector<string> ops = split(value, " ,\t");
				for (size_t o = 0; o < ops.size(); o++) {
					if (ops[o] != "install" && ops[o] != "upgrade" && ops[o] != "remove")
						throw runtime_error(where + "unknown operation '" + ops[o] + "'");
					hook.ops.insert(ops[o]);
				}
			} else if (key == "needs") {
				hook.needs = value;
			} else if (key == "exec") {
				hook.exec = value;
			} else {
				throw runtime_error(where + "unknown key '" + trim(line.substr(0, eq)) + "'");
			}
		}

		if (hook.triggers.empty())
			throw runtime_error(file + ": hook has no Trigger");
		if (hook.exec.empty())
			throw runtime_error(file + ": hook has no Exec");

		hooks_.push_back(hook);
	}
}

bool hook_runner::triggered(const hook_t& hook) const
{
	for (size_t c = 0; c < changes_.size(); c++) {
		if (!hook.ops.empty() && hook.ops.find(changes_[c].first) == hook.ops.end())
			continue;
		for (size_t r = 0; r < hook.regexes.size(); r++)
			if (!regexec(hook.regexes[r].get(), changes_[c].second.c_str(), 0, 0, 0))
				return true;
	}
	return false;
}

int hook_runner::run()
{
	int failed = 0;

	if (changes_.empty())
		return 0;
	if (!loaded_)
		load();

	for (size_t h = 0; h < hooks_.size(); h++) {
		const hook_t& hook = hooks_[h];

		if (!triggered(hook))
			continue;
		if (!hook.needs.empty() && !file_exists(root_resolve(root_, hook.needs)))
			continue;

		vector<string> argv_s = split_command(hook.exec);
		for (size_t a = 0; a < argv_s.size(); a++) {
			string::size_type pos;
			while ((pos = argv_s[a].find("%ROOT%")) != string::npos)
				argv_s[a].replace(pos, 6, root_);
		}
		if (argv_s.empty())
			continue;

		vector<char*> argv;
		for (size_t a = 0; a < argv_s.size(); a++)
			argv.push_back(const_cast<char*>(argv_s[a].c_str()));
		argv.push_back(0);

		cout << "Running hook " << hook.name << "..." << endl;
		cout.flush();
		cerr.flush();

		pid_t pid = fork();
		if (pid == -1) {
			cerr << "tatami: warning: hook " << hook.name << ": fork failed: " << strerror(errno) << endl;
			failed++;
			continue;
		}
		if (pid == 0) {
			setenv("TATAMI_ROOT", root_.c_str(), 1);
			execvp(argv[0], &argv[0]);
			cerr << "tatami: warning: hook " << hook.name << ": could not run " << argv[0]
			     << ": " << strerror(errno) << endl;
			_exit(127);
		}

		int status = 0;
		while (waitpid(pid, &status, 0) == -1 && errno == EINTR)
			;
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			if (WIFEXITED(status))
				cerr << "tatami: warning: hook " << hook.name << " failed (exit status "
				     << WEXITSTATUS(status) << ")" << endl;
			else
				cerr << "tatami: warning: hook " << hook.name << " was killed by a signal" << endl;
			failed++;
		}
	}

	changes_.clear();
	return failed;
}
