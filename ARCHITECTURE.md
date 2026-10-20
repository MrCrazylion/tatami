# tatami — architecture and design report

tatami is a small package manager for Linux in the spirit of CRUX's pkgutils: a
plain-text package database, packages that are tar archives, and a separate builder
(`tatami-mkpkg`). On top of that it has an apt-style command line and a real dependency
solver (libsolv). About 6,300 lines of C++11 and Bash, one multi-purpose binary,
`tatami`, plus the recipe builder `tatami-mkpkg`.

This document describes what exists today, why it is built that way, and where the
limits are. It does not describe plans.

---

## 1. Overview and philosophy

**Design rules (KISS):**

- **Few moving parts.** One binary, one builder script, plain text files (database,
  journal, configuration, hooks). No daemon, no database server, no scripting language
  inside the core.
- **Convention over configuration.** Everything works with no configuration file at
  all: defaults are compiled in, and the system is offline unless a remote repository
  is configured explicitly. Every default can be overridden.
- **Self-contained.** The eight libraries tatami uses (libsolv, libarchive, zlib, zstd,
  xz, bzip2, lz4, libsodium) are Git submodules under `deps/`, pinned to release tags
  and linked as static archives. Nothing is taken from the host's packages. At run time
  the binary needs only libc, libstdc++, libm and libgcc (`make STATIC=yes` gives a
  fully static one). No `tar`, `xz`, `gpg`, `curl` or OpenSSL is needed to install.
- **Everything below `--root`.** Every path tatami reads or writes (database, journal,
  configuration, repositories, caches, hooks, extraction) lives below the installation
  root, which defaults to `/`. Symbolic links inside the root, including absolute ones
  and a merged `/lib -> usr/lib`, are followed as if the root were `/`
  (`root_resolve()` in `rootfs.cc`), so nothing is ever written to the host by mistake.
- **No hard-coded policy.** Nothing like `ldconfig` is built in; it is a hook file.
  Repository lists, rules, key, fetch command and held packages are configuration.
- **Local is trusted, remote is verified.** Signature and checksum checks exist only on
  the code path that handles downloaded data. Local files never reach it.

**Module map:**

| Module | Responsibility |
|---|---|
| `main.cc` | Option parsing, config loading; `keygen`, `sign`, `pack`, `bulkhead` are dispatched before the config is read |
| `commands.cc` | All user commands, repository loading, remote update/fetch, signature policy, the transaction driver |
| `resolver.cc` | libsolv: architecture policy, repositories, jobs, locks, plans, explanations |
| `engine.cc` | The transaction: begin / install / remove / commit / rollback, hooks, install scripts |
| `txn.cc` | The undo journal and crash recovery |
| `db.cc` | The plain-text package database and its lock |
| `pkgarchive.cc`, `pack.cc` | Reading, extracting and writing packages with libarchive |
| `rootfs.cc` | Path confinement to the root |
| `repos.cc` | `repos.conf` / `repos.d`, running `FETCHCMD`, the progress bar |
| `sign.cc` | Ed25519 and SHA-256 through libsodium; `keygen` and `sign` |
| `hooks.cc` | Post-transaction hooks |
| `bulkhead.cc` | The bubblewrap command line used by `tatami-mkpkg` |
| `config.cc`, `meta.cc`, `util.cc` | Configuration, package metadata, helpers |

**Dependency resolution** is delegated to libsolv: installed packages form the
"installed" repository, each configured repository a repo, and a request becomes
solver jobs. The architecture policy is strict (the target's architecture plus
`noarch`). The target architecture is always the machine's, from `uname()`; there is no
setting and no implicit multilib. Removal uses `SOLVER_ERASE` with
`SOLVER_CLEANDEPS`, and explicitly installed packages are declared
`SOLVER_USERINSTALLED`, so unneeded dependencies are removed with the package that
pulled them in. There is no separate "autoremove" command.

---

## 2. Transaction engine

