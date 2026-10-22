#
#  tatami - a package manager in the spirit of pkgutils
#

# Build-time configuration. build.conf is a template of commented-out KEY=VALUE lines:
# uncomment and edit a line before building to override the default below, and the
# make command line beats both. (Nothing in it is active by default: an active empty
# assignment would stop the ?= defaults below from applying.) Example:
#   make SYSCONFDIR=/opt/etc DB_DIR=/opt/var/lib/tatami PREFIX=/opt
-include build.conf

# Where 'make install' puts things
DESTDIR ?=
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man

# Where tatami looks for its files at run time. These are compiled in as
# TATAMI_SYSCONFDIR, TATAMI_DB_DIR and TATAMI_CACHEDIR, but always as paths
# *below the installation root* (--root, default /): with SYSCONFDIR=/opt/etc the
# configuration is <root>/opt/etc/tatami/tatami.conf. 'make install' installs
# to the same places. (Setting ETCDIR or VARDIR directly changes only the install.)
SYSCONFDIR ?= /etc
DB_DIR ?= /var/lib/tatami
CACHEDIR ?= /var/cache/tatami
ETCDIR ?= $(SYSCONFDIR)
VARDIR ?= $(DB_DIR)

# a blank left at the end of a line of build.conf must not end up in a path
DESTDIR := $(strip $(DESTDIR))
PREFIX := $(strip $(PREFIX))
SYSCONFDIR := $(strip $(SYSCONFDIR))
DB_DIR := $(strip $(DB_DIR))
CACHEDIR := $(strip $(CACHEDIR))

# They must be absolute and plain: they are put into C string literals and a sed script
$(foreach v,SYSCONFDIR DB_DIR CACHEDIR, \
  $(if $(filter /%,$($(v))),,$(error $(v) must be an absolute path, not '$($(v))')) \
  $(if $(shell printf '%s' '$($(v))' | tr -d 'A-Za-z0-9._/+-'),$(error $(v) may only contain letters, digits and ._/+-),))

# the same, relative to the root
rel = $(patsubst /%,%,$(patsubst %/,%,$(1)))
RT_SYSCONFDIR = $(call rel,$(SYSCONFDIR))
RT_DB_DIR = $(call rel,$(DB_DIR))
RT_CACHEDIR = $(call rel,$(CACHEDIR))

VERSION = 0.1.0
NAME = tatami-$(VERSION)

# Packages are named <name>_<version>-<release>_<arch>.<extension>. The default
# extension is tar.pkg (set in build.conf; the compression inside is detected from the
# content). An empty PKG_EXT means tar.<compression> (tar.zst, tar.xz, ...), all of
# which tatami then accepts. Another extension for both tools:
#   make PKG_EXT=myext
# Both tools get it as -DDEFAULT_PKG_EXT.
# It is fixed: there is no run-time override (tatami.conf refuses PKG_EXT).
PKG_EXT ?= tar.pkg
PKG_EXT := $(strip $(PKG_EXT))

# The compression for packages: gz, zst, xz, bz2, lz4, lzma or none (there is no
# run-time setting for it; tatami-mkpkg -z overrides it for one build).
PKG_COMPRESSION ?= zst
PKG_COMPRESSION := $(strip $(PKG_COMPRESSION))
ifeq ($(filter $(PKG_COMPRESSION),gz zst xz bz2 lz4 lzma none),)
$(error PKG_COMPRESSION must be one of gz, zst, xz, bz2, lz4, lzma, none, not '$(PKG_COMPRESSION)')
endif
ifneq ($(shell printf '%s' '$(PKG_EXT)' | tr -d 'A-Za-z0-9._-'),)
$(error PKG_EXT may only contain letters, digits, '.', '_' and '-')
endif
ifneq ($(filter .%,$(PKG_EXT)),)
$(error PKG_EXT must not start with a dot)
endif

# All third-party libraries are vendored as git submodules under deps/ (pinned
# to release tags, except libsolv) and built as static archives, so the result
# does not depend on what a distribution packages: some ship no libsolv.a, and
# libarchive/zstd/zlib versions and feature sets differ. Fetch the sources with
#   git submodule update --init
# Needs: cmake and a C compiler. Each archive is only built when it is missing.
DEPS_DIR = $(CURDIR)/deps

LIBSOLV_DIR   = $(DEPS_DIR)/libsolv
LIBSOLV_BUILD = $(LIBSOLV_DIR)/cmake-build
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
ZLIB_BUILD = $(ZLIB_DIR)/cmake-build
ZLIB_A     = $(ZLIB_BUILD)/libz.a

