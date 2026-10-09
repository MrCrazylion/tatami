#ifndef CONFIG_H
#define CONFIG_H

#include <string>
#include <vector>

using namespace std;

// Built-in defaults. The package extension can be changed at compile time
// (make PKG_EXT=myext, which defines DEFAULT_PKG_EXT) and again at run time
// through PKG_EXT in tatami.conf. Every place that checks or strips the
// extension uses config_t::pkg_ext, which starts out as this value.
//
// Empty (the default) means: tar.<compression>, whatever the compression is.
#ifndef DEFAULT_PKG_EXT
#define DEFAULT_PKG_EXT         ""
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
	string pkg_ext;                 // without leading dot, empty: tar.<compression>
	vector<string> repo_dirs;       // directories scanned by 'tatami update'
	vector<string> hold_pkgs;       // HoldPkg: installed packages that are never upgraded or removed by a transaction
	string fetchcmd;                // downloads remote repositories (FETCHCMD)
	string pubkey;                  // PUBKEY: Ed25519 public key (hex or base64), or "none"
	bool have_pubkey;               // pubkey_bytes is valid
	unsigned char pubkey_bytes[32];
	string arch;                    // empty: use the machine architecture
	string bulkhead;                // tatamk only: "yes" or "no" (build isolation)
	string compression;             // used by tatamk only: gz, xz, zst, bz2 or none
	vector<rule_t> rules;           // UPGRADE/INSTALL rules (as in pkgadd.conf)
};

config_t default_config();

// Reads a configuration file. A missing file is only an error if 'required'.
config_t read_config(const string& filename, bool required);

#endif /* CONFIG_H */