Everything one command does — all installs, upgrades and removals of its plan — is
**one transaction, applied completely or not at all.** This is the central design
feature of the project.

### Phases

```
plan ─▶ download + verify ─▶ space check ─▶ begin ─▶ (pre_install, extract)* ─▶ commit ─▶ post_install ─▶ hooks
                                                 │                                  │
                                                 └──────── any error ───────────────┴─▶ rollback
```

1. **Plan.** libsolv produces the steps. Local package files are checked; remote ones
   are downloaded to `var/cache/tatami/packages` and verified (§3).
2. **Disk space check.** The unpacked size of all incoming packages (plus about half a
   block per file and a margin of 5 % and 8 MiB) is compared with `statvfs` of the
   root's filesystem. Upgrades count in full, because old files are freed only at the
   commit. If it does not fit, the run is refused before anything is touched.
3. **Begin.** The journal `var/lib/tatami/transaction.journal` is created and synced.
4. **Per package:** `pre_install` (if any), then extraction. Extraction records every
   change *before* making it. The package database is changed **in memory only**, and
   removals and dropped files are only *queued* for deletion.
5. **Commit.** The deletions that no package of the final state owns are journalled, a
   `K` record is written and synced, the database is written with one atomic rename
   (the **commit point**), and only then are the deferred deletions carried out and the
   backups removed. Downloaded packages are deleted from the cache.
6. **After the commit:** `post_install` of each installed package, then the hooks.

### The journal

An append-only text file; each action is written before it is carried out.

| Record | Meaning | Rollback | Commit |
|---|---|---|---|
| `T` | start of a run | | |
| `I name version` | package installed or upgraded | | |
| `R name` | package removed | | |
| `C path` | created (file, link, directory, implicit parents) | removed, deepest first | |
| `B path bak` | existing file renamed aside in its own directory | renamed back | backup deleted |
| `O path path.old` | configuration file saved as `.old` (§4) | `.old` renamed back | `.old` kept |
| `M path mode uid gid` | existing directory's mode and owner | restored | |
| `D path` | deferred deletion | | carried out |
| `K` | all work done; the database commit follows | | |

### Rollback

If any step fails — a file that cannot be written, a full disk, a corrupt archive, a
conflict, a failing `pre_install` — the driver rolls back **every package of the
run**: the journal is undone newest-first, the in-memory database changes are dropped
(the file was never written), and the command fails with "the transaction failed,
nothing was changed". Packages that were downloaded stay in the cache so a retry does
not download them again.

### Crash recovery

If tatami is killed (SIGKILL) or the machine loses power mid-run, the journal is still
there. The next command that modifies the system reads it first (`txn::recover`):

- **No `K` record:** the database cannot have been written → **roll back** the whole
  run.
- **`K` present:** the database decides. If it shows the result of every `I` and `R`
  record, the commit happened → **finish** (deferred deletions, drop backups). Otherwise
  → **roll back**.

The older one-package journal format is still understood. A test hook,
`TATAMI_CRASH_AT=extracted|committed`, makes tatami kill itself at the two interesting
points; the test suite uses real SIGKILLs at both.

### Locking and conflicts

The database directory is `flock`ed (exclusive for commands that modify, shared for
queries). File conflicts between packages, and with files on disk, are refused unless
`--force`. Files of a package being removed in the same run do not count as conflicts,
and a file a new package takes over from a removed one is kept.

---

## 3. Security and verification

Two independent layers protect remote data. Both are verified **before** a downloaded
file is stored in the cache under its final name or installed.

### SHA-256 package hashes (integrity binding)

- `tatami update` (on a local repository, and so `tatami-mkpkg` for its output directory) computes the SHA-256 of every package file and
  stores it in `repo.solv` as libsolv's standard `SOLVABLE_CHECKSUM`; `tatami show`
  prints it.
- A package downloaded from a remote repository is hashed with libsodium immediately
  after the download and compared with the index. On a mismatch the `.part` file is
  deleted and the run is refused. A cached copy must match as well. An index without a
  checksum for a remote package is refused.
