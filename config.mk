# Build-time configuration of tatami. Edit this file before running 'make'.
#
# The make command line still wins over this file (make PREFIX=/opt install),
# and so does the environment, because every line uses '?='.

# Where 'make install' puts things (not compiled in)
DESTDIR ?=
PREFIX ?= /usr

# Where tatami looks for its files at run time, below the root given with --root.
# These ARE compiled in (as TATAMI_SYSCONFDIR, TATAMI_DB_DIR and TATAMI_CACHEDIR) and
# 'make install' uses the same places. They must be absolute paths.
#   <SYSCONFDIR>/tatami/tatami.conf, repos.conf, repos.d/, hooks.d/
#   <DB_DIR>: package database, journal, metadata, indexes of remote repositories,
#             and the default local repository <DB_DIR>/packages
#   <CACHEDIR>/packages: downloaded packages
SYSCONFDIR ?= /etc
DB_DIR ?= /var/lib/tatami
CACHEDIR ?= /var/cache/tatami

# A fixed package extension for tatami and tatamk, without the leading dot
# (default: empty = tar.<compression>, every compression accepted)
PKG_EXT ?=
