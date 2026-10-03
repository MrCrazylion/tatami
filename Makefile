#
#  tatami - a package manager in the spirit of pkgutils
#

DESTDIR =
BINDIR = /usr/bin
MANDIR = /usr/share/man
ETCDIR = /etc
VARDIR = /var/lib/tatami

VERSION = 0.1.0
NAME = tatami-$(VERSION)

# The package file extension is a build-time default for both tools: tatami
# gets it as -DDEFAULT_PKG_EXT, tatamk as the @DEFAULT_PKG_EXT@ substitution.
# It can still be overridden when running: PKG_EXT in /etc/tatami.conf (both
# tools) and, for tatamk only, the PKG_EXT environment variable.
# Example for your own distribution:  make PKG_EXT=myext
PKG_EXT ?= tar.pkg
ifneq ($(shell printf '%s' '$(PKG_EXT)' | tr -d 'A-Za-z0-9._-'),)
$(error PKG_EXT may only contain letters, digits, '.', '_' and '-')
endif
ifneq ($(filter .%,$(PKG_EXT)),)
$(error PKG_EXT must not start with a dot)
endif
ifeq ($(strip $(PKG_EXT)),)
$(error PKG_EXT must not be empty)
endif

# All third-party libraries are vendored as git submodules under deps/ (pinned
# to release tags, except libsolv) and built as static archives, so the result
# does not depend on what a distribution packages: some ship no libsolv.a, and
# libarchive/zstd/zlib versions and feature sets differ. Fetch the sources with
#   git submodule update --init
# Needs: cmake and a C compiler. Each archive is only built when it is missing.
DEPS_DIR = $(CURDIR)/deps

LIBSOLV_DIR   = $(DEPS_DIR)/libsolv
LIBSOLV_BUILD = $(LIBSOLV_DIR)/build
LIBSOLV_A     = $(LIBSOLV_BUILD)/src/libsolv.a
# libsolv's headers sit flat in its src/ directory and are only given their
# <solv/...> names by 'make install'; they are staged under that name here.
LIBSOLV_INC   = $(LIBSOLV_BUILD)/include
LIBSOLV_STAMP = $(LIBSOLV_INC)/.staged
LIBSOLV_HDRS  = bitmap.h evr.h hash.h policy.h poolarch.h poolvendor.h pool.h \
		poolid.h pooltypes.h queue.h solvable.h solver.h solverdebug.h \
		repo.h repodata.h repo_solv.h repo_write.h util.h selection.h \
		strpool.h dirpool.h knownid.h transaction.h rules.h problems.h \
		chksum.h dataiterator.h

ZLIB_DIR   = $(DEPS_DIR)/zlib
ZLIB_BUILD = $(ZLIB_DIR)/build
ZLIB_A     = $(ZLIB_BUILD)/libz.a

# zstd keeps its own sources in deps/zstd/build, hence another directory name
ZSTD_DIR   = $(DEPS_DIR)/zstd
ZSTD_BUILD = $(ZSTD_DIR)/cmake-build
ZSTD_A     = $(ZSTD_BUILD)/lib/libzstd.a

LIBARCHIVE_DIR   = $(DEPS_DIR)/libarchive
LIBARCHIVE_BUILD = $(LIBARCHIVE_DIR)/build
LIBARCHIVE_A     = $(LIBARCHIVE_BUILD)/libarchive/libarchive.a

DEP_ARCHIVES = $(LIBSOLV_A) $(LIBARCHIVE_A) $(ZSTD_A) $(ZLIB_A)

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++11 -Wall -Wextra -pedantic -D_GNU_SOURCE -DVERSION=\"$(VERSION)\" \
	    -DDEFAULT_PKG_EXT=\"$(PKG_EXT)\" -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 \
	    -isystem $(LIBSOLV_INC) \
	    -isystem $(LIBARCHIVE_DIR)/libarchive \
	    -isystem $(ZSTD_DIR)/lib -isystem $(ZLIB_DIR) -isystem $(ZLIB_BUILD)