- This is checked first, then the signature, so a file substituted on the server is
  caught even when no key is configured.

### Ed25519 signatures

- **Scheme.** Ed25519ph (RFC 8032) through libsodium: the signature is over the
  streamed SHA-512 of the file, so packages of any size are signed without loading them
  into memory. The implementation is checked against the RFC 8032 §7.3 test vector.
  Note that this is the pre-hash variant: a plain `ed25519 verify` tool will not accept
  it.
- **Key management.** `tatami keygen` writes `~/.tatami/privkey` (mode 0600, directory
  0700) and `.pub`, and prints the command that copies the `.pub` file to `/etc/tatami/keys/`; it never overwrites a key
  without `-f`. `tatami sign <file> [key]` writes `<file>.sig`. Keys are hex; the
  public key may also be given as base64.
- **Producer.** `tatami-mkpkg` signs as part of the build when `$TATAMI_PRIVKEY` or
  `~/.tatami/privkey` exists: it refreshes the output directory's `repo.solv`, signs the
  package and the index. `--no-sign` skips it.
- **Trust store.** The trusted keys are the files of `<root>/etc/tatami/keys/` (the
  Alpine/Arch model): add a `.pub` file to trust a signer, delete it to stop. They are
  loaded at start-up in name order; a file that is not a key is skipped with a warning,
  dot files and subdirectories are ignored. A signature is good if it verifies against
  **any** key (the SHA-512 pre-hash state is finished once per key).
- **First-use key fetch.** If `keys/<repo>.pub` is missing, `tatami update` fetches
  `<repo url>/tatami.pub` through `FETCHCMD`, **https only**, into
  `var/cache/tatami/<repo>_quarantine.pub`, then fetches `repo.solv` and its `.sig` into
  `.part` files and verifies them against the quarantined key alone. Only if the proof holds
  is the key copied into the store under a hidden name (same filesystem, so the rename is
  atomic) and renamed to `<repo>.pub`, after which the index is committed. On any failure the
  quarantine key and the `.part` files are deleted. This is trust on first use (it proves the
  key and the index belong together, not who published them). A failed key download skips
  the repository with a warning; a failed proof aborts the update.
- **Consumer.** With at least one trusted key, `tatami update` fetches `repo.solv` and
  `repo.solv.sig`; `tatami install` fetches each package and its `.sig`. Everything is
  verified into `.part` files first. A bad, wrong-key or missing signature aborts, and
  the previous index is kept. Cached indexes are re-verified each time they are loaded
  (one that fails is ignored with a warning, never used), and cached packages are
  reused only if their signature still verifies.
- **No key, no trust.** With no key in the directory a remote repository is refused.
  `ALLOW_UNSIGNED = yes` in `tatami.conf` explicitly accepts unsigned data (the checksums
  are still checked). The old `PUBKEY` setting is refused with a message naming the directory.

### The local bypass

Local sources are trusted. A package file given on the command line
(`tatami install ./pkg.tar.pkg`), a repository given as a path, and a `file://`
repository are **never** checked for a signature or a checksum, never start `FETCHCMD`,
and need no key. This is not a flag: the verification code simply exists only on the
remote fetch path.

### Other protections

- **Extraction hardening.** Member names are normalized; control characters, `..`,
  absolute paths and anything inside tatami's own state directory are refused. Hard-link
  targets and symlinks are resolved inside the root.