# The build directories are all called cmake-build: some of the upstream source
# trees already contain a directory called "build" (libarchive's has files CMake
# reads, zstd's holds its CMake project), and 'make distclean' deletes ours.
ZSTD_DIR   = $(DEPS_DIR)/zstd
ZSTD_BUILD = $(ZSTD_DIR)/cmake-build
ZSTD_A     = $(ZSTD_BUILD)/lib/libzstd.a

XZ_DIR     = $(DEPS_DIR)/xz
XZ_BUILD   = $(XZ_DIR)/cmake-build
XZ_A       = $(XZ_BUILD)/liblzma.a

BZIP2_DIR  = $(DEPS_DIR)/bzip2
BZIP2_BUILD = $(BZIP2_DIR)/cmake-build
BZIP2_A    = $(BZIP2_BUILD)/libbz2.a
BZIP2_OBJS = $(addprefix $(BZIP2_BUILD)/,blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o)

LZ4_DIR    = $(DEPS_DIR)/lz4
LZ4_BUILD  = $(LZ4_DIR)/cmake-build
LZ4_A      = $(LZ4_BUILD)/liblz4.a

# libsodium (Ed25519 signatures). It uses autotools, built outside its source tree;
# the directory has the same name as the others so that clean-up is uniform.
SODIUM_DIR   = $(DEPS_DIR)/libsodium
SODIUM_BUILD = $(SODIUM_DIR)/cmake-build
SODIUM_A     = $(SODIUM_BUILD)/src/libsodium/.libs/libsodium.a

LIBARCHIVE_DIR   = $(DEPS_DIR)/libarchive
LIBARCHIVE_BUILD = $(LIBARCHIVE_DIR)/cmake-build
LIBARCHIVE_A     = $(LIBARCHIVE_BUILD)/libarchive/libarchive.a

DEP_ARCHIVES = $(LIBSOLV_A) $(LIBARCHIVE_A) $(XZ_A) $(BZIP2_A) $(LZ4_A) $(SODIUM_A) $(ZSTD_A) $(ZLIB_A)

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++11 -Wall -Wextra -pedantic -D_GNU_SOURCE -DVERSION=\"$(VERSION)\" \
	    -DDEFAULT_PKG_EXT=\"$(PKG_EXT)\" -DDEFAULT_PKG_COMPRESSION=\"$(PKG_COMPRESSION)\" \
	    -DTATAMI_SYSCONFDIR=\"$(RT_SYSCONFDIR)\" -DTATAMI_DB_DIR=\"$(RT_DB_DIR)\" \
	    -DTATAMI_CACHEDIR=\"$(RT_CACHEDIR)\" -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 \
	    -isystem $(LIBSOLV_INC) \
	    -isystem $(LIBARCHIVE_DIR)/libarchive \
	    -isystem $(ZSTD_DIR)/lib -isystem $(ZLIB_DIR) -isystem $(ZLIB_BUILD) \
	    -isystem $(XZ_DIR)/src/liblzma/api -isystem $(BZIP2_DIR) -isystem $(LZ4_DIR)/lib \
	    -isystem $(SODIUM_DIR)/src/libsodium/include -isystem $(SODIUM_DIR)/src/libsodium/include/sodium -isystem $(SODIUM_BUILD)/src/libsodium/include

# The vendored archives are linked by path (libarchive needs the compression
# libraries, so they come after it); nothing is taken from the system or from pkg-config.
LDLIBS += $(DEP_ARCHIVES)

# make STATIC=yes for a statically linked binary
ifeq ($(STATIC),yes)
LDFLAGS += -static
endif

SRCS = main.cc commands.cc engine.cc resolver.cc db.cc txn.cc rootfs.cc hooks.cc pkgarchive.cc meta.cc config.cc repos.cc sign.cc util.cc
OBJECTS = $(SRCS:%.cc=src/%.o)

all: tatami tatami-mkpkg

# Rebuild when VERSION, PKG_EXT or a compiled-in path changes
FLAGS = $(VERSION) $(PKG_EXT) $(PKG_COMPRESSION) $(RT_SYSCONFDIR) $(RT_DB_DIR) $(RT_CACHEDIR)
.flags: FORCE
	@echo '$(FLAGS)' | cmp -s - $@ || echo '$(FLAGS)' > $@
FORCE:

tatami: $(OBJECTS) $(DEP_ARCHIVES)
	$(CXX) $(LDFLAGS) $(OBJECTS) $(LDLIBS) -o $@

