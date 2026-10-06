#ifndef PATHS_H
#define PATHS_H

// Locations below the installation root (--root). All of them are resolved
// with root_resolve(), so they stay inside the root whatever its symlinks say.

// tatami's state, all in one directory: database, journal, metadata, index
#define STATE_DIR       "var/lib/tatami"
#define DB_DIR          STATE_DIR
#define PKG_DB          "var/lib/tatami/db"
#define PKG_META_DIR    "var/lib/tatami/meta"            // per-package metadata, install reason
#define PKG_REJECTED    "var/lib/tatami/rejected"        // kept-away new versions of config files
#define JOURNAL_FILE    "var/lib/tatami/transaction.journal"
#define DEFAULT_REPO_REL "var/lib/tatami/packages"       // repository used when none is configured

#define REPOS_CONF      "etc/tatami/repos.conf"          // name=url lines
#define REPOS_DIR       "etc/tatami/repos.d"             // *.conf files of the same form
#define REPO_CACHE      "var/lib/tatami/repos"           // downloaded indexes: <name>/repo.solv
#define PKG_CACHE       "var/cache/tatami/packages"      // downloaded package files

#define HOOKS_DIR       "etc/tatami/hooks.d"

#endif /* PATHS_H */