- **Downloading.** `FETCHCMD` (default `curl -f -L -# "%URL%" -o "%DEST%"`) is run with
  `fork`/`exec`, **never through a shell**, so nothing in a URL is interpreted. The
  child's stderr goes through a `pipe()` and tatami draws its own progress bar from the
  percentages; the raw output is never shown. tatami itself contains no network code.
  On a terminal the bar is plain text and drawn in place with `\r`
  (`name   [####......]  33%`, fixed width), and before the `[Y/n]` question a FreeBSD-style
  summary lists the packages by group with counts and the space/download sizes (the unpacked
  size of every package is stored in `repo.solv` as `SOLVABLE_INSTALLSIZE` when indexing;
  a removed package's size is that of its files on disk). Neither is used when stdout is
  not a terminal, so logs and scripts see the stable plain format.
- **Privileges.** Commands that modify the system require root (unless `--simulate`).

### Known limits

No key rotation or revocation, no signed timestamp (an old, validly signed index can be
replayed), key distribution is manual. Install scripts and hooks run host programs as
root, unconfined; package contents are trusted code.

---

## 4. Configuration management

### `.old` backups of configuration files (Slackware style)

A file that an `UPGRADE ... NO` rule in `/etc/tatami/upgrade.rules` matches is a
*configuration file* (the shipped file has one rule, `UPGRADE ^etc/.*$ NO`). When an upgrade brings a version
that differs from the regular file on disk:

1. the new version is extracted to a temporary name next to it;
2. if it is identical in content and permissions, it is dropped — nothing changes;
3. otherwise an existing `<file>.old` is moved aside as an ordinary rollback backup, the
   existing file is renamed to `<file>.old` (journal record `O`), and the new file is
   renamed into place. A message names the saved file.

The rename is part of the transaction: a rollback, or the recovery of a killed run,
deletes the new file and renames the `.old` back (restoring an earlier `.old` too);
after a commit the `.old` stays. There is no `rejected/` directory and no merge tool.
`.old` files belong to no package, so removing a package leaves them. An
`INSTALL ... NO` rule skips a file entirely.

### The hold file — version pinning

`/etc/tatami/hold`, one package name per line (`#` comments and blank lines ignored), pins
installed packages. Each
one gets a `SOLVER_SOLVABLE | SOLVER_LOCK` job, pushed with the other jobs before
`solver_solve()`, so libsolv itself keeps the version whatever else is upgraded or
removed. `tatami upgrade` prints `Skipping upgrade for held package: name (1.0 -> 2.0)`
for each held package that has a newer version. A package named in the `install` or
`remove` command itself is not locked for that command — an explicit request wins (as
with pacman's `IgnorePkg`). Held packages that are not installed are ignored.

### Where things are configured

- `/etc/tatami/tatami.conf` — engine settings only (`FETCHCMD`, `ALLOW_UNSIGNED`, `BULKHEAD`). Missing, empty or
  unreadable is fine: the built-in defaults apply. The old `ARCH`, `HoldPkg`, `PUBKEY`, `PKG_EXT`, `PKG_COMPRESSION`, `REPO_DIRS` and rule lines
  are refused with a message that names their new home.
- `/etc/tatami/repos.conf`, `repos.d/*.conf` — repository definitions and nothing else
  (no `FETCHCMD`, no `ALLOW_UNSIGNED`: those are engine settings).
- `/etc/tatami/keys/` — trusted public keys, one file each.
- `/etc/tatami/hold` — held packages, one per line.
- `/etc/tatami/upgrade.rules` — the `UPGRADE`/`INSTALL` `YES|NO` rules.
  A missing `hold` or `upgrade.rules` is simply ignored (nothing held, no rule). All of
  these are looked up inside the `--root`.
- **Build time.** `build.conf`, provided with the sources, is a template of commented-out
  `KEY=VALUE` lines (`PREFIX`, `SYSCONFDIR`, `DB_DIR`, `CACHEDIR`, `PKG_EXT`,
  `PKG_COMPRESSION`) that the Makefile includes. Nothing in it is active, because an
  active empty assignment would stop the Makefile's `?=` defaults from applying; to
  override a default, uncomment and edit its line. The `make` command line beats both.
  `SYSCONFDIR`, `DB_DIR` and `CACHEDIR` are validated and compiled in as paths *below the
  root*, so a custom layout still works with `--root`; `PKG_EXT` is compiled into tatami and
  substituted into `tatami-mkpkg`, as is `PKG_COMPRESSION`; **both are compile-time only** (`tatami.conf` refuses them, `tatami-mkpkg` ignores the environment, only `tatami-mkpkg -z` overrides the compression); `PREFIX`, `BINDIR`, `MANDIR` and
  `DESTDIR` control `make install`. The layout defaults to the FHS: `/etc/tatami`,
  `/var/lib/tatami`, `/var/cache/tatami`.

---

## 5. Package building — `tatami-mkpkg`

### The `Tatamifile`

A bash fragment, in the pkgutils `Pkgfile` style with real dependency fields:

```bash
# Description: Compression library
name=zlib
version=1.3.2
release=1
source=(https://example.org/zlib-$version.tar.gz)
depends=(libfoo "libbar >= 2.0" "a | b")      # also conflicts, provides, replaces
arch=noarch                                   # required; no fallback

build() {
        cd zlib-$version
        ./configure --prefix=/usr && make && make DESTDIR=$PKG install
}
```

The result is `<name>_<version>-<release>_<arch>.<extension>`, by default `tar.pkg` (fixed at build time; the compression inside is detected from the content; an empty `PKG_EXT` gives `tar.<compression>` instead), for example
`zlib_1.3.2-1_x86_64.tar.pkg`. Names and versions may not contain `_`, so the first two
underscores are the separators. Sources are downloaded next to the recipe, checked
against `.md5sum` if present, and unpacked. **Packing is done by `tatami pack`
(libarchive)**, not by host `tar`: gzip, zstd (the default), xz, lzma, bzip2, lz4 or
none, with `.META` first, sorted entries and numeric owners.

### The bubblewrap sandbox (`bulkhead`)

By default `build()` runs inside `bwrap` through `tatami bulkhead`: the whole system is
mounted read-only, `/tmp`, `/home` and `/root` are tmpfs, the network and PID namespaces
are unshared, the sandbox dies with its parent, and only the package root
(`/tmp/destdir`, which is `$PKG` and `DESTDIR`) and the build directory are writable.
If `bwrap` is missing the build **fails** rather than running unprotected;
`--no-bulkhead` or `BULKHEAD=no` turns the sandbox off explicitly.

### Zero-config install scripts

A file named `tatami.install` next to the `Tatamifile` is picked up automatically (no
variable in the recipe) and bundled into the package as the hidden member `.INSTALL`.
It may define two bash functions, and nothing else is supported:

- `pre_install` — runs for each package right **before** its files are extracted. A
  non-zero exit **aborts the transaction and rolls it back**, earlier packages
  included.
- `post_install` — runs **after the commit**. A failure is only a warning.

Both receive the package version as `$1` and run with `TATAMI_ROOT` set to the
installation root, so they work with `--root`. There are no removal scripts and no
upgrade-specific phases. `.INSTALL` is read into memory when the package is scanned and
is **never installed or listed** as a package file. At run time the script is written
to a private `mkstemp` file in `/tmp/tatami-install-XXXXXX`, bash is started with
`fork`/`exec` to source it and call the one function (the path and version are
arguments, no command line is built from package data), and the file is removed.

### Signing

See §3: with a key present, `tatami-mkpkg` refreshes and signs the output directory's index and
the package as part of the build.

---

## 6. Hooks and repositories

### Post-transaction hooks

Files `etc/tatami/hooks.d/*.hook`; nothing about what to run is built into tatami.

```
Trigger   = ^(usr/)?lib(32|64|x32)?/        # regex on changed paths; repeatable
Trigger   = ^etc/ld\.so\.conf
Operation = install upgrade remove          # optional, default: all
Needs     = etc/ld.so.conf                  # optional: skip unless it exists in the root
Exec      = /sbin/ldconfig -r %ROOT%        # quotes group words; no shell
```

A hook runs **at most once per transaction**, after the commit, and only if one of the
paths the transaction added, changed or removed matches. `%ROOT%` is replaced by the
root and `TATAMI_ROOT` is set. A malformed hook is detected **before** anything is
changed; a failing hook is reported but does not undo the transaction. `make install`
ships the `ldconfig` hook as an example.

### Repositories

- **`etc/tatami/repos.conf`** and **`etc/tatami/repos.d/*.conf`** hold `name = url`
  lines (read in alphabetical order). A URL is a path, `file://…`, or a remote
  `http://`, `https://` or `ftp://` address. The first repository listed wins when a
  version is in several. With no `repos.conf`, or an empty one, the local default below is used; there is no other
  way to configure repositories (`REPO_DIRS` is refused).
- **Default and offline-first.** With nothing configured the only repository is the
  local directory `var/lib/tatami/packages`. Nothing is downloaded unless a remote
  repository is configured explicitly.
- **Local repositories** are read in place. `tatami update` writes the binary
  `repo.solv` (there is no separate `index` command; `tatami-mkpkg` indexes its output directory by running `update` against a throw-away root that lists it as the only repository); if packages are newer than the index, tatami warns and scans the
  directory instead, so results are never wrong, only slower.
- **Remote repositories.** `tatami update` downloads `repo.solv` (and its signature) to
  `var/lib/tatami/repos/<name>/`; `tatami install` downloads packages to
  `var/cache/tatami/packages`, verifies them (§3), and deletes them from the cache once
  the transaction commits.

---

## 7. Testing and reliability

`tests/run.sh` is a single end-to-end script: **689 checks**, all passing, plus
`tests/test_permissions.sh` (5 checks). The suite builds real packages with `tatami-mkpkg`,
drives `tatami` against scratch roots, and compares complete filesystem snapshots
before and after failures. It covers:

- naming, all compression formats (read and written with an empty `PATH`), and
  architecture policy (a `uname()` shim fakes the host);
- install reasons and cascading removal;
- **atomicity:** a failing third package undoes the first two (including an upgrade and
  a replace-removal in the same run); rollback leaves the filesystem byte-for-byte as it
  was;
- **crash recovery:** handmade journals, and real SIGKILLs before and after the database
  commit;
- `--root` isolation: host files are checksummed and a timestamp stamp is used to prove
  nothing outside the root changes, with a usr-merged root and absolute symlinks;
- repositories and `repo.solv`; remote fetching through a fake `FETCHCMD`; the progress
  bar (run inside a pseudo-terminal) and the default fetch command line;
- **signatures and hashes:** the RFC 8032 vector, key generation, wrong-key, tampered
  package, tampered index, missing `.sig`, a substituted package, cached-index
  re-verification, base64 keys, and the local bypass;
- disk space (an `LD_PRELOAD` shim fakes `statvfs`) and cache cleanup;
- `.old` backups with and without an earlier `.old`, with rollback and recovery;
- the hold file, install scripts, hooks (including failing and malformed ones),
  configuration fallbacks, and shell-injection attempts in URLs.

Mutation checks were used on the security- and safety-critical paths (signature
verification, hash comparison, the lock job, the `pre_install` abort, the journal
commit record): disabling each makes specific tests fail.

**Not yet exercised:** a real HTTP mirror with a real `curl`; a real `bwrap` (this
build host cannot create user namespaces, so the sandbox is tested with a mock); an
actual power-loss test around the database rename; hosts other than `aarch64`.

---

## Summary of limits and open items

- Per-run atomicity covers tatami's own files and database. What an install script or a
  hook does elsewhere cannot be undone.
- Read-only commands (`list`, `show`, …) do not run crash recovery; the next command
  that modifies the system does.
- No key rotation, revocation or signed timestamps; no installed-file verification
  command; no `rejmerge`-style tool for `.old` files; no version-pinning syntax other
  than the hold file; no multilib.
- Not yet validated against real mirrors, a real sandbox, or power loss (see §7).
