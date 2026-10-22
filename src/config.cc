#include "config.h"
#include "sign.h"
#include "util.h"
#include <fstream>
#include <sstream>
#include <algorithm>
#include <dirent.h>
#include <sys/stat.h>
#include <iostream>

static string unquote(const string& s)
{
	if (s.size() >= 2 && (s[0] == '"' || s[0] == '\'') && s[s.size() - 1] == s[0])
		return s.substr(1, s.size() - 2);
	return s;
}

config_t default_config()
{
	config_t cfg;
	cfg.pkg_ext = DEFAULT_PKG_EXT;
	cfg.fetchcmd = DEFAULT_FETCHCMD;
	cfg.allow_unsigned = false;
	// no repository listed: <root>/var/lib/tatami/packages (worked out per root)
	return cfg;
}

config_t read_config(const string& filename, bool required)
{
	config_t cfg = default_config();
	ifstream in(filename.c_str());

	if (!in) {
		if (required)
			throw runtime_error("could not read configuration file " + filename);
		return cfg;
	}

	string line;
	unsigned int linecount = 0;

	while (getline(in, line)) {
		linecount++;
		line = trim(line);
		if (line.empty() || line[0] == '#')
			continue;

		const string where = filename + ":" + itos(linecount) + ": ";

		if (line.length() >= CONF_MAXLINE)
			throw runtime_error(where + "line too long, aborting");

		// A setting is "KEY = value" (blanks around '=' allowed); anything
		// else is an UPGRADE/INSTALL rule.
		const string::size_type eq = line.find('=');
		const string key = eq == string::npos ? string() : trim(line.substr(0, eq));
		const bool is_setting = !key.empty() &&
			key.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_") == string::npos;

		if (is_setting) {
			const string value = unquote(trim(line.substr(eq + 1)));

			if (key == "PKG_EXT" || key == "PKG_COMPRESSION") {
				throw runtime_error(where + key + " is a compile-time setting and can no longer be set here: "
						    "set it in build.conf (or 'make " + key + "=...') and rebuild");
			} else if (key == "REPO_DIRS") {
				throw runtime_error(where + "REPO_DIRS is gone: list the repositories in " REPOS_CONF);
			} else if (key == "FETCHCMD") {
				if (value.empty())
					throw runtime_error(where + "FETCHCMD is empty");
				cfg.fetchcmd = value;
			} else if (key == "ALLOW_UNSIGNED") {
				if (value != "yes" && value != "no")
					throw runtime_error(where + "invalid ALLOW_UNSIGNED '" + value + "', should be yes or no");
				cfg.allow_unsigned = value == "yes";
			} else if (key == "PUBKEY") {
				throw runtime_error(where + "PUBKEY is gone: put the public key file into " KEYS_DIR "/");
			} else if (key == "HoldPkg" || key == "HOLDPKG") {
				throw runtime_error(where + "HoldPkg moved to " + HOLD_FILE + ", one package name per line");
			} else if (key == "ARCH") {
				throw runtime_error(where + "ARCH is gone: tatami uses the machine architecture (uname)");
			} else {
				throw runtime_error(where + "unknown setting '" + key + "', aborting");
			}
		} else {
			throw runtime_error(where + "'" + line + "' is not a setting (UPGRADE/INSTALL rules live in " + RULES_FILE + ")");
		}
	}

	return cfg;
}

// Files next to tatami.conf: the list of held packages and the file rules.
// A missing file is fine, it just means nothing is held / no rule.
void read_hold(const string& filename, config_t& cfg)
{
	ifstream in(filename.c_str());
	string line;

	while (getline(in, line)) {
		line = trim(line);
		if (line.empty() || line[0] == '#')
			continue;
		vector<string> names = split(line, " \t");     // one name per line; trailing words are ignored
		cfg.hold_pkgs.push_back(names[0]);
	}
}

void read_rules(const string& filename, config_t& cfg)
{
	ifstream in(filename.c_str());
	string line;
	unsigned int linecount = 0;

	while (getline(in, line)) {
		linecount++;
		line = trim(line);
		if (line.empty() || line[0] == '#')
			continue;

		const string where = filename + ":" + itos(linecount) + ": ";

		if (line.length() >= CONF_MAXLINE)
			throw runtime_error(where + "line too long, aborting");

		// UPGRADE|INSTALL <pattern> YES|NO
		istringstream fields(line);
		string event, pattern, action, extra;

		fields >> event >> pattern >> action;
		if (action.empty() || (fields >> extra))
			throw runtime_error(where + "wrong number of arguments, aborting");

		rule_t rule;
		if (event == "UPGRADE")
			rule.event = UPGRADE;
		else if (event == "INSTALL")
			rule.event = INSTALL;
		else
			throw runtime_error(where + "'" + event + "' unknown event, aborting");

		rule.pattern = pattern;
		if (action == "YES")
			rule.action = true;
		else if (action == "NO")
			rule.action = false;
		else
			throw runtime_error(where + "'" + action + "' unknown action, should be YES or NO, aborting");

		cfg.rules.push_back(rule);
	}
}

void read_keys(const string& dir, config_t& cfg)
{
	DIR* d = opendir(dir.c_str());
	if (!d)
		return;

	vector<string> names;
	while (struct dirent* e = readdir(d)) {
		const string n = e->d_name;
		if (n[0] != '.')
			names.push_back(n);
	}
	closedir(d);
	sort(names.begin(), names.end());

	for (size_t i = 0; i < names.size(); i++) {
		const string path = dir + "/" + names[i];
		struct stat st;
		if (stat(path.c_str(), &st) == -1 || !S_ISREG(st.st_mode))
			continue;

		pubkey_t key;
		key.file = path;
		ifstream in(path.c_str());
		string text;
		getline(in, text);
		if (text.size() > 256 || !decode_pubkey(text, key.bytes)) {
			cerr << "tatami: warning: " << path << " is not a public key (64 hex digits or base64), ignored" << endl;
			continue;
		}
		cfg.trusted_keys.push_back(key);
	}
}
