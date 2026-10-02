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

PKG_CONFIG ?= pkg-config
PKGS = libarchive

# libsolv is vendored as a git submodule (deps/libsolv) and linked statically,
# so the dependency solver is part of the tatami binary and does not depend on
# what the host distribution packages (some ship no libsolv.a at all).
# Needs: cmake, a C compiler and the zlib headers. Fetch the sources with
#   git submodule update --init
LIBSOLV_DIR   = $(CURDIR)/deps/libsolv
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

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++11 -Wall -Wextra -pedantic -D_GNU_SOURCE -DVERSION=\"$(VERSION)\" \
	    -DDEFAULT_PKG_EXT=\"$(PKG_EXT)\" -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 \
	    -isystem $(LIBSOLV_INC) \
	    $(shell $(PKG_CONFIG) --cflags $(PKGS) | sed 's/-I/-isystem /g')
# libsolv.a itself is added to the link command below; it needs zlib
LDLIBS += $(shell $(PKG_CONFIG) --libs libarchive) -lz

# make STATIC=yes for a statically linked binary
ifeq ($(STATIC),yes)
LDFLAGS += -static
LDLIBS := $(shell $(PKG_CONFIG) --libs --static $(PKGS)) -lz
endif

SRCS = main.cc bulkhead.cc commands.cc engine.cc resolver.cc db.cc pkgarchive.cc meta.cc config.cc util.cc
OBJECTS = $(SRCS:%.cc=src/%.o)

all: tatami tatamk

# Rebuild when VERSION or PKG_EXT change
.flags: FORCE
	@echo '$(VERSION) $(PKG_EXT)' | cmp -s - $@ || echo '$(VERSION) $(PKG_EXT)' > $@
FORCE:

tatami: $(OBJECTS) $(LIBSOLV_A)
	$(CXX) $(LDFLAGS) $(OBJECTS) $(LIBSOLV_A) -o $@ $(LDLIBS)

# Minimal static libsolv: no repository format parsers, no shared library.
$(LIBSOLV_BUILD)/Makefile:
	@test -f $(LIBSOLV_DIR)/CMakeLists.txt || { \
		echo "deps/libsolv is empty: run 'git submodule update --init'" >&2; exit 1; }
	mkdir -p $(LIBSOLV_BUILD)
	cd $(LIBSOLV_BUILD) && cmake $(LIBSOLV_DIR) \
		-DENABLE_STATIC=ON -DDISABLE_SHARED=ON -DCMAKE_BUILD_TYPE=Release \
		-DENABLE_RPMMD=OFF -DENABLE_SUSEREPO=OFF -DENABLE_COMPS=OFF \
		-DENABLE_HELIXREPO=OFF -DENABLE_DEBIAN=OFF -DENABLE_ARCHREPO=OFF

# With DISABLE_SHARED=ON the static library is the CMake target "libsolv"
# (output: build/src/libsolv.a); "libsolv_static" only exists next to a shared one.
$(LIBSOLV_A): $(LIBSOLV_BUILD)/Makefile
	$(MAKE) -C $(LIBSOLV_BUILD) libsolv

$(LIBSOLV_STAMP): $(LIBSOLV_A)
	mkdir -p $(LIBSOLV_INC)/solv
	cd $(LIBSOLV_DIR)/src && cp $(LIBSOLV_HDRS) $(LIBSOLV_INC)/solv/
	cp $(LIBSOLV_BUILD)/src/solvversion.h $(LIBSOLV_INC)/solv/
	touch $@

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

# 'clean' keeps the (slow to rebuild) vendored libsolv; 'distclean' resets it too
distclean: clean
	rm -f tatami tatamk .flags
	rm -rf $(LIBSOLV_BUILD)
