#ifndef PATHS_H
#define PATHS_H

// Locations below the installation root (--root). All of them are resolved
// with root_resolve(), so they stay inside the root whatever its symlinks say.

// The base directories can be chosen at build time (config.mk or the make command
// line: SYSCONFDIR, DB_DIR, CACHEDIR). The Makefile passes them as
// TATAMI_SYSCONFDIR, TATAMI_DB_DIR and TATAMI_CACHEDIR, always relative to the root
// (no leading slash). Without them these are the defaults.
#ifndef TATAMI_SYSCONFDIR
#define TATAMI_SYSCONFDIR "etc"
#endif
#ifndef TATAMI_DB_DIR
#define TATAMI_DB_DIR   "var/lib/tatami"
#endif
#ifndef TATAMI_CACHEDIR
#define TATAMI_CACHEDIR "var/cache/tatami"
#endif

// tatami's state, all in one directory: database, journal, metadata, index
#define STATE_DIR       TATAMI_DB_DIR
#define DB_DIR          STATE_DIR
#define PKG_DB          STATE_DIR "/db"
#define PKG_META_DIR    STATE_DIR "/meta"                // per-package metadata, install reason
#define PKG_REJECTED    STATE_DIR "/rejected"            // kept-away new versions of config files
#define JOURNAL_FILE    STATE_DIR "/transaction.journal"
#define DEFAULT_REPO_REL STATE_DIR "/packages"           // repository used when none is configured

#define TATAMI_ETC      TATAMI_SYSCONFDIR "/tatami"
#define REPOS_CONF      TATAMI_ETC "/repos.conf"         // name=url lines
#define REPOS_DIR       TATAMI_ETC "/repos.d"            // *.conf files of the same form
#define REPO_CACHE      STATE_DIR "/repos"               // downloaded indexes: <name>/repo.solv
#define PKG_CACHE       TATAMI_CACHEDIR "/packages"      // downloaded package files

#define HOOKS_DIR       TATAMI_ETC "/hooks.d"

#endif /* PATHS_H */