# --- vendored dependencies -------------------------------------------------
# Each follows the same scheme: configure with cmake (fails with a hint if the
# submodule is empty), then build the static archive. Archives that already
# exist are not rebuilt.

define check_submodule
	@test -f $(1)/$(or $(2),CMakeLists.txt) || { \
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

# xz -> liblzma.a (the library only: no command line tools, no translations, no threads)
$(XZ_BUILD)/Makefile:
	$(call check_submodule,$(XZ_DIR))
	mkdir -p $(XZ_BUILD)
	cd $(XZ_BUILD) && cmake $(XZ_DIR) -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		-DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
		-DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF -DXZ_NLS=OFF -DXZ_THREADS=no \
		-DBUILD_TESTING=OFF

$(XZ_A): $(XZ_BUILD)/Makefile
	$(MAKE) -C $(XZ_BUILD) liblzma

# bzip2 has no CMake project at this release: its seven library sources are
# compiled straight into libbz2.a, outside the source tree
$(BZIP2_BUILD)/%.o: $(BZIP2_DIR)/%.c
	$(call check_submodule,$(BZIP2_DIR),bzlib.c)
	@mkdir -p $(BZIP2_BUILD)
	$(CC) -O2 -D_FILE_OFFSET_BITS=64 -c $< -o $@

$(BZIP2_A): $(BZIP2_OBJS)
	$(AR) rcs $@ $(BZIP2_OBJS)

# libsodium -> libsodium.a (--enable-minimal: just the high-level API, which has Ed25519)
$(SODIUM_BUILD)/Makefile:
	$(call check_submodule,$(SODIUM_DIR),configure)
	mkdir -p $(SODIUM_BUILD)
	cd $(SODIUM_BUILD) && $(SODIUM_DIR)/configure --enable-static --disable-shared \
		--enable-minimal --disable-dependency-tracking --disable-debug --with-pic

$(SODIUM_A): $(SODIUM_BUILD)/Makefile
	$(MAKE) -C $(SODIUM_BUILD)

# lz4 -> liblz4.a (library only)
$(LZ4_BUILD)/Makefile:
	$(call check_submodule,$(LZ4_DIR)/build/cmake)
	mkdir -p $(LZ4_BUILD)
	cd $(LZ4_BUILD) && cmake $(LZ4_DIR)/build/cmake -DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=OFF -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF

$(LZ4_A): $(LZ4_BUILD)/Makefile
	$(MAKE) -C $(LZ4_BUILD) lz4_static

# libarchive -> libarchive.a with gzip (zlib), zstd, xz/lzma (liblzma), bzip2
# and lz4, all taken from the vendored libraries above, so that reading and
# writing every supported format is built in and needs no external program.
# What it could optionally use besides (openssl, acl, xattr, xml, pcre, ...) is
# switched off, as are its command line tools and tests.
$(LIBARCHIVE_BUILD)/Makefile: $(ZLIB_A) $(ZSTD_A) $(XZ_A) $(BZIP2_A) $(LZ4_A)
	$(call check_submodule,$(LIBARCHIVE_DIR))
	mkdir -p $(LIBARCHIVE_BUILD)
	cd $(LIBARCHIVE_BUILD) && cmake $(LIBARCHIVE_DIR) -DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=OFF -DENABLE_INSTALL=OFF -DENABLE_TEST=OFF \
		-DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
		-DENABLE_ZLIB=ON -DZLIB_INCLUDE_DIR=$(ZLIB_DIR) -DZLIB_LIBRARY=$(ZLIB_A) \
		-DENABLE_ZSTD=ON -DZSTD_INCLUDE_DIR=$(ZSTD_DIR)/lib -DZSTD_LIBRARY=$(ZSTD_A) \
		-DENABLE_LZMA=ON -DLIBLZMA_INCLUDE_DIR=$(XZ_DIR)/src/liblzma/api \
		-DLIBLZMA_LIBRARY_RELEASE=$(XZ_A) -DLIBLZMA_LIBRARY=$(XZ_A) \
		-DENABLE_BZip2=ON -DBZIP2_INCLUDE_DIR=$(BZIP2_DIR) \
		-DBZIP2_LIBRARY_RELEASE=$(BZIP2_A) -DBZIP2_LIBRARIES=$(BZIP2_A) \
		-DENABLE_LZ4=ON -DLZ4_INCLUDE_DIR=$(LZ4_DIR)/lib -DLZ4_LIBRARY=$(LZ4_A) \
		-DENABLE_LZO=OFF -DENABLE_LIBB2=OFF -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF \
		-DENABLE_NETTLE=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_PCREPOSIX=OFF \
		-DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF \
		-DCMAKE_C_FLAGS=-I$(ZLIB_BUILD)

$(LIBARCHIVE_A): $(LIBARCHIVE_BUILD)/Makefile
	$(MAKE) -C $(LIBARCHIVE_BUILD) archive_static

# tatami-mkpkg: one C++17 file plus the archive writer of tatami (pack.cc), linked
# statically with libarchive and the compression libraries only
MKPKG_OBJECTS = src/mkpkg.o src/pack.o src/meta.o src/util.o
MKPKG_ARCHIVES = $(LIBARCHIVE_A) $(ZSTD_A) $(XZ_A) $(BZIP2_A) $(LZ4_A) $(ZLIB_A)

tatami-mkpkg: $(MKPKG_OBJECTS) $(MKPKG_ARCHIVES)
	$(CXX) $(LDFLAGS) -o $@ $(MKPKG_OBJECTS) $(MKPKG_ARCHIVES) -static

src/mkpkg.o: src/mkpkg.cpp .flags
	$(CXX) $(filter-out -std=c++11,$(CXXFLAGS)) -std=c++17 -MMD -MP -c $< -o $@

# libsolv's headers must be staged before anything is compiled (order-only)
src/%.o: src/%.cc .flags | $(LIBSOLV_STAMP) $(SODIUM_BUILD)/Makefile
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

-include $(OBJECTS:.o=.d) $(MKPKG_OBJECTS:.o=.d)

.PHONY: install clean distclean check FORCE

check: all
	bash tests/run.sh

# The filesystem skeleton is created with plain 'mkdir -p': directories that
# already exist are left exactly as they are (mode, owner and contents), and
# an existing configuration or hook file is never overwritten. Binaries are replaced,
# as for any upgrade. The package database, index and metadata directories
# below $(VARDIR) are created by tatami itself on first use.
install: all
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(ETCDIR) $(DESTDIR)$(ETCDIR)/tatami/hooks.d $(DESTDIR)$(ETCDIR)/tatami/keys \
		$(DESTDIR)$(VARDIR)/packages
	install -m0755 tatami $(DESTDIR)$(BINDIR)/tatami
	install -m0755 tatami-mkpkg $(DESTDIR)$(BINDIR)/tatami-mkpkg
	mkdir -p $(DESTDIR)$(MANDIR)/man8 $(DESTDIR)$(MANDIR)/man5
	install -m0644 man/tatami.8 man/tatami-mkpkg.8 $(DESTDIR)$(MANDIR)/man8/
	install -m0644 man/tatami.conf.5 $(DESTDIR)$(MANDIR)/man5/
	@if [ -e $(DESTDIR)$(ETCDIR)/tatami/tatami.conf ]; then \
		echo "keeping existing $(DESTDIR)$(ETCDIR)/tatami/tatami.conf"; \
	else \
		install -m0644 tatami.conf $(DESTDIR)$(ETCDIR)/tatami/tatami.conf; \
	fi
	@for f in hold upgrade.rules; do \
		if [ -e $(DESTDIR)$(ETCDIR)/tatami/$$f ]; then \
			echo "keeping existing $(DESTDIR)$(ETCDIR)/tatami/$$f"; \
		else \
			install -m0644 $$f $(DESTDIR)$(ETCDIR)/tatami/$$f; \
		fi; \
	done
	@for h in hooks/*.hook; do \
		if [ -e $(DESTDIR)$(ETCDIR)/tatami/hooks.d/$$(basename $$h) ]; then \
			echo "keeping existing $(DESTDIR)$(ETCDIR)/tatami/hooks.d/$$(basename $$h)"; \
		else \
			install -m0644 $$h $(DESTDIR)$(ETCDIR)/tatami/hooks.d/; \
		fi; \
	done

# 'clean' removes what this project built (objects, dependency files, binaries) but
# keeps the slow-to-rebuild vendored libraries; 'distclean' resets them too.
# build.conf is yours and is never removed.
clean:
	rm -f src/*.o src/*.d tatami tatami-mkpkg .flags

distclean: clean
	rm -rf $(LIBSOLV_BUILD) $(ZLIB_BUILD) $(ZSTD_BUILD) $(XZ_BUILD) $(BZIP2_BUILD) $(LZ4_BUILD) $(LIBARCHIVE_BUILD) $(SODIUM_BUILD)
