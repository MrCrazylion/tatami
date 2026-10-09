#include "config.h"
#include "sign.h"
#include "util.h"
#include <fstream>
#include <sstream>

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
	cfg.have_pubkey = false;
	// no repository listed: <root>/var/lib/tatami/packages (worked out per root)
	return cfg;
}

static string check_ext(const string& value, const string& where)
{
	string ext = value;

	while (!ext.empty() && ext[0] == '.')
		ext.erase(0, 1);

	if (ext.find_first_not_of(
	    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") != string::npos)
		throw runtime_error(where + "invalid PKG_EXT '" + value + "'");

	return ext;
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
	bool repos_set = false;

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

			if (key == "PKG_EXT") {
				cfg.pkg_ext = check_ext(value, where);
			} else if (key == "REPO_DIRS") {
				if (!repos_set)
					cfg.repo_dirs.clear();
				repos_set = true;
				// separated by blanks; a plain path list may also use ':' (not inside a URL)
				vector<string> words = split(value, " \t");
				for (size_t w = 0; w < words.size(); w++) {
					if (words[w].find("://") != string::npos) {
						cfg.repo_dirs.push_back(words[w]);
					} else {
						vector<string> dirs = split(words[w], ":");
						cfg.repo_dirs.insert(cfg.repo_dirs.end(), dirs.begin(), dirs.end());
					}
				}
			} else if (key == "HoldPkg" || key == "HOLDPKG") {
				// space-separated package names; may be given several times
				vector<string> names = split(value, " \t");
				cfg.hold_pkgs.insert(cfg.hold_pkgs.end(), names.begin(), names.end());
			} else if (key == "FETCHCMD") {
				if (value.empty())
					throw runtime_error(where + "FETCHCMD is empty");
				cfg.fetchcmd = value;
			} else if (key == "PUBKEY") {
				if (value == "none") {
					cfg.pubkey = value;
					cfg.have_pubkey = false;
				} else if (decode_pubkey(value, cfg.pubkey_bytes)) {
					cfg.pubkey = value;
					cfg.have_pubkey = true;
				} else {
					throw runtime_error(where + "invalid PUBKEY (expected 64 hex digits or a 32-byte base64 key, or none)");
				}
			} else if (key == "ARCH") {
				cfg.arch = value;
			} else if (key == "BULKHEAD") {
				if (value != "yes" && value != "no")
					throw runtime_error(where + "invalid BULKHEAD '" + value + "', should be yes or no");
				cfg.bulkhead = value;
			} else if (key == "PKG_COMPRESSION") {
				if (value != "gz" && value != "xz" && value != "zst" && value != "bz2" && value != "lz4" && value != "lzma" && value != "none")
					throw runtime_error(where + "invalid PKG_COMPRESSION '" + value + "'");
				cfg.compression = value;
			} else {
				throw runtime_error(where + "unknown setting '" + key + "', aborting");
			}
		} else {
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

	return cfg;
}
