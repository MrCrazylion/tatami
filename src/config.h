#ifndef CONFIG_H
#define CONFIG_H

#include "sign.h"
#include <string>
#include <vector>

using namespace std;

// Built-in defaults. The package extension can be changed at compile time
// (make PKG_EXT=myext, which defines DEFAULT_PKG_EXT) and again at run time
// through PKG_EXT in tatami.conf. Every place that checks or strips the
// extension uses config_t::pkg_ext, which starts out as this value.
//
// The default is tar.pkg. Empty means: tar.<compression>, whatever the compression is
// (every compression is then accepted).
#ifndef DEFAULT_PKG_EXT
#define DEFAULT_PKG_EXT         "tar.pkg"
#endif
// Inside the root, e.g. <root>/etc/tatami/tatami.conf; SYSCONFDIR can be changed at build time
#include "paths.h"
#define TATAMI_CONF             "/" TATAMI_SYSCONFDIR "/tatami/tatami.conf"
// Downloads one remote file; used only for http://, https:// and ftp:// repositories.
// %URL% and %DEST% are replaced; the command is run directly, not through a shell.
// Its stderr is read by tatami, which draws the progress bar from the "NN.N%"
// figures it prints (curl -#); nothing else of its output is shown.
#define DEFAULT_FETCHCMD        "curl -f -L -# \"%URL%\" -o \"%DEST%\""
#define CONF_MAXLINE            1024

enum rule_event_t {
	UPGRADE,
	INSTALL
};

struct rule_t {
	rule_event_t event;
	string pattern;
	bool action;
};

struct config_t {
	string pkg_ext;                 // DEFAULT_PKG_EXT, fixed at build time; empty: tar.<compression>
	vector<string> repo_dirs;       // directories scanned by 'tatami update'
	vector<string> hold_pkgs;       // etc/tatami/hold: installed packages that are never upgraded or removed by a transaction
	string fetchcmd;                // downloads remote repositories (FETCHCMD)
	bool allow_unsigned;            // ALLOW_UNSIGNED: remote data without signatures is accepted
	vector<pubkey_t> trusted_keys;  // the files of etc/tatami/keys: a signature by any of them is good
	string bulkhead;                // tatamk only: "yes" or "no" (build isolation)
	vector<rule_t> rules;           // etc/tatami/upgrade.rules: UPGRADE/INSTALL rules
};

config_t default_config();

// Reads a configuration file. A missing file is only an error if 'required'.
config_t read_config(const string& filename, bool required);

// Fill cfg.hold_pkgs from the hold file (one package name per line) and
// cfg.rules from the rules file. A file that does not exist is ignored.
void read_hold(const string& filename, config_t& cfg);
void read_rules(const string& filename, config_t& cfg);

// Reads every regular file of the directory (not names starting with '.') as a
// public key into cfg.trusted_keys, in name order. A missing directory is fine; a
// file that is not a key is skipped with a warning.
void read_keys(const string& dir, config_t& cfg);

#endif /* CONFIG_H */