# The vendored archives are linked by path (libarchive needs zstd and zlib, so
# they come after it); nothing is taken from the system or from pkg-config.
LDLIBS += $(DEP_ARCHIVES)

# make STATIC=yes for a statically linked binary
ifeq ($(STATIC),yes)
LDFLAGS += -static
endif

SRCS = main.cc bulkhead.cc commands.cc engine.cc resolver.cc db.cc pkgarchive.cc meta.cc config.cc util.cc
OBJECTS = $(SRCS:%.cc=src/%.o)

all: tatami tatamk

# Rebuild when VERSION or PKG_EXT change
.flags: FORCE
	@echo '$(VERSION) $(PKG_EXT)' | cmp -s - $@ || echo '$(VERSION) $(PKG_EXT)' > $@
FORCE:

tatami: $(OBJECTS) $(DEP_ARCHIVES)
	$(CXX) $(LDFLAGS) $(OBJECTS) $(LDLIBS) -o $@

# --- vendored dependencies -------------------------------------------------
# Each follows the same scheme: configure with cmake (fails with a hint if the
# submodule is empty), then build the static archive. Archives that already
# exist are not rebuilt.

define check_submodule
	@test -f $(1)/CMakeLists.txt || { \
		echo "$(1) is empty: run 'git submodule update --init'" >&2; exit 1; }
endef

# Minimal static libsolv: no repository format parsers, no shared library.
$(LIBSOLV_BUILD)/Makefile: $(ZLIB_A)
	$(call check_submodule,$(LIBSOLV_DIR))
	mkdir -p $(LIBSOLV_BUILD)
	cd $(LIBSOLV_BUILD) && cmake $(LIBSOLV_DIR) \
		-DENABLE_STATIC=ON -DDISABLE_SHARED=ON -DCMAKE_BUILD_TYPE=Release \
		-DENABLE_RPMMD=OFF -DENABLE_SUSEREPO=OFF -DENABLE_COMPS=OFF \
		-DENABLE_HELIXREPO=OFF -DENABLE_DEBIAN=OFF -DENABLE_ARCHREPO=OFF \
		-DZLIB_INCLUDE_DIR=$(ZLIB_DIR) -DZLIB_LIBRARY=$(ZLIB_A) \
		-DCMAKE_C_FLAGS=-I$(ZLIB_BUILD)

# With DISABLE_SHARED=ON the static library is the CMake target "libsolv"
# (output: build/src/libsolv.a); "libsolv_static" only exists next to a shared one.
$(LIBSOLV_A): $(LIBSOLV_BUILD)/Makefile
	$(MAKE) -C $(LIBSOLV_BUILD) libsolv

$(LIBSOLV_STAMP): $(LIBSOLV_A)
	mkdir -p $(LIBSOLV_INC)/solv
	cd $(LIBSOLV_DIR)/src && cp $(LIBSOLV_HDRS) $(LIBSOLV_INC)/solv/
	cp $(LIBSOLV_BUILD)/src/solvversion.h $(LIBSOLV_INC)/solv/
	touch $@

# zlib -> libz.a (its generated zconf.h lands in the build directory)
$(ZLIB_BUILD)/Makefile:
	$(call check_submodule,$(ZLIB_DIR))
	mkdir -p $(ZLIB_BUILD)
	cd $(ZLIB_BUILD) && cmake $(ZLIB_DIR) -DCMAKE_BUILD_TYPE=Release \
		-DZLIB_BUILD_STATIC=ON -DZLIB_BUILD_SHARED=OFF \
		-DZLIB_BUILD_TESTING=OFF -DZLIB_INSTALL=OFF

$(ZLIB_A): $(ZLIB_BUILD)/Makefile
	$(MAKE) -C $(ZLIB_BUILD) zlibstatic

