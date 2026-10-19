# tatami

A small, fast package manager for Linux, built on the design of CRUX's pkgutils.

- **Simple (KISS).** One binary, `tatami`, and one builder script, `tatamk`. The package
  database, configuration, journal and hooks are plain text files. Everything works with
  no configuration at all and stays offline unless you add a remote repository.
- **Atomic transactions.** Everything one command does is applied completely or not at
  all. Every change is journalled first, a failure rolls back every package of the run,
  and a run killed in the middle is recovered by the next one.
- **Real dependency resolution.** [libsolv](https://github.com/openSUSE/libsolv) resolves
  dependencies, conflicts, replacements and removals (including unneeded dependencies).
- **Verified downloads.** Packages and repository indexes are signed with Ed25519, and
  every package is bound to the index by its SHA-256 hash. Local files are trusted and
  are never checked.
- **Self-contained.** libsolv, libarchive, zlib, zstd, xz, bzip2, lz4 and libsodium are
  built from pinned Git submodules and linked statically. Installing needs no `tar`,
  `xz`, `gpg` or OpenSSL.

Everything tatami reads or writes lives below an installation root, `/` by default, which
you can change with `--root` to install into a chroot or an image.

## 1. Compilation and installation

### Requirements

To **build** tatami you need:

- a C compiler and a C++11 compiler (`gcc` or `clang`), `make`, `cmake` and a POSIX shell
- `git`, to fetch the bundled libraries

All libraries are **Git submodules** in `deps/`, pinned to release tags and built as
static archives, so nothing is taken from your distribution's packages.

To **run** it, the compiled `tatami` needs only libc and libstdc++ (`make STATIC=yes`
produces a fully static binary). `tatamk` additionally needs `bash`; building packages in
its sandbox needs [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`), and
the default download command needs `curl`.

### Get the sources

```sh
git clone --recurse-submodules https://github.com/MrCrazylion/tatami.git
cd tatami
# if you cloned without --recurse-submodules:
git submodule update --init
```

### Choose the paths, the extension and the compression (optional)

Before compiling you can edit [`build.conf`](build.conf). It is a template: every line is
commented out, and the Makefile has a default for each key.

```
# tatami build configuration template
# Uncomment and modify the fields below to override the Makefile defaults.
#
# PREFIX=/usr
# SYSCONFDIR=/etc
# DB_DIR=/var/lib/tatami
# CACHEDIR=/var/cache/tatami
# PKG_EXT=tar.pkg
# PKG_COMPRESSION=zst
```

To override a default, uncomment its line (remove the `# `) and change the value:

```
PREFIX=/opt/tatami
PKG_COMPRESSION=xz
```

| Key | Default | Meaning |
|---|---|---|
| `PREFIX` | `/usr` | `make install` puts `tatami` and `tatamk` in `$(PREFIX)/bin` and the manual pages in `$(PREFIX)/share/man` |
| `SYSCONFDIR` | `/etc` | configuration directory: `$(SYSCONFDIR)/tatami/` |
| `DB_DIR` | `/var/lib/tatami` | package database, journal, indexes of remote repositories, local repository |
| `CACHEDIR` | `/var/cache/tatami` | downloaded packages |
| `PKG_EXT` | `tar.pkg` | package file extension (no leading dot); empty means `tar.<compression>` |
| `PKG_COMPRESSION` | `zst` | compression `tatamk` uses: `gz`, `zst`, `xz`, `bz2`, `lz4`, `lzma` or `none` |

Leave a line commented out to keep the default; do not leave an active line with an empty
value (`PREFIX=`), because that makes the variable intentionally empty instead of using the
default. Put one `KEY=VALUE` per line, with no spaces around `=` and comments on lines of
their own. `SYSCONFDIR`, `DB_DIR`, `CACHEDIR`, `PKG_EXT` and `PKG_COMPRESSION` are compiled
into the programs (the three directories always as paths below the `--root`), so change them
**before** you build; the directories must be absolute paths. A value in `build.conf` beats
an environment variable of the same name, and the `make` command line beats both:
`make PREFIX=/opt/tatami`; `make DESTDIR=/tmp/pkg install` stages an installation. `make
clean` never touches `build.conf`. `PKG_EXT` and `PKG_COMPRESSION` exist **only** here: they
are fixed when tatami is built and cannot be changed at run time (`tatami.conf` refuses them),
which keeps every package in a repository named and compressed the same way.

### Build and install

```sh
make
sudo make install
```

The first build also compiles the bundled libraries, which takes a few minutes. `make
install` installs the programs, the manual pages (`tatami(8)`, `tatamk(8)`,
`tatami.conf(5)`), an example `ldconfig` hook, and a default `tatami.conf`. An existing
configuration file or hook is never overwritten.

Optionally run the test suite (it needs root and builds real packages in a scratch
directory):

```sh
sudo make check
```

`make clean` removes what was built but keeps the libraries; `make distclean` removes
those as well.

## 2. Configuration

The main configuration file is `/etc/tatami/tatami.conf` (`$(SYSCONFDIR)/tatami/`). It is
optional: if it is missing or empty, tatami uses its built-in defaults. Lines have the form
`NAME = value`; `#` starts a comment. The installed file documents every setting.

### Package format

Packages are named `<name>_<version>-<release>_<arch>.<extension>`, for example
`zlib_1.3.2-1_x86_64.tar.pkg`. The default extension is `tar.pkg`; the compression inside
is detected from the content, so it does not appear in the name.

The extension and the compression are decided when tatami is built (`PKG_EXT` and
`PKG_COMPRESSION` in `build.conf`, see above) and are not configurable afterwards: putting
either in `tatami.conf` is an error. An empty `PKG_EXT` means `tar.<compression>` (`tar.zst`,
`tar.xz`, ...), and every compression is then accepted. The only run-time choice is
`tatamk -z <compression>`, for one build.

All compression formats are read and written by tatami itself.

### Architecture

Packages for other architectures are refused. tatami always uses the machine's architecture
(`uname -m`); there is no setting for it. `noarch` packages are accepted everywhere.
`tatamk` takes the architecture from `arch=` in the recipe. It is required: a recipe without it is refused, with no fallback to the
build machine (use `arch=noarch` for architecture-independent packages).

### Other useful settings

```ini
# How remote files are downloaded (the default)
FETCHCMD = curl -f -L -# "%URL%" -o "%DEST%"
```

### One file per job

`tatami.conf` holds the engine settings only: `FETCHCMD`, `ALLOW_UNSIGNED`, `BULKHEAD`
and the `REPO_DIRS` fallback. Everything else has its own plain-text file in
`/etc/tatami`, and every one of them may be missing:

| File | Content |
| --- | --- |
| `repos.conf`, `repos.d/*.conf` | Repository definitions only: `core = https://...`, `local = /srv/packages` |
| `keys/` | Trusted public keys, one file each (`*.pub`) |
| `hold` | Held packages, one name per line (`#` comments allowed) |
| `upgrade.rules` | `UPGRADE`/`INSTALL` rules: `EVENT  PATTERN  YES\|NO` |
| `hooks.d/*.hook` | Post-transaction hooks |

```
# /etc/tatami/hold
linux
glibc
```

```
# /etc/tatami/upgrade.rules: a changed configuration file is saved as <file>.old
UPGRADE   ^etc/.*$   NO
```

Naming a held package in `tatami install` or `tatami remove` overrides the hold. See
`man tatami.conf` for everything.

## 3. Security and signing

Packages and indexes are signed with Ed25519. You sign what you publish; every client that
downloads from you verifies it.

**1. Generate a key pair** (once, on the machine that builds packages):

```sh
tatami keygen
```

```
Private key: /home/you/.tatami/privkey (keep it secret)
Public key:  /home/you/.tatami/privkey.pub
Copy the public key file into /etc/tatami/keys/ on every machine that installs your packages:
  cp /home/you/.tatami/privkey.pub /etc/tatami/keys/
```

The private key is stored with mode 0600 in `~/.tatami/privkey`. An existing key is never
overwritten without `-f`. Back it up: a lost key cannot be recovered, and packages signed
with a replaced key no longer verify.

**2. Trust the public key** on each machine that installs your packages: copy the `.pub` file
into `/etc/tatami/keys/`, which is simply a directory of public keys, one per file:

```sh
cp privkey.pub /etc/tatami/keys/myrepo.pub
```

To trust another signer add its file too; a signature made by **any** of the keys is accepted.
To stop trusting one, delete its file. Nothing else needs to be edited.

**3. That is all.** From now on:

- `tatamk` finds `~/.tatami/privkey` (or the file named by `$TATAMI_PRIVKEY`) and signs
  automatically. It refreshes the `repo.solv` index of the output directory and writes
  `<package>.sig` and `repo.solv.sig` next to it. `--no-sign` skips this.
- `tatami update` and `tatami install` fetch the `.sig` files of everything they download
  from a **remote** repository and verify them against the keys in `/etc/tatami/keys/`. A missing, malformed or
  wrong signature aborts the command, and the SHA-256 hash of each package in the index must
  match the download.
- **Local** files, repositories given as a path or as `file://`, and package files given on
  the command line are trusted: they are never checked and need no key.

With no key in `/etc/tatami/keys/`, remote repositories are refused. If you really want to
use unsigned ones, write `ALLOW_UNSIGNED = yes` in `tatami.conf`.

## 4. Repositories

Repositories are listed in `/etc/tatami/repos.conf`, and in any `/etc/tatami/repos.d/*.conf`,
one `name = url` per line. When a version is in several repositories, the first one listed wins.

```ini
# /etc/tatami/repos.conf

# A local directory of packages (the default location of the local repository)
core = /var/lib/tatami/packages

# A remote repository
main = https://mirror.example.com/tatami/x86_64
```

- A **local** repository is a directory of packages, read in place. `file:///path` works too.
  It needs no signature and does not use the network.
- A **remote** repository (`http://`, `https://` or `ftp://`) is downloaded with `FETCHCMD`
  and needs a trusted key in `/etc/tatami/keys/`. `tatami update` fetches its index; `tatami install` fetches the
  packages and deletes them from the cache once the transaction has committed.
  The remote directory must contain the packages, `repo.solv`, and their `.sig` files, which
  is exactly what `tatamk` produces in its output directory.

With no `repos.conf` at all, tatami uses the local directory `/var/lib/tatami/packages`, so
it is fully offline by default.

## 5. Usage crash course

### Build a package

A package is described by a `Tatamifile`, a small bash recipe. Create an empty directory with
this file:

```bash
# Description: A friendly greeter
name=hello
version=1.0
arch=noarch
release=1

build() {
        mkdir -p $PKG/usr/bin
        printf '#!/bin/sh\necho "Hello from tatami"\n' > $PKG/usr/bin/hello
        chmod 755 $PKG/usr/bin/hello
}
```

`arch` is required (use `noarch` for scripts, otherwise the target architecture such as `x86_64`).
`build()` runs in the unpacked sources (`$SRC`) and must install everything into `$PKG`. A real
recipe also lists `source=(...)` and `depends=(...)` and typically ends with
`make DESTDIR=$PKG install`.

Build it into your local repository (run it as a user who may write to that directory, or
build into another directory and list it in `repos.conf`):

```sh
tatamk -o /var/lib/tatami/packages
```

```
=======> Creating hello_1.0-1_x86_64.tar.pkg
=======> Built /var/lib/tatami/packages/hello_1.0-1_x86_64.tar.pkg
```

The build runs in a [bubblewrap](https://github.com/containers/bubblewrap) sandbox: the
system is read-only, there is no network, and only the package directory is writable. Add
`--no-bulkhead` to build without it. To run a script when the package is installed, put
`pre_install()` and `post_install()` functions in a file called `tatami.install` next to the
`Tatamifile`; `tatamk` bundles it automatically.

### Index a local repository

```sh
tatami index /var/lib/tatami/packages
```

This writes `repo.solv`, the binary index with the metadata and the SHA-256 hash of every
package. (If you have a signing key, `tatamk` has already done this for you.)

### Install

```sh
sudo tatami update              # refresh the indexes of the configured repositories
sudo tatami install hello       # install a package and its dependencies
hello
```

More commands:

```sh
tatami search <regex>           # search names and descriptions
tatami show hello               # details of a package
tatami list                     # installed packages (--upgradable, --available)
tatami files hello              # files of a package
tatami owns /usr/bin/hello      # which package owns a file
sudo tatami upgrade             # upgrade everything
sudo tatami remove hello        # remove it, with dependencies nobody needs any more
```

Add `-s` to any command to see what would be done without changing anything, `-y` to skip the
confirmation, and `-r <dir>` to work in another root. A package file can be installed
directly with `sudo tatami install ./hello_1.0-1_x86_64.tar.pkg`.

## More information

- `man tatami`, `man tatamk`, `man tatami.conf`: complete reference
- [`ARCHITECTURE.md`](ARCHITECTURE.md): how the transaction engine, the verification and the
  build system work, and what is not covered yet

## License

tatami is derived from the design (and parts of the code) of pkgutils, Copyright (c) 2000-2005
Per Liden and 2006-2021 the CRUX team, and is licensed under the GNU General Public License
version 2 or later. See [`COPYING`](COPYING).
