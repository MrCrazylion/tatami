#ifndef CONFIG_H
#define CONFIG_H

#include <string>
#include <vector>

using namespace std;

// Built-in defaults. The package extension can be changed at compile time
// (make PKG_EXT=myext, which defines DEFAULT_PKG_EXT) and again at run time
// through PKG_EXT in tatami.conf. Every place that checks or strips the
// extension uses config_t::pkg_ext, which starts out as this value.
#ifndef DEFAULT_PKG_EXT
#define DEFAULT_PKG_EXT         "tar.pkg"
#endif
#define DEFAULT_REPO_DIR        "/var/lib/tatami/packages"
#define TATAMI_CONF             "/etc/tatami.conf"
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
	string pkg_ext;                 // without leading dot, e.g. "tar.pkg"
	vector<string> repo_dirs;       // directories scanned by 'tatami update'
	string arch;                    // empty: use the machine architecture
	string bulkhead;                // tatamk only: "yes" or "no" (build isolation)
	string compression;             // used by tatamk only: gz, xz, zst, bz2 or none
	vector<rule_t> rules;           // UPGRADE/INSTALL rules (as in pkgadd.conf)
};

config_t default_config();

// Reads a configuration file. A missing file is only an error if 'required'.
config_t read_config(const string& filename, bool required);

#endif /* CONFIG_H */