# zstd -> libzstd.a (library only: no programs, no tests, no threads, no legacy formats)
$(ZSTD_BUILD)/Makefile:
	$(call check_submodule,$(ZSTD_DIR)/build/cmake)
	mkdir -p $(ZSTD_BUILD)
	cd $(ZSTD_BUILD) && cmake $(ZSTD_DIR)/build/cmake -DCMAKE_BUILD_TYPE=Release \
		-DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=OFF \
		-DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF \
		-DZSTD_LEGACY_SUPPORT=OFF -DZSTD_MULTITHREAD_SUPPORT=OFF

$(ZSTD_A): $(ZSTD_BUILD)/Makefile
	$(MAKE) -C $(ZSTD_BUILD) libzstd_static

# libarchive -> libarchive.a, with gzip (zlib) and zstd taken from the two
# vendored libraries above. Everything else it can optionally use (xz, bzip2,
# lz4, openssl, acl, xattr, xml, pcre, ...) is switched off, as are its
# command line tools and tests, so it needs no other library; xz/bzip2/lzip
# archives are then read through the external programs, if installed.
$(LIBARCHIVE_BUILD)/Makefile: $(ZLIB_A) $(ZSTD_A)
	$(call check_submodule,$(LIBARCHIVE_DIR))
	mkdir -p $(LIBARCHIVE_BUILD)
	cd $(LIBARCHIVE_BUILD) && cmake $(LIBARCHIVE_DIR) -DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=OFF -DENABLE_INSTALL=OFF -DENABLE_TEST=OFF \
		-DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
		-DENABLE_ZLIB=ON -DZLIB_INCLUDE_DIR=$(ZLIB_DIR) -DZLIB_LIBRARY=$(ZLIB_A) \
		-DENABLE_ZSTD=ON -DZSTD_INCLUDE_DIR=$(ZSTD_DIR)/lib -DZSTD_LIBRARY=$(ZSTD_A) \
		-DENABLE_LZMA=OFF -DENABLE_BZip2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF \
		-DENABLE_LIBB2=OFF -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF \
		-DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_PCREPOSIX=OFF \
		-DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF \
		-DCMAKE_C_FLAGS=-I$(ZLIB_BUILD)

$(LIBARCHIVE_A): $(LIBARCHIVE_BUILD)/Makefile
	$(MAKE) -C $(LIBARCHIVE_BUILD) archive_static

tatamk: tatamk.in .flags
	sed -e "s/#VERSION#/$(VERSION)/" -e "s/@DEFAULT_PKG_EXT@/$(PKG_EXT)/" $< > $@
	chmod +x $@

# libsolv's headers must be staged before anything is compiled (order-only)
src/%.o: src/%.cc .flags | $(LIBSOLV_STAMP)
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

-include $(OBJECTS:.o=.d)

.PHONY: install clean distclean check FORCE

check: all
	bash tests/run.sh

# The filesystem skeleton is created with plain 'mkdir -p': directories that
# already exist are left exactly as they are (mode, owner and contents), and
# an existing configuration file is never overwritten. Binaries are replaced,
# as for any upgrade. The package database, index and metadata directories
# below $(VARDIR) are created by tatami itself on first use.
install: all
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(ETCDIR) $(DESTDIR)$(VARDIR)/packages
	install -m0755 tatami $(DESTDIR)$(BINDIR)/tatami
	install -m0755 tatamk $(DESTDIR)$(BINDIR)/tatamk
	@if [ -e $(DESTDIR)$(ETCDIR)/tatami.conf ]; then \
		echo "keeping existing $(DESTDIR)$(ETCDIR)/tatami.conf"; \
	else \
		install -m0644 tatami.conf $(DESTDIR)$(ETCDIR)/tatami.conf; \
	fi

clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d)

# 'clean' keeps the (slow to rebuild) vendored libraries; 'distclean' resets them too
distclean: clean
	rm -f tatami tatamk .flags
	rm -rf $(LIBSOLV_BUILD) $(ZLIB_BUILD) $(ZSTD_BUILD) $(LIBARCHIVE_BUILD)
