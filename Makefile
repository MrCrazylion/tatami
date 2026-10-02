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

# Default package file extension, overridable at run time with PKG_EXT in
# tatami.conf. Example: make PKG_EXT=tar.pkg
PKG_EXT = pkg.tar.zst

PKG_CONFIG ?= pkg-config
PKGS = libarchive libsolv

CXXFLAGS ?= -O2
CXXFLAGS += -std=c++11 -Wall -Wextra -pedantic -D_GNU_SOURCE -DVERSION=\"$(VERSION)\" \
	    -DDEFAULT_PKG_EXT=\"$(PKG_EXT)\" -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 \
	    $(shell $(PKG_CONFIG) --cflags $(PKGS) | sed 's/-I/-isystem /g')
LDLIBS += $(shell $(PKG_CONFIG) --libs libarchive)

# libsolv is linked statically (set LIBSOLV_STATIC=no for the shared library)
# so that the dependency solver is part of the tatami binary itself.
ifeq ($(LIBSOLV_STATIC),no)
LDLIBS += $(shell $(PKG_CONFIG) --libs libsolv)
else
LDLIBS += $(shell $(PKG_CONFIG) --libs-only-L libsolv) -Wl,-Bstatic \
	  $(shell $(PKG_CONFIG) --libs-only-l --static libsolv) -Wl,-Bdynamic
endif

# make STATIC=yes for a statically linked binary
ifeq ($(STATIC),yes)
LDFLAGS += -static
LDLIBS := $(shell $(PKG_CONFIG) --libs --static $(PKGS))
endif

SRCS = main.cc bulkhead.cc commands.cc engine.cc resolver.cc db.cc pkgarchive.cc meta.cc config.cc util.cc
OBJECTS = $(SRCS:%.cc=src/%.o)

all: tatami tatamk

# Rebuild when VERSION or PKG_EXT change
.flags: FORCE
	@echo '$(VERSION) $(PKG_EXT)' | cmp -s - $@ || echo '$(VERSION) $(PKG_EXT)' > $@
FORCE:

tatami: $(OBJECTS)
	$(CXX) $(LDFLAGS) $(OBJECTS) -o $@ $(LDLIBS)

tatamk: tatamk.in .flags
	sed -e "s/#VERSION#/$(VERSION)/" -e "s/#PKG_EXT#/$(PKG_EXT)/" $< > $@
	chmod +x $@

src/%.o: src/%.cc .flags
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

distclean: clean
	rm -f tatami tatamk .flags
