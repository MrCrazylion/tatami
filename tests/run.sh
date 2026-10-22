#!/bin/bash
# End-to-end tests: drives tatami against a scratch root and tests the standalone C++ tatami-mkpkg.
# bwrap cannot run on every machine (it needs user namespaces), so tatami-mkpkg is tested against a
# mock bwrap that records its arguments and runs the build in the host workspace. The fixture
# packages of the tatami tests do not depend on tatami-mkpkg: they are packed by a small Python helper.
# Needs root (like tatami itself) and is run with: make check
cd "$(dirname "$0")/.." || exit 1
export TATAMI="$PWD/tatami"   # tatami-mkpkg signs and indexes through the tatami binary
MKPKG="$PWD/tatami-mkpkg"
REPO_ROOT_DIR="$PWD"
T="$PWD/tests/work"
ROOT="$T/root"
REPO="$T/repo"
CONF="$T/tatami.conf"
EXT="tar.pkg"          # the build-time default extension; other ones need their own build (see below)
HARCH=$(uname -m)      # packages built here carry the host architecture in their name

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; [ -n "$2" ] && echo "$2" | sed 's/^/       /'; }

t() { [ -e "$ROOT/etc/tatami/repos.conf" ] || set_repos "$ROOT" "$REPO"; "$TATAMI" -r "$ROOT" -c "$CONF" "$@"; }
ty() { t -y "$@"; }
# check <description> <expected-exit: 0|1> <command...>; output kept in $OUT
check() {
	local desc="$1" want="$2"; shift 2
	OUT=$("$@" 2>&1); local rc=$?
	if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = 1 ] && [ $rc -ne 0 ]; }; then ok "$desc"; else bad "$desc (exit $rc)" "$OUT"; fi
}
has() { # has <description> <regex>: $OUT contains
	if echo "$OUT" | grep -Eq -- "$2"; then ok "$1"; else bad "$1 (missing: $2)" "$OUT"; fi
}
hasnt() {
	if echo "$OUT" | grep -Eq -- "$2"; then bad "$1 (unexpected: $2)" "$OUT"; else ok "$1"; fi
}
exists() { if [ -e "$ROOT/$2" ] || [ -L "$ROOT/$2" ]; then ok "$1"; else bad "$1 ($2 missing)"; fi; }
absent() { if [ -e "$ROOT/$2" ] || [ -L "$ROOT/$2" ]; then bad "$1 ($2 present)"; else ok "$1"; fi; }

# "a >= 1, b" -> "a >= 1" "b"
quote_list() {
	local IFS=, out="" item
	for item in $1; do
		item=$(echo "$item" | sed 's/^ *//; s/ *$//')
		out="$out \"$item\""
	done
	echo "$out"
}

# fixture_build <Tatamifile> <output-dir>: a package from an old-style recipe (with conflicts, provides, replaces),
# built on the host and packed with Python's tarfile. This is where the tatami tests get their packages from:
# tatami-mkpkg itself deliberately ignores conflicts, provides and replaces.
fixture_build() {
	local file="$1" out="$2" w rc
	w=$(mktemp -d "$T/fix.XXXXXX") || return 1
	(
		unset name version release depends conflicts provides replaces arch; unset -f build
		. "$file" || exit 1
		mkdir -p "$w/pkg" "$out"; export SRC="$w" PKG="$w/pkg" name version release
		( set -e; cd "$SRC"; build ) || exit 1
		pv="$version${release:+-$release}"; pa="$arch"
		case "$(printf '%s' "$pa" | tr 'A-Z' 'a-z')" in noarch|all|any) pa=noarch ;; esac
		j() { local IFS=,; local o="" i; for i in "$@"; do o="${o:+$o, }$i"; done; echo "$o"; }
		{
			echo "name: $name"; echo "version: $pv"; echo "arch: $pa"
			d=$(sed -n 's/^# *Description: *//p' "$file" | head -n 1); [ -n "$d" ] && echo "description: $d"
			[ ${#depends[@]} -gt 0 ] && echo "depends: $(j "${depends[@]}")"
			[ ${#conflicts[@]} -gt 0 ] && echo "conflicts: $(j "${conflicts[@]}")"
			[ ${#provides[@]} -gt 0 ] && echo "provides: $(j "${provides[@]}")"
			[ ${#replaces[@]} -gt 0 ] && echo "replaces: $(j "${replaces[@]}")"
		} > "$w/.META"
		[ -f "$(dirname "$file")/tatami.install" ] && cp "$(dirname "$file")/tatami.install" "$w/pkg/.INSTALL"
		python3 - "$w/.META" "$w/pkg" "$out/${name}_${pv}_${pa}.$EXT" <<'PYPACK'
import os, sys, tarfile
meta, root, out = sys.argv[1:4]
def plain(ti):
    ti.uid = ti.gid = 0; ti.uname = ti.gname = ""
    return ti
with tarfile.open(out, "w:gz") as t:
    t.add(meta, arcname=".META", filter=plain)
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs + files):
            full = os.path.join(d, n)
            t.add(full, arcname=os.path.relpath(full, root), recursive=False, filter=plain)
PYPACK
	); rc=$?
	rm -rf "$w"; return $rc
}

# mkpkg <name> <version> [key=value...]   keys: depends conflicts provides replaces files
mkpkg() {
	local name="$1" version="$2"; shift 2
	local dir="$T/recipes/$name-$version" depends="" conflicts="" provides="" replaces="" arch="" body=""
	for kv in "$@"; do
		case "$kv" in
		depends=*) depends="${kv#depends=}" ;;
		conflicts=*) conflicts="${kv#conflicts=}" ;;
		provides=*) provides="${kv#provides=}" ;;
		replaces=*) replaces="${kv#replaces=}" ;;
		arch=*) arch="${kv#arch=}" ;;
		file=*) body="$body"$'\n\t'"mkdir -p \$PKG/$(dirname "${kv#file=}"); echo '$name $version' > \$PKG/${kv#file=}" ;;
		esac
	done
	mkdir -p "$dir"
	depends=$(quote_list "$depends"); conflicts=$(quote_list "$conflicts")
	provides=$(quote_list "$provides"); replaces=$(quote_list "$replaces")
	cat > "$dir/Tatamifile" <<RECIPE
# Description: test package $name
name=$name
version=$version
release=1
source=()
depends=($depends)
conflicts=($conflicts)
provides=($provides)
replaces=($replaces)
arch=${arch:-$HARCH}
build() {
	mkdir -p \$PKG/usr/share/$name
	echo "$name $version" > \$PKG/usr/share/$name/version$body
}
RECIPE
	fixture_build "$dir/Tatamifile" "$REPO" > "$T/tatami-mkpkg.log" 2>&1 || { bad "fixture package $name $version" "$(cat "$T/tatami-mkpkg.log")"; return 1; }
}

rm -rf "$T"
mkdir -p "$T/home"; export HOME="$T/home"      # tatami-mkpkg looks for a signing key in ~/.tatami
mkdir -p "$ROOT/etc" "$REPO" "$T/recipes"
cat > "$CONF" <<CONFIG
CONFIG
# the file rules and the held packages live in the root's etc/tatami, not in tatami.conf
set_rules() { mkdir -p "$1/etc/tatami"; printf 'UPGRADE ^etc/.*$ NO\n' > "$1/etc/tatami/upgrade.rules"; }
set_rules "$ROOT"
# repositories are defined in <root>/etc/tatami/repos.conf and nowhere else: set_repos <root> <dir>...
set_repos() { local root="$1" i=0; shift; mkdir -p "$root/etc/tatami"; : > "$root/etc/tatami/repos.conf"
	for d in "$@"; do i=$((i+1)); echo "repo$i = $d" >> "$root/etc/tatami/repos.conf"; done; }
set_repos "$ROOT" "$REPO"
# a stand-in for bwrap: logs its arguments ($MOCK_LOG), then runs the command in the host workspace, with
# /build mapped to it. MOCK_EXIT makes it fail without running anything, MOCK_SLEEP makes it wait first.
MOCKB="$T/mockbwrap"; mkdir -p "$MOCKB"
cat > "$MOCKB/bwrap" <<'MOCKEOF'
#!/bin/bash
[ -n "$MOCK_LOG" ] && printf '%s\n' "$@" > "$MOCK_LOG"
ws=""; chdir=""; envl=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
	case "$1" in
	--bind) [ "$3" = /build ] && ws="$2"; shift 2 ;;
	--chdir) chdir="$2"; shift ;;
	--setenv) envl+=("$2=${3//\/build/$ws}"); shift 2 ;;
	esac
	shift
done
shift
[ -n "$MOCK_SLEEP" ] && sleep "$MOCK_SLEEP"
[ -n "$MOCK_EXIT" ] && exit "$MOCK_EXIT"
cd "$ws/${chdir#/build/}" || exit 97
exec env -i "${envl[@]}" PATH=/usr/bin:/bin "$@"
MOCKEOF
chmod +x "$MOCKB/bwrap"
MASTER="$T/master"; mkdir -p "$MASTER"
# tatami-mkpkg through the mock sandbox: mk [options]
mk() { PATH="$MOCKB:$PATH" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" "$@"; }
# the server side of a repository: the index of a directory is written by 'tatami update', which
# indexes a local repository; this is what tatami-mkpkg does for its output directory. (No 'tatami index'.)
publish_index() {
	local d; d=$(mktemp -d "$T/pubidx.XXXXXX"); mkdir -p "$d/etc/tatami"
	printf 'out = %s\n' "$1" > "$d/etc/tatami/repos.conf"
	"$TATAMI" -r "$d" update; local rc=$?
	rm -rf "$d"; return $rc
}
cat > "$T/fakeuname.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
/* reports FAKE_MACHINE as the machine architecture (uname -m) */
int uname(struct utsname *u) {
	int (*real)(struct utsname *) = dlsym(RTLD_NEXT, "uname");
	int r = real(u);
	const char *e = getenv("FAKE_MACHINE");
	if (r == 0 && e) { strncpy(u->machine, e, sizeof u->machine - 1); u->machine[sizeof u->machine - 1] = 0; }
	return r;
}
C
HAVE_UNAME_SHIM=0
cc -shared -fPIC -o "$T/fakeuname.so" "$T/fakeuname.c" -ldl 2>/dev/null && ldd "$TATAMI" >/dev/null 2>&1 && HAVE_UNAME_SHIM=1
# machine <arch> <command...>: run with uname() reporting that architecture
machine() { local m="$1"; shift; env LD_PRELOAD="$T/fakeuname.so" FAKE_MACHINE="$m" "$@"; }

echo "# building packages"
mkpkg libfoo 1.0 file=usr/lib/libfoo.so.1
mkpkg app 1.0 "depends=libfoo >= 1.0, virtual-editor" file=usr/bin/app file=etc/app.conf
mkpkg ed 1.0 provides=virtual-editor file=usr/bin/ed
mkpkg nano 1.0 provides=virtual-editor file=usr/bin/nano
mkpkg clash 1.0 conflicts=app file=usr/bin/clash
mkpkg thief 1.0 file=usr/bin/app
mkpkg broken 1.0 "depends=doesnotexist"
mkpkg tooold 1.0 "depends=libfoo >= 2.0"
mkpkg oldname 1.0 file=usr/bin/oldname
mkpkg newname 1.0 replaces=oldname file=usr/bin/newname
[ -f "$REPO/libfoo_1.0-1_$HARCH.$EXT" ] && ok "package built with custom extension .$EXT" || bad "package file name" "$(ls "$REPO")"
tar -tf "$REPO/libfoo_1.0-1_$HARCH.$EXT" | head -1 | grep -qx .META && ok ".META is the first member" || bad ".META first"

echo "# update / search"
check "simulated update writes nothing" 0 t -s update
absent "no index from -s update" var/lib/tatami/index
check "dependencies resolve without a prior update (index built on demand)" 0 t -s install app
has "on-demand index finds libfoo" "libfoo \(1.0-1\)"
absent "simulate writes no index" var/lib/tatami/index
check "update" 0 t update
has "update indexes every package" "Indexed 10 packages"
exists "the repository now has a binary repo.solv index" ../repo/repo.solv
check "search by name" 0 t search '^lib'
has "search finds libfoo" "libfoo/1.0-1"
check "search by description" 0 t search 'test package ed'
has "search description" "^ed/1.0-1"
check "show" 0 t show app
has "show depends (libsolv keeps its own order)" "^Depends: .*libfoo >= 1.0"
has "show the virtual dependency too" "^Depends: .*virtual-editor"
has "show not installed" "Status: not installed"
check "show unknown package" 1 t show nonexistent

echo "# install with dependencies"
check "simulate install" 0 t -s install app
has "simulate lists libfoo" "libfoo \(1.0-1\)"
absent "simulate changes nothing" usr/bin/app
check "install app" 0 ty install app
has "dependency libfoo installed" "Installing libfoo"
has "virtual provider installed" "Installing (ed|nano)"
exists "app file" usr/bin/app
exists "dependency file" usr/lib/libfoo.so.1
exists "database is in the state directory" var/lib/tatami/db
absent ".META not extracted" .META
exists "metadata stored" var/lib/tatami/meta/app
check "install again is a no-op" 0 ty install app
has "nothing to do" "Nothing to do"
check "list installed" 0 t list --installed
has "list shows app" "^app/1.0-1 \[installed\]"
check "owns" 0 t owns 'bin/app$'
has "owns finds app" "app +usr/bin/app"
check "files" 0 t files app
has "files lists app" "^usr/bin/app$"
check "files of a package file" 0 t files "$REPO/libfoo_1.0-1_$HARCH.$EXT"
has "files of package file" "usr/lib/libfoo.so.1"
check "show installed" 0 t show app
has "show status" "Status: installed \(1.0-1\)"

echo "# conflicts"
check "declared conflict is refused" 1 ty install clash
has "solver explains conflict" "conflict"
absent "clash not installed" usr/bin/clash
check "file conflict between packages is refused" 1 ty install thief
has "lists conflicting file" "usr/bin/app"
check "missing dependency is refused" 1 ty install broken
has "explains missing dependency" "doesnotexist"
check "too old dependency is refused" 1 ty install tooold
check "unknown package" 1 ty install nonexistent
has "unknown package message" "unable to locate package nonexistent"

echo "# upgrade"
mkpkg libfoo 1.1 file=usr/lib/libfoo.so.1
mkpkg libfoo 2.0 file=usr/lib/libfoo.so.1
echo "locally modified" > "$ROOT/etc/app.conf"
check "update picks up new versions" 0 t update
check "list upgradable" 0 t list --upgradable
has "upgradable shown" "libfoo/1.0-1 \[installed, upgradable to 2.0-1\]"
check "upgrade all" 0 ty upgrade
has "libfoo upgraded" "Upgrading libfoo \(1.0-1 -> 2.0-1\)"
check "libfoo is now 2.0" 0 cat "$ROOT/usr/lib/libfoo.so.1"
has "new content" "libfoo 2.0"
check "upgrade again is a no-op" 0 ty upgrade
has "nothing to do" "Nothing to do"
check "pinned version install" 0 ty install libfoo=1.1-1
has "downgrade to requested version" "libfoo"
check "version after pinned install" 0 cat "$ROOT/usr/lib/libfoo.so.1"
has "libfoo 1.1" "libfoo 1.1"
check "back to latest" 0 ty install libfoo
has "upgraded" "Upgrading libfoo \(1.1-1 -> 2.0-1\)"

echo "# configuration files (UPGRADE ^etc/ NO): the new file is installed, the existing one becomes <file>.old"
mkpkg app 2.0 "depends=libfoo >= 1.0, virtual-editor" file=usr/bin/app file=etc/app.conf
# no explicit update: tatami notices the repository changed
check "upgrade app" 0 ty install app
has "tells that the old file was saved" "etc/app.conf differs from the existing file, which was saved as etc/app.conf.old"
check "the package's new config is installed" 0 cat "$ROOT/etc/app.conf"
has "new content" "app 2.0"
[ "$(cat "$ROOT/etc/app.conf.old")" = "locally modified" ] && ok "the locally modified file is kept as etc/app.conf.old" || bad "no .old backup" "$(cat "$ROOT/etc/app.conf.old" 2>&1)"
[ ! -e "$ROOT/var/lib/tatami/rejected" ] && ok "there is no rejected directory any more" || bad "rejected directory exists"
[ -z "$(find "$ROOT" -name '*.tatami-new*')" ] && ok "no temporary files are left" || bad "temporary files left"
check "app binary upgraded" 0 cat "$ROOT/usr/bin/app"
has "new binary" "app 2.0"

echo "# install from a package file"
check "install a file argument" 0 ty install "$REPO/oldname_1.0-1_$HARCH.$EXT"
exists "file installed" usr/bin/oldname
check "reject a file with the wrong extension" 1 ty install "$T/recipes/oldname-1.0/Tatamifile"

echo "# replaces"
check "package replacing another" 0 ty install newname
has "old package removed" "Removing oldname"
exists "new file" usr/bin/newname
absent "old file gone" usr/bin/oldname

echo "# clear solver messages"
# 1. a dependency that can only be met by downgrading
mkpkg needsold 1.0 "depends=libfoo < 2.0"
check "dependency forcing a downgrade is refused" 1 ty install needsold
has "explains the downgrade" "downgrading: libfoo \(2.0-1 -> 1.1-1\)"
has "points at name=version" "name=version"
# 3. an upgrade blocked by a conflict says why
mkpkg libfoo 3.0 conflicts=app file=usr/lib/libfoo.so.1
check "blocked upgrade" 0 ty upgrade
has "reports the blocked package" "libfoo cannot be upgraded to 3.0-1"
has "gives the reason" "conflict"
has "still says nothing to do" "Nothing to do"
check "blocked install of installed package" 0 ty install libfoo
has "reason shown for install too" "libfoo cannot be upgraded to 3.0-1"
# 4. package built for another architecture
mkpkg foreign 1.0 arch=riscv64z
check "foreign architecture" 1 ty install foreign
has "incompatible architecture message" "built for architecture riscv64z, which is incompatible with this system"
hasnt "not the generic message" "unable to locate"
# 2. replaces matches virtual provides
check "ed provides the editor app needs" 0 test -e "$ROOT/usr/bin/ed"
mkpkg vi2 1.0 provides=virtual-editor replaces=virtual-editor file=usr/bin/vi2
check "replacing a virtual provide" 0 ty install vi2
has "provider replaced" "Removing ed"
absent "old provider files gone" usr/bin/ed
exists "new provider installed" usr/bin/vi2

echo "# remove"
check "remove libfoo removes dependents" 0 ty remove libfoo
has "dependent app removed" "Removing app"
has "libfoo removed" "Removing libfoo"
absent "app gone" usr/bin/app
absent "libfoo gone" usr/lib/libfoo.so.1
absent "empty dirs cleaned" usr/share/app
absent "metadata removed" var/lib/tatami/meta/libfoo
exists "other packages untouched" usr/bin/newname
check "list shows installed packages only" 0 t list
hasnt "a removed package is not listed" "^libfoo/"
hasnt "available but not installed packages are not listed" "^clash/"
has "installed packages are listed" "^newname/1.0-1 \\[installed\\]"
check "list --available reads the repository index" 0 t list --available
has "removed package is still available" "^libfoo/3.0-1$"
has "available package that was never installed" "^clash/1.0-1$"
has "installed package is marked in the available list" "^newname/1.0-1 \\[installed\\]"
check "search reads the index too" 0 t search '^libfoo$'
has "search still finds the removed package" "^libfoo/3.0-1"
check "list works without any repository index" 0 bash -c "mkdir -p '$T/noidx/var/lib/tatami' && cp '$ROOT/var/lib/tatami/db' '$T/noidx/var/lib/tatami/db' && '$TATAMI' -r '$T/noidx' -c '$CONF' list"
has "list from the database alone" "^newname/1.0-1 \\[installed\\]"
absent "list did not create an index" ../noidx/var/lib/tatami/index
check "remove not installed" 1 ty remove libfoo
check "database backup exists" 0 test -f "$ROOT/var/lib/tatami/db.backup"

echo "# declined confirmation"
mkpkg extra 1.0 file=usr/bin/extra
check "declining is a failure exit" 1 bash -c "echo n | script -qec '$TATAMI -r $ROOT -c $CONF install extra' /dev/null"
absent "nothing installed after declining" usr/bin/extra
check "non-interactive without -y is refused" 1 t install extra
absent "still not installed" usr/bin/extra

echo "# tatami-mkpkg: a standalone static binary; the build runs in a bwrap sandbox (mocked here)"
ldd "$MKPKG" 2>&1 | grep -q 'not a dynamic' && ok "tatami-mkpkg is a statically linked binary" || bad "tatami-mkpkg is dynamically linked" "$(ldd "$MKPKG" 2>&1)"
head -c 4 "$MKPKG" | grep -q 'ELF' && ok "and a compiled program, not a script" || bad "tatami-mkpkg is not an ELF binary"
leftovers() { ls /tmp | grep -Ec '^[a-z0-9]{16,32}$'; }
SB="$T/sb"; rm -rf "$SB"; mkdir -p "$SB/r" "$SB/out" "$SB/srv"
LEFT=$(leftovers)
cat > "$SB/r/Tatamifile" <<RECIPE
# Description: Sandbox test
name=sbox
version=1.0
release=2
arch=$HARCH
depends=(glibc "libfoo >= 2.0" "a | b")
build() {
	echo "\$PWD \$(basename \$SRC) \$(basename \$PKG) \$name \$version \$release" > \$PKG/env
	ls "\$SRC" > \$PKG/srclist
}
package() { echo packaged >> \$PKG/env; }
RECIPE
NM="sbox_1.0-2_$HARCH.$EXT"
export MOCK_LOG="$SB/args"
check "a build through the (mock) sandbox succeeds" 0 mk -f "$SB/r/Tatamifile" -o "$SB/out"
unset MOCK_LOG
[ -f "$SB/out/$NM" ] && ok "and makes $NM" || bad "no package" "$(ls "$SB/out")"
ENVF=$(tar -xOf "$SB/out/$NM" env 2>/dev/null)
echo "$ENVF" | head -1 | grep -Eq '^/tmp/[a-z0-9]{24}/src src pkg sbox 1.0 2$' && ok "build() ran in <workspace>/src with SRC=.../src, PKG=.../pkg and name, version, release set" || bad "environment of build()" "$ENVF"
echo "$ENVF" | grep -qx packaged && ok "package() ran after build()" || bad "package() did not run"
[ -z "$(tar -xOf "$SB/out/$NM" srclist 2>/dev/null)" ] && ok "the source directory was empty (src and pkg are separate directories)" || bad "src not empty" "$(tar -xOf "$SB/out/$NM" srclist)"
tar -tf "$SB/out/$NM" | head -1 | grep -qx '\.META' && ok ".META is the first member" || bad ".META not first" "$(tar -tf "$SB/out/$NM" | head -3)"
ARGS=$(sed '/^--$/q' "$SB/args" | paste -sd' ' -)
for a in --unshare-all --die-with-parent --new-session --clearenv; do echo " $ARGS " | grep -q -- " $a " && ok "bwrap gets $a" || bad "bwrap lacks $a" "$ARGS"; done
echo "$ARGS" | grep -qF -- "--ro-bind $MASTER / --dev /dev --proc /proc --tmpfs /tmp" && ok "the masterdir is the root, bound read-only; /dev, /proc and a tmpfs /tmp follow" || bad "root and API file systems" "$ARGS"
echo "$ARGS" | grep -Eq -- "--bind /tmp/[a-z0-9]{24} /build --chdir /build/src" && ok "the workspace /tmp/<24 lowercase letters and digits> is bound read-write at /build, and the directory is /build/src" || bad "workspace bind" "$ARGS"
for kv in "SRC /build/src" "PKG /build/pkg" "name sbox" "version 1.0" "release 2"; do echo "$ARGS" | grep -qF -- "--setenv $kv" && ok "--setenv $kv" || bad "no --setenv $kv" "$ARGS"; done
sed -n '/^--$/,$p' "$SB/args" | sed -n '2,3p' | paste -sd' ' - | grep -qx '/bin/sh -c' && ok "the build script is run by /bin/sh -c" || bad "command" "$(sed -n '/^--$/,$p' "$SB/args" | head -4)"
WS=$(echo "$ARGS" | grep -Eo '/tmp/[a-z0-9]{24}' | head -1)
[ -n "$WS" ] && [ ! -e "$WS" ] && ok "the workspace $WS is deleted after a successful build" || bad "workspace left behind" "$WS"
[ "$(leftovers)" = "$LEFT" ] && ok "no directory is left in /tmp" || bad "leftovers in /tmp"
for d in dev proc tmp build; do [ -d "$MASTER/$d" ] || bad "mount point $d missing in the masterdir"; done; ok "the mount points exist in the (read-only) masterdir"
tar -xOf "$SB/out/$NM" .META | grep -qx 'depends: glibc, libfoo >= 2.0, a | b' && ok ".META: depends keep their version conditions and alternatives" || bad "depends in .META" "$(tar -xOf "$SB/out/$NM" .META)"
tar -xOf "$SB/out/$NM" .META | grep -qx 'description: Sandbox test' && ok ".META: the description comes from '# Description:'" || bad "description"
tar -xOf "$SB/out/$NM" .META | grep -qx "version: 1.0-2" && ok ".META: version is <version>-<release>" || bad "version in .META"
check "tatami reads the package" 0 "$TATAMI" -c "$CONF" files "$SB/out/$NM"

# failing builds leave nothing behind
printf 'name=failing\nversion=1\narch=%s\nbuild() {\n\tmkdir -p $PKG/usr/bin\n\tfalse\n\techo late > $PKG/usr/bin/failing\n}\n' "$HARCH" > "$SB/r/Failing"
check "a failing command in build() fails the build" 1 mk -f "$SB/r/Failing" -o "$SB/out"
has "with the old message" "ERROR: building failing failed"
[ ! -e "$SB/out/failing_1_$HARCH.$EXT" ] && ok "no package produced by failing build" || bad "package produced by failing build"
[ "$(leftovers)" = "$LEFT" ] && ok "and the workspace is gone" || bad "workspace left after a failed build"
printf 'name=nothing\nversion=1\narch=%s\nbuild() { :; }\n' "$HARCH" > "$SB/r/Nothing"
check "a build that installs nothing into \$PKG fails" 1 mk -f "$SB/r/Nothing" -o "$SB/out"
has "with a message" 'installed nothing into \$PKG'
OUT=$(MOCK_EXIT=7 mk -f "$SB/r/Tatamifile" -o "$SB/out2" 2>&1); rc=$?
[ $rc -ne 0 ] && [ ! -e "$SB/out2/$NM" ] && [ "$(leftovers)" = "$LEFT" ] && ok "a sandbox that exits with an error fails the build and the workspace is deleted" || bad "bwrap failure" "$OUT"
OUT=$(PATH="$T/nobin:/nonexistent" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/out2" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "cannot run bwrap" && echo "$OUT" | grep -q "bubblewrap" && ok "without bwrap: a clear error that names bubblewrap" || bad "missing bwrap" "$OUT"
[ "$(leftovers)" = "$LEFT" ] && ok "and nothing is left in /tmp" || bad "workspace left without bwrap"
OUT=$(mk -m "$SB/no-masterdir" -f "$SB/r/Tatamifile" -o "$SB/out2" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "masterdir .* does not exist" && ok "a missing masterdir is an error" || bad "missing masterdir" "$OUT"
# an interrupt: forwarded to the sandbox, then the workspace is deleted all the same
PATH="$MOCKB:$PATH" TATAMI="$TATAMI" MOCK_SLEEP=5 "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/out2" > "$SB/intr.log" 2>&1 &
BGP=$!; sleep 1
kill -TERM "$BGP"; wait "$BGP"; rc=$?
[ $rc -ne 0 ] && grep -q "interrupted by signal" "$SB/intr.log" && ok "SIGTERM during the build stops it with 'interrupted'" || bad "interrupt (rc $rc)" "$(cat "$SB/intr.log")"
[ "$(leftovers)" = "$LEFT" ] && ok "and the workspace is deleted" || bad "workspace left after an interrupt"

echo "# tatami-mkpkg: options"
for o in "-c $CONF" --no-bulkhead --no-sandbox --bulkhead -k --keep-work; do
	OUT=$(mk $o -f "$SB/r/Tatamifile" -o "$SB/out2" 2>&1); rc=$?
	[ $rc -ne 0 ] && echo "$OUT" | grep -q "invalid option" && ok "${o%% *}: the option of the former script is gone" || bad "${o%% *} was accepted" "$OUT"
done
check "-h prints the usage" 0 "$MKPKG" -h
has "it names the masterdir option" "--masterdir"
has "and the signing key" "TATAMI_PRIVKEY"
check "-v prints the version" 0 "$MKPKG" -v
has "tatami-mkpkg and a version" "^tatami-mkpkg [0-9]"
check "an option without its argument is an error" 1 "$MKPKG" -f
check "a missing recipe is an error" 1 mk -f "$SB/r/NoSuchFile"
has "which says so" "not found"

echo "# tatami-mkpkg: the Tatamifile"
rb() { printf '%b' "$1" > "$SB/r/Bad"; OUT=$(mk -f "$SB/r/Bad" -o "$SB/out3" 2>&1); rc=$?; }
GOOD='build() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n'
rb "name=x\nversion=1\narch=$HARCH\n$GOOD"
[ $rc -eq 0 ] && [ -f "$SB/out3/x_1_$HARCH.$EXT" ] && ok "release is optional: the package is <name>_<version>_<arch>" || bad "recipe without release" "$OUT $(ls "$SB/out3")"
rb "name=x\nversion=1\nrelease=3\narch=$HARCH\nmakedepends=(gcc 'bad, entry' \"a b\")\nconflicts=(\"old < 2\")\nreplaces=(older)\nprovides=(x-api)\nanything=\"goes here\"\n$GOOD"
[ $rc -eq 0 ] && ok "makedepends, conflicts, replaces, provides and other fields are ignored, not parsed" || bad "ignored fields were not ignored" "$OUT"
M3=$(tar -xOf "$SB/out3/x_1-3_$HARCH.$EXT" .META 2>/dev/null)
echo "$M3" | grep -Eq '^(conflicts|replaces|provides|makedepends):' && bad ".META has an ignored field" "$M3" || ok "and none of them reaches .META"
rb "name=x\nversion=1\n$GOOD"
[ $rc -ne 0 ] && [ "$OUT" = "Error: arch is not defined in Tatamifile" ] && ok "arch is required: exactly 'Error: arch is not defined in Tatamifile'" || bad "recipe without arch" "$OUT"
rb "name=x\nversion=1\narch=\n$GOOD"
[ $rc -ne 0 ] && [ "$OUT" = "Error: arch is not defined in Tatamifile" ] && ok "an empty arch= is the same error" || bad "empty arch" "$OUT"
rb "version=1\narch=$HARCH\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "does not set 'name'" && ok "name is required" || bad "no name" "$OUT"
rb "name=x\narch=$HARCH\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "does not set 'version'" && ok "version is required" || bad "no version" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\n"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "does not define build()" && ok "build() is required" || bad "no build()" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\nbuild() { mkdir -p \$PKG/x; echo x > \$PKG/x/f; }\npackage() { echo p > \$PKG/x/p; }\n"
[ $rc -eq 0 ] && tar -tf "$SB/out3/x_1_$HARCH.$EXT" | grep -qx 'x/p' && ok "package() is optional, and runs when present" || bad "package()" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\ndepends=(\"a, b\")\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "must not contain a comma" && ok "a relation containing a comma is refused" || bad "comma in depends" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\nrm -rf /\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "line 4: unsupported statement 'rm'" && ok "a command in the recipe is a syntax error with its line: nothing runs on the host" || bad "command in the recipe" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\nbuild() { echo hi\n"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "missing '}'" && ok "an unclosed function body is a syntax error" || bad "unclosed body" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\nsource=(\$nope)\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q 'variable \$nope is not set' && ok "an unset variable is an error" || bad "unset variable" "$OUT"
rb "name=x\nversion=1\narch=$HARCH\ndepends=(a \"b\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "unterminated quote" && ok "an unterminated quote is an error" || bad "unterminated quote" "$OUT"
rb "name=under_score\nversion=1\narch=$HARCH\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "only contain letters, digits" && ok "'_' in a package name is refused (it separates name and version in file names)" || bad "underscore in name" "$OUT"
rb "name=-x\nversion=1\narch=$HARCH\n$GOOD"; [ $rc -ne 0 ] && echo "$OUT" | grep -q "must start with a letter or digit" && ok "a name must start with a letter or digit" || bad "name starting with a dash" "$OUT"
rb "# a comment\nname=multi   # trailing comment\nversion='1.0'\narch=\"$HARCH\"\ndepends=(\n\t# one per line\n\tfoo\n\t'bar >= 1'\n)\nbuild() {\n\tmkdir -p \$PKG/x\n\techo '}' > \$PKG/x/brace   # } in a comment and in quotes\n}\n"
[ $rc -eq 0 ] && tar -xOf "$SB/out3/multi_1.0_$HARCH.$EXT" .META | grep -qx 'depends: foo, bar >= 1' && ok "comments, quotes, multi-line arrays and braces inside quotes and comments are understood" || bad "parser details" "$OUT"
for a in noarch ANY All NoArch; do
	rb "name=na$(echo $a | tr 'A-Z' 'a-z')\nversion=1\narch=$a\n$GOOD"
	[ -f "$SB/out3/na$(echo $a | tr 'A-Z' 'a-z')_1_noarch.$EXT" ] && ok "arch=$a is written noarch" || bad "arch=$a" "$OUT $(ls "$SB/out3")"
done
rb "name=x86\nversion=2.5\nrelease=1\narch=x86_64\n$GOOD"
[ -f "$SB/out3/x86_2.5-1_x86_64.$EXT" ] && ok "an underscore in the architecture does not confuse the name: x86_2.5-1_x86_64.$EXT" || bad "x86_64 name" "$OUT $(ls "$SB/out3")"
check "tatami parses these names back without a warning" 0 bash -c "mkdir -p '$SB/ext-root/etc/tatami'; echo 'p = $SB/out3' > '$SB/ext-root/etc/tatami/repos.conf'; '$TATAMI' -r '$SB/ext-root' update"
hasnt "no naming warning" "named differently"

echo "# tatami-mkpkg: sources"
if command -v curl >/dev/null && command -v md5sum >/dev/null; then
	mkdir -p "$SB/src/demo-1.0/pkg" "$SB/srvdir" "$SB/rs"
	echo hello > "$SB/src/demo-1.0/hello.txt"; echo inner > "$SB/src/demo-1.0/pkg/inner.txt"
	( cd "$SB/src" && tar czf "$SB/srvdir/demo-1.0.tar.gz" demo-1.0 )
	echo patch > "$SB/rs/fix.patch"
	cat > "$SB/rs/Tatamifile" <<RECIPE
name=demo
version=1.0
arch=$HARCH
source=(file://$SB/srvdir/\$name-\$version.tar.gz fix.patch)
build() {
	cd demo-1.0
	mkdir -p \$PKG/usr/share/demo
	cp hello.txt pkg/inner.txt ../fix.patch \$PKG/usr/share/demo/
}
RECIPE
	( cd "$SB/rs" && md5sum fix.patch > .md5sum; md5sum "$SB/srvdir/demo-1.0.tar.gz" | sed 's|  .*|  demo-1.0.tar.gz|' >> .md5sum )
	check "a remote source is fetched, checked and unpacked; a local one is copied" 0 mk -f "$SB/rs/Tatamifile" -o "$SB/out4"
	has "downloaded" "Downloading file://"
	has "checksums verified" "Checking md5sum"
	[ -f "$SB/rs/demo-1.0.tar.gz" ] && ok "the download is kept next to the recipe" || bad "no download cache"
	DP="$SB/out4/demo_1.0_$HARCH.$EXT"
	tar -tf "$DP" | grep -qx 'usr/share/demo/hello.txt' && tar -tf "$DP" | grep -qx 'usr/share/demo/inner.txt' && tar -tf "$DP" | grep -qx 'usr/share/demo/fix.patch' && ok "the unpacked tarball (including its own top-level pkg/ directory) and the patch are in /build/src, apart from \$PKG" || bad "sources" "$(tar -tf "$DP")"
	tar -tf "$DP" | grep -c 'inner.txt' | grep -qx 1 && ok "the tarball's pkg/ directory did not clash with the package root" || bad "layout clash"
	rm -f "$SB/srvdir/demo-1.0.tar.gz"
	check "an already downloaded source is not fetched again" 0 mk -f "$SB/rs/Tatamifile" -o "$SB/out4"
	hasnt "no second download" "Downloading"
	echo tampered >> "$SB/rs/demo-1.0.tar.gz"
	check "a source that does not match .md5sum fails the build" 1 mk -f "$SB/rs/Tatamifile" -o "$SB/out5"
	has "md5sum says so" "md5sum verification failed"
	[ ! -e "$SB/out5/demo_1.0_$HARCH.$EXT" ] && [ "$(leftovers)" = "$LEFT" ] && ok "no package, no workspace" || bad "left after a checksum failure"
	rm -f "$SB/rs/.md5sum"
	printf 'name=nosrc\nversion=1\narch=%s\nsource=(missing.tar.gz)\nbuild() { :; }\n' "$HARCH" > "$SB/rs/Missing"
	check "a missing local source is an error" 1 mk -f "$SB/rs/Missing" -o "$SB/out5"
	has "naming it" "source 'missing.tar.gz' not found"
	printf 'name=nodl\nversion=1\narch=%s\nsource=(file://%s/nothing-here.tar.gz)\nbuild() { :; }\n' "$HARCH" "$SB/srvdir" > "$SB/rs/Nodl"
	check "a download that fails is an error" 1 mk -f "$SB/rs/Nodl" -o "$SB/out5"
	has "naming the URL" "download of file://.*nothing-here.tar.gz failed"
	[ ! -e "$SB/rs/nothing-here.tar.gz.part" ] && ok "and leaves no partial file" || bad "partial download left"
	mkdir -p "$SB/evil" && ( cd "$SB/evil" && mkdir d && echo x > d/f && tar cf "$SB/rs/evil.tar" --transform 's|^d/|../../escape-|' d/f 2>/dev/null )
	printf 'name=evil\nversion=1\narch=%s\nsource=(evil.tar)\nbuild() { mkdir -p $PKG/a; echo > $PKG/a/f; }\n' "$HARCH" > "$SB/rs/Evil"
	check "a tarball with a path that leaves the source directory is refused" 1 mk -f "$SB/rs/Evil" -o "$SB/out5"
	has "naming the path" "unsafe path"
	[ ! -e /tmp/escape-f ] && [ "$(leftovers)" = "$LEFT" ] && ok "and nothing was written outside the workspace" || bad "tarball escaped"
else
	echo "skip - sources (needs curl and md5sum)"
fi

echo "# tatami-mkpkg: .INSTALL, signing and the index"
SGK="$SB/sk"; mkdir -p "$SGK"; HOME="$SGK/home" "$TATAMI" keygen >/dev/null 2>&1
SIGNED() { ( cd "$SB" && HOME="$SGK/home" mk "$@" ); }
mkdir -p "$SB/srepo"
check "with a key in ~/.tatami/privkey the build signs" 0 SIGNED -f "$SB/r/Tatamifile" -o "$SB/srepo"
has "it says so" "Signing with $SGK/home/.tatami/privkey"
[ -f "$SB/srepo/$NM.sig" ] && [ -f "$SB/srepo/repo.solv" ] && [ -f "$SB/srepo/repo.solv.sig" ] && ok "the package, its .sig, repo.solv and repo.solv.sig are in the output directory" || bad "signing output" "$(ls "$SB/srepo")"
[ "$(head -c 4 "$SB/srepo/repo.solv")" = SOLV ] && ok "repo.solv is the tatami index" || bad "repo.solv"
check "tatami can use the repository" 0 bash -c "mkdir -p '$SB/sroot/etc/tatami'; echo 'p = $SB/srepo' > '$SB/sroot/etc/tatami/repos.conf'; '$TATAMI' -r '$SB/sroot' list --available | grep -q sbox"
check "a build with no key is unsigned" 0 env -u TATAMI_PRIVKEY HOME="$SB/nohome" PATH="$MOCKB:$PATH" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/unsigned"
has "it says that" "Not signing \(no key: run 'tatami keygen'\)"
[ -f "$SB/unsigned/$NM" ] && [ ! -e "$SB/unsigned/$NM.sig" ] && [ ! -e "$SB/unsigned/repo.solv" ] && ok "no .sig, no index" || bad "unsigned build" "$(ls "$SB/unsigned")"
check "--no-sign skips signing even with a key" 0 SIGNED --no-sign -f "$SB/r/Tatamifile" -o "$SB/nosign"
[ -f "$SB/nosign/$NM" ] && [ ! -e "$SB/nosign/$NM.sig" ] && ok "no .sig with --no-sign" || bad "--no-sign" "$(ls "$SB/nosign")"
check "a TATAMI_PRIVKEY that does not exist is an error" 1 env TATAMI_PRIVKEY="$SB/missing" PATH="$MOCKB:$PATH" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/x"
has "the message names it" "signing key $SB/missing \(TATAMI_PRIVKEY\) not found"
[ ! -e "$SB/x" ] || [ -z "$(ls "$SB/x" 2>/dev/null)" ] && ok "and nothing is built" || bad "built despite the missing key"
check "TATAMI_PRIVKEY wins over ~/.tatami/privkey" 0 env TATAMI_PRIVKEY="$SGK/home/.tatami/privkey" HOME="$SB/nohome" PATH="$MOCKB:$PATH" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/srepo2"
[ -f "$SB/srepo2/$NM.sig" ] && ok "signed with it" || bad "TATAMI_PRIVKEY not used"
OUT=$(env TATAMI_PRIVKEY="$SGK/home/.tatami/privkey" TATAMI=/nonexistent/tatami PATH="$MOCKB:$PATH" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/x2" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "needs the tatami binary" && echo "$OUT" | grep -q "TATAMI=/path/to/tatami" && ok "a key but no tatami binary: an error before anything is built" || bad "missing tatami binary" "$OUT"
echo notakey > "$SB/bad.key"
OUT=$(env TATAMI_PRIVKEY="$SB/bad.key" PATH="$MOCKB:$PATH" TATAMI="$TATAMI" "$MKPKG" -m "$MASTER" -f "$SB/r/Tatamifile" -o "$SB/x3" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "could not sign" && ok "a key that cannot sign is an error" || bad "bad key" "$OUT"
[ "$(leftovers)" = "$LEFT" ] && [ -z "$(ls /tmp | grep tatami-mkpkg-index)" ] && ok "and neither the workspace nor the index scratch directory is left" || bad "leftovers after a signing failure"

echo "# commands that moved into tatami-mkpkg are gone from tatami"
for c in bulkhead pack; do
	OUT=$("$TATAMI" $c 2>&1); rc=$?
	[ $rc -ne 0 ] && echo "$OUT" | grep -q "unknown command '$c'" && ok "tatami $c is an unknown command" || bad "tatami $c still exists (rc $rc)" "$OUT"
done
OUT=$("$TATAMI" --help 2>&1)
echo "$OUT" | grep -Eqi 'bulkhead|^ *pack ' && bad "--help still mentions bulkhead or pack" "$OUT" || ok "--help mentions neither"
printf 'BULKHEAD = no\n' > "$T/oldbulk.conf"
check "BULKHEAD in tatami.conf is an unknown setting" 1 "$TATAMI" -r "$ROOT" -c "$T/oldbulk.conf" list
has "reported as unknown, with its line" "oldbulk.conf:1: unknown setting 'BULKHEAD'"

echo "# architecture-independent packages"
mkpkg na-noarch 1.0 arch=noarch file=usr/share/na/noarch
mkpkg na-any 1.0 arch=any file=usr/share/na/any
mkpkg na-all 1.0 arch=all file=usr/share/na/all
mkpkg na-mixed 1.0 arch=NoArch file=usr/share/na/mixed
mkpkg arch-explicit 1.0 arch=$HARCH file=usr/share/na/explicit
mkpkg na-foreign 1.0 arch=riscv64z file=usr/share/na/foreign
check "noarch, any, all, NoArch and explicit host-architecture packages install on this host" 0 ty install na-noarch na-any na-all na-mixed arch-explicit
exists "noarch installed" usr/share/na/noarch
exists "any installed" usr/share/na/any
exists "all installed" usr/share/na/all
exists "mixed-case NoArch installed" usr/share/na/mixed
exists "package with an explicit host architecture installed" usr/share/na/explicit
OUT=$(t show arch-explicit 2>&1); has "and it carries the host architecture it was built with" "Architecture *: *$HARCH"
check "a package for another architecture is still refused" 1 ty install na-foreign
has "with the architecture message" "incompatible with this system"
absent "foreign package not installed" usr/share/na/foreign
check "noarch also installs from a file argument" 0 ty install "$REPO/na-any_1.0-1_noarch.$EXT"
check "noarch installs when the host architecture is unknown to libsolv" 0 machine zz80 "$TATAMI" -r "$ROOT" -c "$CONF" -s install na-noarch

echo "# package names: <name>_<version>-<release>_<arch>.tar.<compression>, or a fixed extension"
DEFEXT=$(mk -h | sed -n "s/.*fixed when tatami was built: '\([^']*\)'.*/\1/p" | head -1)
[ -n "$DEFEXT" ] && ok "the build-time extension is compiled into tatami-mkpkg (${DEFEXT:-automatic})" || bad "default extension not compiled into tatami-mkpkg" "$DEFEXT"
[ "$DEFEXT" = tar.pkg ] && ok "the default extension is tar.pkg" || bad "default extension is not tar.pkg" "$DEFEXT"
DEFCOMP=$(mk -h | sed -n "s/.*(default: '\([a-z0-9]*\)').*/\1/p" | head -1)
[ "$DEFCOMP" = zst ] && ok "the build-time compression is zst by default" || bad "default compression is not zst" "$DEFCOMP"
grep -v '^#' "$REPO_ROOT_DIR/build.conf" 2>/dev/null | grep -q '[^[:space:]]' && bad "build.conf has an active assignment" || ok "build.conf has only commented-out lines"
EXPECT="$DEFEXT"
mkdir -p "$T/extrepo" "$T/recipes/ext1"
printf 'name=ext1\nversion=1\nrelease=3\narch='$HARCH'\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext1/Tatamifile"
printf '' > "$T/noext.conf"
set_repos "$T/extroot" "$T/extrepo"
check "tatami-mkpkg names the package by the build-time extension" 0 mk -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext1_1-3_${HARCH}.$EXPECT" ] && ok "package is named ext1_1-3_${HARCH}.$EXPECT" || bad "default-named package missing" "$(ls "$T/extrepo")"
[ "$(head -c 4 "$T/extrepo/ext1_1-3_${HARCH}.$EXPECT" | od -An -tx1 | tr -d ' \n')" = 28b52ffd ] && ok "and it is compressed with the build-time default, zstd" || bad "default compression"
check "tatami recognises that name" 0 "$TATAMI" -r "$T/extroot" -c "$T/noext.conf" update
has "tatami found the default-named package" "1 package"
hasnt "no naming warning" "named differently"

# nothing at run time can change them: not the configuration, not the environment
printf 'PKG_EXT = other\n' > "$T/badext.conf"
check "PKG_EXT in tatami.conf is refused by tatami" 1 "$TATAMI" -r "$ROOT" -c "$T/badext.conf" list
has "with a message that points to build.conf" "PKG_EXT is a compile-time setting.*build.conf"
printf 'PKG_COMPRESSION = gz\n' > "$T/badcomp.conf"
check "PKG_COMPRESSION in tatami.conf is refused by tatami" 1 "$TATAMI" -r "$ROOT" -c "$T/badcomp.conf" list
has "with the same message" "PKG_COMPRESSION is a compile-time setting.*build.conf"
rm -f "$T/extrepo"/ext1_*
printf 'PKG_EXT = other\nPKG_COMPRESSION = gz\n' > "$T/ignored2.conf"
OUT=$(PKG_EXT=envext PKG_COMPRESSION=gz mk -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo" 2>&1)
[ -f "$T/extrepo/ext1_1-3_${HARCH}.$EXPECT" ] && [ "$(ls "$T/extrepo" | grep -c "^ext1_")" = 1 ] && ok "tatami-mkpkg ignores PKG_EXT in the configuration and in the environment" || bad "tatami-mkpkg was influenced at run time" "$(ls "$T/extrepo")"
[ "$(head -c 4 "$T/extrepo/ext1_1-3_${HARCH}.$EXPECT" | od -An -tx1 | tr -d ' \n')" = 28b52ffd ] && ok "and PKG_COMPRESSION too: still zstd" || bad "compression changed at run time"

# other values need another build: variants are built from a copy of the sources
# a variant's tatami-mkpkg through the mock sandbox: mkv <variant-dir> [options]
mkv() { local v="$1"; shift; PATH="$MOCKB:$PATH" TATAMI="$v/tatami" "$v/tatami-mkpkg" -m "$MASTER" "$@"; }
variant() { # <name> <make variables...>: builds tatami and tatami-mkpkg into $T/var-<name>
	local d="$T/var-$1"; shift
	rm -rf "$d"; mkdir -p "$d"
	cp -r "$REPO_ROOT_DIR/src" "$REPO_ROOT_DIR/Makefile" "$REPO_ROOT_DIR/build.conf" "$d/"
	rm -f "$d"/src/*.o "$d"/src/*.d
	( cd "$d" && make -j4 DEPS_DIR="$REPO_ROOT_DIR/deps" "$@" ) > "$d/build.log" 2>&1
}
if variant custom PKG_EXT=tpkg PKG_COMPRESSION=gz; then
	VC="$T/var-custom"; ok "a build with PKG_EXT=tpkg PKG_COMPRESSION=gz"
	rm -f "$T/extrepo"/ext1_*
	check "that tatami-mkpkg names the package .tpkg" 0 mkv "$VC" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	[ -f "$T/extrepo/ext1_1-3_${HARCH}.tpkg" ] && ok "ext1_1-3_${HARCH}.tpkg" || bad "custom extension" "$(ls "$T/extrepo")"
	[ "$(head -c 2 "$T/extrepo/ext1_1-3_${HARCH}.tpkg" | od -An -tx1 | tr -d ' \n')" = 1f8b ] && ok "compressed with gzip, the build-time compression" || bad "custom compression"
	check "that tatami indexes it" 0 "$VC/tatami" -r "$T/extroot" -c "$T/noext.conf" update
	has "one package" "Indexed 1 package"
	check "a tatami with the default extension does not take .tpkg as a package" 0 "$TATAMI" -r "$T/extroot" -c "$T/noext.conf" update
	has "none found" "Indexed 0 package"
else
	bad "variant build (PKG_EXT=tpkg PKG_COMPRESSION=gz)" "$(tail -5 "$T/var-custom/build.log")"
fi
if variant auto PKG_EXT=; then
	VA="$T/var-auto"; ok "a build with an empty PKG_EXT"
	AUTOENV() { mkv "$VA" "$@"; }
	rm -rf "$T/extrepo"; mkdir -p "$T/extrepo"
	check "an empty PKG_EXT names the package by its compression" 0 AUTOENV -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	[ -f "$T/extrepo/ext1_1-3_${HARCH}.tar.zst" ] && ok "default compression zstd: ext1_1-3_${HARCH}.tar.zst" || bad "automatic name missing" "$(ls "$T/extrepo")"
	for c in xz gz bz2 lz4 lzma; do
		check "tatami-mkpkg -z $c names the package tar.$c" 0 AUTOENV -z $c -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
		[ -f "$T/extrepo/ext1_1-3_${HARCH}.tar.$c" ] && ok "ext1_1-3_${HARCH}.tar.$c exists" || bad "tar.$c package missing" "$(ls "$T/extrepo")"
	done
	check "tatami-mkpkg -z none names it .tar" 0 AUTOENV -z none -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	[ -f "$T/extrepo/ext1_1-3_${HARCH}.tar" ] && ok "uncompressed package is ext1_1-3_${HARCH}.tar" || bad "plain tar package missing"
	check "tatami-mkpkg refuses an unknown compression" 1 AUTOENV -z rot13 -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	check "tatami indexes every tar.<compression> in one repository" 0 "$VA/tatami" -r "$T/extroot" -c "$T/noext.conf" update
	has "the same package in several formats is indexed once" "Indexed 1 package "
	has "and the extra copies are reported" "ext1 1-3 is already in the repository"
else
	bad "variant build (empty PKG_EXT)" "$(tail -5 "$T/var-auto/build.log")"
fi
if variant xzext PKG_EXT=tar.xz; then
	rm -rf "$T/extrepo"; mkdir -p "$T/extrepo"
	check "an extension that names a compression selects it" 0 mkv "$T/var-xzext" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	[ "$(head -c 6 "$T/extrepo/ext1_1-3_${HARCH}.tar.xz" | od -An -tx1 | tr -d ' \n')" = fd377a585a00 ] && ok "PKG_EXT=tar.xz packs with xz" || bad "extension-derived compression" "$(ls "$T/extrepo")"
else
	bad "variant build (PKG_EXT=tar.xz)" "$(tail -5 "$T/var-xzext/build.log")"
fi
# a different directory layout: every path is a compile-time constant below the root, in tatami and in tatami-mkpkg
if variant lay SYSCONFDIR=/opt/etc DB_DIR=/srv/db CACHEDIR=/srv/cache; then
	VL="$T/var-lay"; LR="$T/layroot"; rm -rf "$LR" "$T/layrepo" "$T/layhome"; mkdir -p "$LR" "$T/layrepo" "$T/layhome"
	mkdir -p "$LR/opt/etc/tatami"; echo "lay = $T/layrepo" > "$LR/opt/etc/tatami/repos.conf"
	HOME="$T/layhome" "$VL/tatami" keygen >/dev/null
	printf 'name=laypkg\nversion=1\narch=%s\nbuild() { mkdir -p $PKG/usr/share/laypkg; echo lay > $PKG/usr/share/laypkg/f; }\n' "$HARCH" > "$T/layrepo.Tatamifile"
	OUT=$(HOME="$T/layhome" mkv "$VL" -f "$T/layrepo.Tatamifile" -o "$T/layrepo" 2>&1); rc=$?
	[ $rc -eq 0 ] && [ "$(head -c 4 "$T/layrepo/repo.solv" 2>/dev/null)" = SOLV ] && [ -f "$T/layrepo/repo.solv.sig" ] && ok "tatami-mkpkg (SYSCONFDIR=/opt/etc) indexes and signs its output directory" || bad "tatami-mkpkg with a custom layout (exit $rc)" "$OUT"
	check "tatami finds the repository in <root>/opt/etc/tatami/repos.conf" 0 "$VL/tatami" -r "$LR" -y install laypkg
	[ -f "$LR/usr/share/laypkg/f" ] && ok "and installs from it" || bad "not installed"
	[ -d "$LR/srv/db" ] && ok "the database is below <root>/srv/db (DB_DIR)" || bad "no DB_DIR" "$(find "$LR" -maxdepth 3 | head)"
	[ ! -e "$LR/var/lib/tatami" ] && [ ! -e "$LR/etc/tatami" ] && ok "nothing was created at the default locations" || bad "default locations used" "$(find "$LR" -maxdepth 3 -path '*tatami*')"
	printf 'laypkg\n' > "$LR/opt/etc/tatami/hold"
	check "the hold file is read from SYSCONFDIR too" 0 "$VL/tatami" -r "$LR" -y remove laypkg
	OUT=$(HOME="$T/layhome" "$VL/tatami" keygen -f 2>&1)
	echo "$OUT" | grep -q "cp .*privkey.pub /opt/etc/tatami/keys/" && ok "keygen names the key directory of that layout" || bad "keygen message" "$OUT"
else
	bad "variant build (custom layout)" "$(tail -5 "$T/var-lay/build.log")"
fi
rm -rf "$T"/var-*
rm -rf "$T/extrepo"; mkdir -p "$T/extrepo"
# the architecture is part of the name, and an underscore inside it (x86_64) does not confuse the parser
mkdir -p "$T/recipes/ext2"
printf 'name=ext-two\nversion=2.5\nrelease=1\narch=x86_64\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext2/Tatamifile"
check "build a package for x86_64 (hyphenated name, underscore in the arch)" 0 mk -f "$T/recipes/ext2/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext-two_2.5-1_x86_64.$EXPECT" ] && ok "named ext-two_2.5-1_x86_64.$EXPECT" || bad "x86_64 package name" "$(ls "$T/extrepo")"
check "tatami parses it back without a naming warning" 0 "$TATAMI" -r "$T/extroot" -c "$T/noext.conf" update
hasnt "no warning for a name whose arch contains an underscore" "named differently"
printf 'name=ext3\nversion=1\narch=NoArch\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext2/Tatamifile"
check "arch in any case: NoArch is written noarch" 0 mk -f "$T/recipes/ext2/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext3_1_noarch.$EXPECT" ] && ok "named ext3_1_noarch.$EXPECT" || bad "noarch name" "$(ls "$T/extrepo")"
rm -rf "$T/extrepo"

echo "# compression formats: all read and written natively, no external program"
for comp in gz zst xz bz2 lz4 lzma; do
	mkdir -p "$T/comp-$comp/recipe" "$T/comp-$comp/repo" "$T/comp-$comp/root/etc"
	printf 'name=cmp-%s\nversion=1\narch='$HARCH'\nbuild() { mkdir -p $PKG/usr/share/cmp; echo "compressed with %s" > $PKG/usr/share/cmp/%s; }\n' "$comp" "$comp" "$comp" > "$T/comp-$comp/recipe/Tatamifile"
	printf '' > "$T/comp-$comp/conf"
	set_repos "$T/comp-$comp/root" "$T/comp-$comp/repo"
	check "tatami-mkpkg builds a $comp package" 0 mk -z "$comp" -f "$T/comp-$comp/recipe/Tatamifile" -o "$T/comp-$comp/repo"
	pkgf="$T/comp-$comp/repo/cmp-${comp}_1_$HARCH.$EXT"
	case "$comp" in gz) magic='1f8b' ;; zst) magic='28b52ffd' ;; xz) magic='fd377a585a00' ;; bz2) magic='425a68' ;; lz4) magic='04224d18' ;; lzma) magic='5d0000' ;; esac
	[ "$(head -c 6 "$pkgf" | od -An -tx1 | tr -d ' \n' | cut -c1-${#magic})" = "$magic" ] && ok "the $comp package really is $comp-compressed" || bad "$comp package has the wrong compression" "$(head -c 6 "$pkgf" | od -An -tx1)"
	check "tatami lists the files of a $comp package (PATH is empty: no external program)" 0 env PATH=/nonexistent "$TATAMI" -r "$T/comp-$comp/root" -c "$T/comp-$comp/conf" files "$pkgf"
	has "$comp: file list" "usr/share/cmp/$comp"
	check "tatami installs a $comp package (PATH is empty)" 0 env PATH=/nonexistent "$TATAMI" -r "$T/comp-$comp/root" -c "$T/comp-$comp/conf" -y install "$pkgf"
	grep -qx "compressed with $comp" "$T/comp-$comp/root/usr/share/cmp/$comp" 2>/dev/null && ok "$comp: file content extracted intact" || bad "$comp: content wrong or missing"
	check "tatami indexes a $comp package" 0 "$TATAMI" -r "$T/comp-$comp/root" -c "$T/comp-$comp/conf" update
done

echo "# install reasons and cascading removal (no autoremove command: remove always cleans up)"
ROOT_MAIN="$ROOT"; ROOT="$T/root-reasons"; mkdir -p "$ROOT/etc"
mkpkg cz-base 1.0 file=usr/lib/cz-base
mkpkg cz-lib 1.0 depends=cz-base file=usr/lib/cz-lib
mkpkg cz-shared 1.0 file=usr/lib/cz-shared
mkpkg cz-app1 1.0 "depends=cz-lib, cz-shared" file=usr/bin/cz-app1
mkpkg cz-app2 1.0 depends=cz-shared file=usr/bin/cz-app2
mkpkg cz-solo 1.0 file=usr/bin/cz-solo
check "install two applications that share a dependency" 0 ty install cz-app1 cz-app2
exists "app1 installed" usr/bin/cz-app1
exists "dependency installed" usr/lib/cz-lib
exists "transitive dependency installed" usr/lib/cz-base
exists "shared dependency installed" usr/lib/cz-shared
check "show a requested package" 0 t show cz-app1
has "recorded as manually installed" "^Installed: manually"
check "show a dependency" 0 t show cz-lib
has "recorded as a dependency" "^Installed: automatically, as a dependency"
check "show a transitive dependency" 0 t show cz-base
has "also a dependency" "^Installed: automatically"
check "simulated remove shows the orphans" 0 t -s remove cz-app1
has "orphan listed" "cz-lib \\(1.0-1\\) \\[no longer needed\\]"
has "transitive orphan listed" "cz-base \\(1.0-1\\) \\[no longer needed\\]"
hasnt "still-needed dependency not listed" "cz-shared"
exists "simulation removed nothing" usr/lib/cz-lib
check "remove app1: its orphaned dependencies go with it" 0 ty remove cz-app1
has "app1 removed" "Removing cz-app1"
has "orphan removed" "Removing cz-lib"
has "transitive orphan removed" "Removing cz-base"
hasnt "a dependency still needed by app2 is kept" "Removing cz-shared"
absent "app1 files gone" usr/bin/cz-app1
absent "orphan files gone" usr/lib/cz-lib
absent "transitive orphan files gone" usr/lib/cz-base
exists "shared dependency kept" usr/lib/cz-shared
exists "app2 untouched" usr/bin/cz-app2
check "remove the last user of the shared dependency" 0 ty remove cz-app2
has "shared dependency removed with it" "Removing cz-shared"
absent "shared dependency files gone" usr/lib/cz-shared
check "nothing is left installed" 0 t list
hasnt "no cz- package remains" "^cz-"

# an explicit install protects a package
check "install app1 again" 0 ty install cz-app1
check "asking for an installed dependency explicitly" 0 ty install cz-lib
has "it is now manual" "cz-lib is now marked as manually installed"
check "show: now manual" 0 t show cz-lib
has "recorded as manual" "^Installed: manually"
check "remove app1: the explicit package and what it needs stay" 0 ty remove cz-app1
exists "explicitly installed package kept" usr/lib/cz-lib
exists "its own dependency kept" usr/lib/cz-base
absent "app1 gone" usr/bin/cz-app1
absent "the other orphan is removed" usr/lib/cz-shared

# explicit packages are never swept, even when nothing needs them
check "install a standalone package and an app" 0 ty install cz-solo cz-app2
check "remove the app" 0 ty remove cz-app2
exists "standalone explicit package kept" usr/bin/cz-solo
absent "app's dependency removed" usr/lib/cz-shared

# packages of unknown origin (installed before reasons were tracked) count as explicit
check "install app2 again" 0 ty install cz-app2
sed -i '/^reason:/d' "$ROOT/var/lib/tatami/meta/cz-shared"
check "remove app2" 0 ty remove cz-app2
exists "a package without a recorded reason is kept" usr/lib/cz-shared
check "its status reads as manual" 0 t show cz-shared
has "unknown reason means manual" "^Installed: manually"
check "removing a dependency removes its dependents too" 0 ty remove cz-lib
absent "dependency removed" usr/lib/cz-lib
absent "and its orphan" usr/lib/cz-base
ROOT="$ROOT_MAIN"

echo "# atomic installation: a failure halfway rolls everything back"
ROOT="$T/root-atomic"; mkdir -p "$ROOT/etc" "$ROOT/usr/share"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
def add(tf, name, data=None, typ=tarfile.REGTYPE, mode=0o644, link=""):
    i = tarfile.TarInfo(name); i.type = typ; i.mode = mode; i.linkname = link
    if typ == tarfile.REGTYPE:
        i.size = len(data); tf.addfile(i, io.BytesIO(data))
    else:
        tf.addfile(i)
def pkg(path, name, version, files, broken):
    with tarfile.open(path, "w:gz") as tf:
        add(tf, ".META", ("name: %s\nversion: %s\n" % (name, version)).encode())
        for n, kind, mode, data in files:
            if kind == "d": add(tf, n, typ=tarfile.DIRTYPE, mode=mode)
            else: add(tf, n, data, mode=mode)
        # a hard link to a file that is not in the archive: only fails when it is extracted,
        # after everything before it was already written
        if broken: add(tf, "usr/share/%s/zlast" % name, typ=tarfile.LNKTYPE, link="no/such/target")
fresh = [("usr/share/rbfresh/", "d", 0o755, None), ("usr/share/rbfresh/a", "f", 0o644, b"a\n"),
         ("usr/share/rbfresh/sub/", "d", 0o755, None), ("usr/share/rbfresh/sub/b", "f", 0o644, b"b\n")]
pkg(t + "/rbfresh_1." + ext, "rbfresh", "1", fresh, True)
v1 = [("usr/share/rbup/", "d", 0o755, None), ("usr/share/rbup/data", "f", 0o640, b"version one\n"),
      ("usr/share/rbup/oldonly", "f", 0o644, b"old\n")]
v2 = [("usr/share/rbup/", "d", 0o700, None), ("usr/share/rbup/data", "f", 0o600, b"version TWO\n"),
      ("usr/share/rbup/newfile", "f", 0o644, b"new\n")]
pkg(t + "/rbup_1." + ext, "rbup", "1", v1, False)
pkg(t + "/rbup_2." + ext, "rbup", "2", v2, True)
pkg(t + "/rbup_3." + ext, "rbup", "3", v2, False)
PY
has_data() { [ "$(cat "$ROOT/usr/share/rbup/data" 2>/dev/null)" = "$1" ]; }
# everything observable about the tree except timestamps: paths, types, modes, owners, link targets, contents
snap() { (cd "$ROOT" && find . -printf '%p %y %m %u:%g %l\n' | sort; find . -type f -exec md5sum {} + 2>/dev/null | sort); }

# the first run on a new root creates tatami's own state directory (database, index);
# do that first so the comparison below is about the extraction only
check "install version 1 of a package" 0 ty install "$T/rbup_1.$EXT"
has_data "version one" && ok "version 1 is in place" || bad "version 1 content"

before=$(snap)
check "a fresh installation that fails halfway is refused" 1 ty install "$T/rbfresh_1.$EXT"
has "the failing member is named" "could not install usr/share/rbfresh/zlast"
has "the user is told nothing changed" "nothing was changed"
after=$(snap)
[ "$before" = "$after" ] && ok "the filesystem is exactly as before (every path, mode, owner and content)" || bad "the filesystem changed" "$(diff <(echo "$before") <(echo "$after") | head -8)"
absent "extracted file removed" usr/share/rbfresh/a
absent "created subdirectory removed" usr/share/rbfresh/sub
absent "created directory removed" usr/share/rbfresh
absent "no journal left" var/lib/tatami/transaction.journal
check "the database does not know the package" 1 t files rbfresh

before=$(snap)
check "an upgrade that fails halfway is refused" 1 ty install "$T/rbup_2.$EXT"
has "nothing was changed" "nothing was changed"
after=$(snap)
[ "$before" = "$after" ] && ok "the upgrade left the filesystem exactly as before" || bad "the failed upgrade changed the filesystem" "$(diff <(echo "$before") <(echo "$after") | head -8)"
has_data "version one" && ok "the overwritten file has its old content again" || bad "old content not restored"
[ "$(stat -c %a "$ROOT/usr/share/rbup/data")" = 640 ] && ok "and its old mode (640)" || bad "mode of the overwritten file"
[ "$(stat -c %a "$ROOT/usr/share/rbup")" = 755 ] && ok "the existing directory has its old mode (755) again" || bad "directory mode not restored"
exists "the file only the old version has is still there" usr/share/rbup/oldonly
absent "the new version's file was removed" usr/share/rbup/newfile
check "the database still has version 1" 0 t list
has "version 1 is registered" "^rbup/1 \\[installed\\]"
[ "$(find "$ROOT" -name '.tatami-bak*' | wc -l)" = 0 ] && ok "no backup files are left behind" || bad "backup files left" "$(find "$ROOT" -name '.tatami-bak*')"
absent "no journal left after the rollback" var/lib/tatami/transaction.journal

check "the same upgrade without the broken member succeeds" 0 ty install "$T/rbup_3.$EXT"
has_data "version TWO" && ok "new content installed" || bad "new content missing"
exists "new file installed" usr/share/rbup/newfile
absent "file the new version no longer has is deleted afterwards" usr/share/rbup/oldonly
[ "$(find "$ROOT" -name '.tatami-bak*' | wc -l)" = 0 ] && ok "backups are cleaned up after a successful upgrade" || bad "backups left after success"
absent "no journal left after success" var/lib/tatami/transaction.journal
check "the database has version 3" 0 t list
has "version 3 is registered" "^rbup/3 \\[installed\\]"

echo "# a symbolic link to a directory (/lib -> usr/lib) stays a link"
mkdir -p "$ROOT/usr/lib"; ln -s usr/lib "$ROOT/lib"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
def add(tf, name, data=None, typ=tarfile.REGTYPE, mode=0o644, link=""):
    i = tarfile.TarInfo(name); i.type = typ; i.mode = mode; i.linkname = link
    if typ == tarfile.REGTYPE:
        i.size = len(data); tf.addfile(i, io.BytesIO(data))
    else:
        tf.addfile(i)
for name, broken in (("lnkok", False), ("lnkbad", True)):
    with tarfile.open("%s/%s_1.%s" % (t, name, ext), "w:gz") as tf:
        add(tf, ".META", ("name: %s\nversion: 1\n" % name).encode())
        add(tf, "lib/", typ=tarfile.DIRTYPE, mode=0o755)
        add(tf, "lib/%s.so" % name, b"lib\n")
        if broken: add(tf, "usr/lib/zlast", typ=tarfile.LNKTYPE, link="no/such/target")
PY
before=$(snap)
check "a failing install that writes through the link is refused" 1 ty install "$T/lnkbad_1.$EXT"
after=$(snap)
[ "$before" = "$after" ] && ok "rolled back with the link and its directory untouched" || bad "link or directory changed" "$(diff <(echo "$before") <(echo "$after") | head -6)"
[ -L "$ROOT/lib" ] && ok "/lib is still a symbolic link after the rollback" || bad "/lib is no longer a link"
check "a package shipping lib/ installs through the link" 0 ty install "$T/lnkok_1.$EXT"
[ -L "$ROOT/lib" ] && ok "/lib is still a symbolic link after the install" || bad "install replaced the link by a directory"
[ "$(readlink "$ROOT/lib")" = "usr/lib" ] && ok "pointing where it did" || bad "link target changed" "$(readlink "$ROOT/lib")"
exists "the file went through the link into usr/lib" usr/lib/lnkok.so

echo "# an installation interrupted by a crash is recovered the next time tatami runs"
D="$ROOT/usr/share/crash"; mkdir -p "$D"
echo partial > "$D/old"; echo orig > "$D/.tatami-bak.1.0"; echo junk > "$D/new"
printf 'P\tcrash\t1\nC\t%s\nB\t%s\t%s\n' "$D/new" "$D/old" "$D/.tatami-bak.1.0" > "$ROOT/var/lib/tatami/transaction.journal"
OUT=$(ty remove nothing-here 2>&1)
has "an unfinished installation is rolled back" "rolled back an interrupted installation of crash 1"
[ "$(cat "$D/old")" = orig ] && ok "the overwritten file is restored" || bad "file not restored" "$(cat "$D/old")"
[ ! -e "$D/new" ] && [ ! -e "$D/.tatami-bak.1.0" ] && ok "the new file and the backup are gone" || bad "recovery left files" "$(ls -a "$D")"
absent "journal removed after recovery" var/lib/tatami/transaction.journal
rm -rf "$D"
# the database already lists rbup 3: the interrupted run had committed, recovery finishes the job
echo stale > "$ROOT/usr/share/rbup/stale"; echo bak > "$ROOT/usr/share/rbup/.tatami-bak.2.0"
printf 'P\trbup\t3\nD\t%s\nB\t%s\t%s\n' "$ROOT/usr/share/rbup/stale" "$ROOT/usr/share/rbup/data" "$ROOT/usr/share/rbup/.tatami-bak.2.0" > "$ROOT/var/lib/tatami/transaction.journal"
OUT=$(ty remove nothing-here 2>&1)
has "a committed installation is finished" "finished an interrupted installation of rbup 3"
absent "deferred deletion carried out" usr/share/rbup/stale
absent "backup dropped" usr/share/rbup/.tatami-bak.2.0
has_data "version TWO" && ok "the committed content is kept" || bad "committed content lost"
absent "journal removed" var/lib/tatami/transaction.journal
ROOT="$ROOT_MAIN"

echo "# configuration files: .old backups in the transaction journal"
ROOT="$T/root-cfg"; rm -rf "$ROOT"; mkdir -p "$ROOT/etc"; set_rules "$ROOT"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
def add(tf, name, data=None, typ=tarfile.REGTYPE, mode=0o644, link=""):
    i = tarfile.TarInfo(name); i.type = typ; i.mode = mode; i.linkname = link
    if typ == tarfile.REGTYPE:
        i.size = len(data); tf.addfile(i, io.BytesIO(data))
    else:
        tf.addfile(i)
def pkg(version, conf, broken=False):
    with tarfile.open("%s/cfg_%s%s.%s" % (t, version, "bad" if broken else "", ext), "w:gz") as tf:
        add(tf, ".META", ("name: cfg\nversion: %s\n" % version).encode())
        add(tf, "etc/", typ=tarfile.DIRTYPE, mode=0o755)
        add(tf, "etc/cfg.conf", conf.encode())
        add(tf, "etc/cfg-same.conf", b"always the same\n")
        add(tf, "usr/", typ=tarfile.DIRTYPE, mode=0o755)
        add(tf, "usr/share/cfg-data", ("data " + version + "\n").encode())
        if broken:
            add(tf, "usr/share/zzz-broken", typ=tarfile.LNKTYPE, link="no/such/target")
pkg("1", "conf v1\n"); pkg("2", "conf v2\n"); pkg("2", "conf v2\n", broken=True)
pkg("3", "conf v3\n"); pkg("3", "conf v3\n", broken=True)
PY
check "install cfg 1" 0 ty install "$T/cfg_1.$EXT"
[ ! -e "$ROOT/etc/cfg.conf.old" ] && ok "a fresh install makes no .old file" || bad ".old on first install"
echo "admin edit" > "$ROOT/etc/cfg.conf"
before=$(snap)
check "an upgrade that fails halfway is refused" 1 ty install "$T/cfg_2bad.$EXT"
[ "$before" = "$(snap)" ] && ok "rollback: the edited cfg.conf is back, the new one and any .old are gone, nothing else changed" || bad "rollback differs" "$(diff <(echo "$before") <(echo "$(snap)") | head -8)"
[ "$(cat "$ROOT/etc/cfg.conf")" = "admin edit" ] && [ ! -e "$ROOT/etc/cfg.conf.old" ] && ok "cfg.conf is the admin's file again, no .old" || bad "config not restored"
check "the upgrade that works" 0 ty install "$T/cfg_2.$EXT"
[ "$(cat "$ROOT/etc/cfg.conf")" = "conf v2" ] && [ "$(cat "$ROOT/etc/cfg.conf.old")" = "admin edit" ] && ok "new file installed, the admin's file is cfg.conf.old" || bad "result of the upgrade"
[ ! -e "$ROOT/etc/cfg-same.conf.old" ] && ok "a config file that did not change gets no .old" || bad "needless .old"
# a second upgrade replaces the .old file; a failing one must bring both files back
before=$(snap)
check "failing upgrade over an existing .old" 1 ty install "$T/cfg_3bad.$EXT"
[ "$before" = "$(snap)" ] && [ "$(cat "$ROOT/etc/cfg.conf")" = "conf v2" ] && [ "$(cat "$ROOT/etc/cfg.conf.old")" = "admin edit" ] && ok "rollback restored cfg.conf and the previous .old" || bad "rollback with an existing .old" "$(diff <(echo "$before") <(echo "$(snap)") | head -8)"
# killed after extracting: the next run undoes it
{ TATAMI_CRASH_AT=extracted "$TATAMI" -r "$ROOT" -c "$CONF" -y install "$T/cfg_3.$EXT" >/dev/null 2>&1; rc=$?; } 2>/dev/null
[ $rc -eq 137 ] && [ "$(cat "$ROOT/etc/cfg.conf")" = "conf v3" ] && [ "$(cat "$ROOT/etc/cfg.conf.old")" = "conf v2" ] && ok "killed with SIGKILL in the middle: cfg.conf is v3, the .old is v2" || bad "state at the kill (exit $rc)"
OUT=$(ty remove nothing-here 2>&1)
has "the next run rolls it back" "rolled back an interrupted transaction"
[ "$before" = "$(snap)" ] && ok "cfg.conf (v2) and the previous .old (admin edit) are back, byte for byte" || bad "recovery differs" "$(diff <(echo "$before") <(echo "$(snap)") | head -8)"
# killed after the database commit: the next run finishes, the .old stays
{ TATAMI_CRASH_AT=committed "$TATAMI" -r "$ROOT" -c "$CONF" -y install "$T/cfg_3.$EXT" >/dev/null 2>&1; rc=$?; } 2>/dev/null
OUT=$(ty remove nothing-here 2>&1)
has "the next run finishes it" "finished an interrupted transaction"
[ "$(cat "$ROOT/etc/cfg.conf")" = "conf v3" ] && [ "$(cat "$ROOT/etc/cfg.conf.old")" = "conf v2" ] && ok "committed: v3 installed, v2 kept as cfg.conf.old" || bad "finished state"
[ -z "$(find "$ROOT" -name '.tatami-bak*' -o -name '*.tatami-new*')" ] && ok "no backups or temporary files left" || bad "leftovers"
[ ! -e "$ROOT/var/lib/tatami/rejected" ] && ok "still no rejected directory" || bad "rejected directory exists"
ROOT="$ROOT_MAIN"

echo "# one transaction per run: all or nothing, across packages"
ROOT="$T/root-gtx"; rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
def add(tf, name, data=None, typ=tarfile.REGTYPE, mode=0o644, link=""):
    i = tarfile.TarInfo(name); i.type = typ; i.mode = mode; i.linkname = link
    if typ == tarfile.REGTYPE:
        i.size = len(data); tf.addfile(i, io.BytesIO(data))
    else:
        tf.addfile(i)
def pkg(name, version, files, replaces=None, broken=False):
    with tarfile.open("%s/g%s_%s.%s" % (t, name, version, ext), "w:gz") as tf:
        meta = "name: %s\nversion: %s\n" % (name, version)
        if replaces: meta += "replaces: %s\n" % replaces
        add(tf, ".META", meta.encode())
        add(tf, "usr/", typ=tarfile.DIRTYPE, mode=0o755)
        add(tf, "usr/share/", typ=tarfile.DIRTYPE, mode=0o755)
        for f, c in sorted(files.items()):
            add(tf, f, c.encode())
        if broken:
            add(tf, "usr/share/zzz-broken", typ=tarfile.LNKTYPE, link="no/such/target")
pkg("g1", "1", {"usr/share/g1": "g1\n"})
pkg("g2", "1", {"usr/share/g2": "g2\n"})
pkg("g3", "1", {"usr/share/g3": "g3\n"}, broken=True)
pkg("up", "1", {"usr/share/up": "up v1\n", "usr/share/up-old": "gone in v2\n"})
pkg("up", "2", {"usr/share/up": "up v2\n", "usr/share/up-new": "new in v2\n"})
pkg("old", "1", {"usr/share/shared": "old\n", "usr/share/old-only": "old only\n"})
pkg("new", "1", {"usr/share/shared": "new\n", "usr/share/new-only": "new only\n"}, replaces="old")
pkg("newbad", "1", {"usr/share/shared": "new\n", "usr/share/new-only": "new only\n"}, replaces="old", broken=True)
PY
G() { ty install "$@"; }
check "set up: up 1 and old 1" 0 ty install "$T/gup_1.$EXT" "$T/gold_1.$EXT"
before=$(snap)
check "a run whose third package fails is refused" 1 G "$T/gg1_1.$EXT" "$T/gup_2.$EXT" "$T/gg3_1.$EXT"
has "it says what it does" "rolling back the whole transaction"
has "and that nothing was changed" "the transaction failed, nothing was changed"
after=$(snap)
[ "$before" = "$after" ] && ok "the filesystem is exactly as before: the two good packages were undone too" || bad "partial state left" "$(diff <(echo "$before") <(echo "$after") | head -8)"
check "g1 was not installed" 1 t files g1
has_up=$(t list 2>&1); echo "$has_up" | grep -q "^up/1 \[installed\]" && ok "up is still version 1 in the database" || bad "database changed" "$has_up"
[ "$(cat "$ROOT/usr/share/up")" = "up v1" ] && [ -f "$ROOT/usr/share/up-old" ] && ok "up's files are version 1 again, nothing was deleted" || bad "upgrade not undone"
[ "$(find "$ROOT" -name '.tatami-bak*' | wc -l)" = 0 ] && [ ! -e "$ROOT/var/lib/tatami/transaction.journal" ] && ok "no backups and no journal are left" || bad "leftovers"
# removal in the same run: old is replaced by new, which takes over a file
before=$(snap)
check "the replacing package fails: old must survive untouched" 1 G "$T/gnewbad_1.$EXT"
after=$(snap)
[ "$before" = "$after" ] && ok "old's files are all still there" || bad "removal was not undone" "$(diff <(echo "$before") <(echo "$after") | head -8)"
t list 2>&1 | grep -q "^old/1 \[installed\]" && ok "old is still in the database" || bad "old lost from the database"
check "the run that works: new replaces old, g1 and up 2 come along" 0 G "$T/gnew_1.$EXT" "$T/gg1_1.$EXT" "$T/gup_2.$EXT"
[ "$(cat "$ROOT/usr/share/shared")" = new ] && ok "the file both packages list now belongs to new, with the new content" || bad "shared file" "$(cat "$ROOT/usr/share/shared")"
[ ! -e "$ROOT/usr/share/old-only" ] && [ -f "$ROOT/usr/share/new-only" ] && ok "old's other files are gone only after the commit" || bad "old-only handling"
[ ! -e "$ROOT/usr/share/up-old" ] && [ "$(cat "$ROOT/usr/share/up")" = "up v2" ] && ok "up 2 replaced up 1, its dropped file is deleted" || bad "upgrade result"
t list 2>&1 | grep -q "^old/" && bad "old still listed" || ok "old is no longer in the database"
[ "$(find "$ROOT" -name '.tatami-bak*' | wc -l)" = 0 ] && [ ! -e "$ROOT/var/lib/tatami/transaction.journal" ] && ok "backups and journal are cleaned up" || bad "leftovers after success"

echo "# a run killed with SIGKILL is undone, or finished, by the next run"
ROOT="$T/root-kill"; rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
check "set up: up 1 and old 1" 0 ty install "$T/gup_1.$EXT" "$T/gold_1.$EXT"
before=$(snap)
{ TATAMI_CRASH_AT=extracted "$TATAMI" -r "$ROOT" -c "$CONF" -y install "$T/gnew_1.$EXT" "$T/gg1_1.$EXT" "$T/gup_2.$EXT" >/dev/null 2>&1; rc=$?; } 2>/dev/null
[ $rc -eq 137 ] && ok "tatami was killed (SIGKILL) after extracting everything, before the commit" || bad "not killed (exit $rc)"
[ -e "$ROOT/var/lib/tatami/transaction.journal" ] && [ -f "$ROOT/usr/share/g1" ] && [ -f "$ROOT/usr/share/up-new" ] && ok "the half-done run is on disk: journal, new files" || bad "no half-done state"
OUT=$(ty remove nothing-here 2>&1)
has "the next run rolls back the whole transaction" "rolled back an interrupted transaction \(3 install/upgrade, 1 removal\)"
after=$(snap)
[ "$before" = "$after" ] && ok "every package of the killed run is undone, the system is as before" || bad "state differs after recovery" "$(diff <(echo "$before") <(echo "$after") | head -8)"
LST=$(t list 2>&1); echo "$LST" | grep -q "^up/1 \[installed\]" && echo "$LST" | grep -q "^old/1 \[installed\]" && ok "database untouched" || bad "database changed" "$LST"
{ TATAMI_CRASH_AT=committed "$TATAMI" -r "$ROOT" -c "$CONF" -y install "$T/gnew_1.$EXT" "$T/gg1_1.$EXT" "$T/gup_2.$EXT" >/dev/null 2>&1; rc=$?; } 2>/dev/null
[ $rc -eq 137 ] && ok "tatami was killed after the database commit, before the old files were deleted" || bad "not killed (exit $rc)"
[ -e "$ROOT/usr/share/old-only" ] && [ -e "$ROOT/usr/share/up-old" ] && ok "the old files are still there at that moment" || bad "deleted too early"
OUT=$(ty remove nothing-here 2>&1)
has "the next run finishes it" "finished an interrupted transaction \(3 install/upgrade, 1 removal\)"
[ ! -e "$ROOT/usr/share/old-only" ] && [ ! -e "$ROOT/usr/share/up-old" ] && [ "$(cat "$ROOT/usr/share/shared")" = new ] && ok "deferred deletions done, the shared file is new's" || bad "not finished"
[ "$(find "$ROOT" -name '.tatami-bak*' | wc -l)" = 0 ] && [ ! -e "$ROOT/var/lib/tatami/transaction.journal" ] && ok "backups and journal removed" || bad "leftovers after recovery"
LST=$(t list 2>&1); echo "$LST" | grep -q "^new/1 \[installed\]" && echo "$LST" | grep -q "^up/2 \[installed\]" && ok "the committed database is intact" || bad "database wrong" "$LST"
ROOT="$ROOT_MAIN"

# ---------------------------------------------------------------------------
# helpers for the sections below: build a package with its own tiny recipe
#   mkp <repo-dir> <name> <version> <arch|-> <depends|-> [path:content]...
TCONF="$T/mk.conf"; printf '' > "$TCONF"
mkp() {
	local repo="$1" name="$2" version="$3" arch="$4" deps="$5"; shift 5
	local dir="$T/recipes-x/$name-$version-$RANDOM" body="" f
	mkdir -p "$dir" "$repo"
	for f in "$@"; do
		body="$body"$'\n\t'"mkdir -p \$PKG/$(dirname "${f%%:*}"); printf '%s\\n' '${f#*:}' > \$PKG/${f%%:*}"
	done
	{
		echo "name=$name"; echo "version=$version"
		[ "$arch" != - ] && echo "arch=$arch" || echo "arch=$HARCH"
		[ "$deps" != - ] && echo "depends=($deps)"
		echo "build() {$body"; echo "}"
	} > "$dir/Tatamifile"
	fixture_build "$dir/Tatamifile" "$repo" > "$dir/log" 2>&1 || bad "fixture package $name $version" "$(cat "$dir/log")"
}

echo "# disk space: checked before anything is extracted"
ROOT="$T/root-space"; rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
for name in ("big1", "big2"):
    with tarfile.open("%s/%s_1.%s" % (t, name, ext), "w:gz") as tf:
        def add(n, data):
            i = tarfile.TarInfo(n); i.size = len(data); i.mode = 0o644; tf.addfile(i, io.BytesIO(data))
        add(".META", ("name: %s\nversion: 1\n" % name).encode())
        add("usr/share/%s/blob" % name, b"\0" * (5 << 20))      # 5 MiB once extracted, tiny compressed
PY
cat > "$T/fakefree.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/statvfs.h>
/* reports FAKE_FREE_BYTES as the free space of every filesystem */
static void fake(struct statvfs *b) {
	const char *e = getenv("FAKE_FREE_BYTES");
	if (e && b->f_frsize) { b->f_bavail = strtoull(e, 0, 10) / b->f_frsize; b->f_bfree = b->f_bavail; }
}
int statvfs(const char *p, struct statvfs *b) {
	int (*real)(const char *, struct statvfs *) = dlsym(RTLD_NEXT, "statvfs");
	int r = real(p, b); if (r == 0) fake(b); return r;
}
int statvfs64(const char *p, struct statvfs64 *b) {
	int (*real)(const char *, struct statvfs64 *) = dlsym(RTLD_NEXT, "statvfs64");
	int r = real(p, b);
	const char *e = getenv("FAKE_FREE_BYTES");
	if (r == 0 && e && b->f_frsize) { b->f_bavail = strtoull(e, 0, 10) / b->f_frsize; b->f_bfree = b->f_bavail; }
	return r;
}
C
if cc -shared -fPIC -o "$T/fakefree.so" "$T/fakefree.c" -ldl 2>/dev/null && ldd "$TATAMI" >/dev/null 2>&1; then
	FF() { env LD_PRELOAD="$T/fakefree.so" FAKE_FREE_BYTES="$1" "$TATAMI" -r "$ROOT" -c "$CONF" -y install "${@:2}"; }
	check "set up the root" 0 ty install "$T/gg1_1.$EXT"
	before=$(snap)
	check "one 5 MiB package with 10 MiB free is refused" 1 FF $((10<<20)) "$T/big1_1.$EXT"
	has "with the numbers" "not enough disk space on .*: [0-9]+ MiB needed .* 10 MiB available"
	has "and a promise" "Nothing has been changed"
	[ "$before" = "$(snap)" ] && ok "the filesystem is untouched, no journal, no half-extracted files" || bad "the refused install changed something"
	check "the same package with 16 MiB free fits (5 MiB + margin)" 0 FF $((16<<20)) "$T/big1_1.$EXT"
	check "remove it" 0 ty remove big1
	check "two such packages need the sum: 16 MiB are not enough" 1 FF $((16<<20)) "$T/big1_1.$EXT" "$T/big2_1.$EXT"
	[ ! -e "$ROOT/usr/share/big1/blob" ] && ok "so not even the first one was extracted" || bad "first package extracted"
	check "with 32 MiB both are installed" 0 FF $((32<<20)) "$T/big1_1.$EXT" "$T/big2_1.$EXT"
	check "without the shim the real free space is used and is enough" 0 ty remove big1 big2
else
	echo "skip - no C compiler or a static tatami: the disk space tests need an LD_PRELOAD shim"
fi
ROOT="$ROOT_MAIN"

echo "# repositories: the binary repo.solv index"
RP="$T/repos"; rm -rf "$RP"; mkdir -p "$RP/a" "$RP/b" "$RP/root/etc"
mkp "$RP/a" rp-one 1.0 - '"rp-two >= 1.0"' usr/share/rp-one/f:one
mkp "$RP/a" rp-two 1.0 - - usr/share/rp-two/f:two
printf '' > "$RP/base.conf"
# a scenario is the repos.conf of the root: <name>.repos (no such file: no repos.conf at all)
echo "ra = $RP/a" > "$RP/a.repos"
ROOT_MAIN="$ROOT"; ROOT="$RP/root"
tr() { mkdir -p "$ROOT/etc/tatami"; if [ -f "$RP/$1.repos" ]; then cp "$RP/$1.repos" "$ROOT/etc/tatami/repos.conf"; else rm -f "$ROOT/etc/tatami/repos.conf"; fi
	"$TATAMI" -r "$ROOT" -c "$RP/base.conf" "${@:2}"; }
check "tatami update writes repo.solv into a local repository" 0 tr a update
has "it reports the packages" "Indexed 2 packages in .*/a/repo.solv"
[ "$(head -c 4 "$RP/a/repo.solv")" = SOLV ] && ok "repo.solv is a libsolv binary repository" || bad "repo.solv is not a SOLV file" "$(head -c 8 "$RP/a/repo.solv" | od -c | head -1)"
check "there is no tatami index command any more" 1 "$TATAMI" index "$RP/a"
has "it is an unknown command" "unknown command 'index'"
OUT=$("$TATAMI" --help 2>&1); echo "$OUT" | grep -qE "^ *index" && bad "the help still lists index" "$OUT" || ok "and the help does not list it"
echo "rn = $RP/nowhere" > "$RP/nowhere.repos"
OUT=$(tr nowhere update 2>&1); echo "$OUT" | grep -q "nowhere" && ok "update of a local directory that does not exist reports it" || bad "missing local repository" "$OUT"
# the index is used as it is when it is not older than the packages: with a garbage package file the
# scanner would skip it, only the index still knows it
cp "$RP/a/repo.solv" "$RP/repo.solv.saved"
rm -f "$RP"/a/rp-two_1.0*; echo garbage > "$RP/a/rp-two_1.0_garbage.tar.pkg"; touch -d '2000-01-01' "$RP/a"
check "a fresh repo.solv is trusted (dependencies come from the index)" 0 tr a show rp-one
has "the dependency is known from the index" "^Depends: rp-two >= 1.0"
has "so are file name and size" "^Filename: .*/a/rp-one_1.0_"
check "the index knows the dependency package too" 0 tr a show rp-two
check "installing fails cleanly when the indexed file is not what it claims" 1 tr a -y install rp-one
hasnt "and nothing was half-installed" "Installing"
rm -f "$RP/a/rp-two_1.0_garbage.tar.pkg"
mkp "$RP/a" rp-two 1.0 - - usr/share/rp-two/f:two
check "re-indexing after the repair" 0 tr a update
# stale index: a package added after the index was written is still found, with a hint
mkp "$RP/a" rp-three 1.0 - - usr/share/rp-three/f:three
OUT=$(tr a show rp-three 2>&1); echo "$OUT" | grep -q "^Package: rp-three" && ok "a package added after indexing is found (the directory is scanned)" || bad "stale index" "$OUT"
echo "$OUT" | grep -q "older than the packages" && ok "with a warning to re-index" || bad "no stale warning" "$OUT"
check "update re-indexes the configured repository" 0 tr a update
has "update reports it" "Indexed 3 packages in .*/a/repo.solv"
OUT=$(tr a show rp-three 2>&1); echo "$OUT" | grep -q "older than" && bad "still stale after update" "$OUT" || ok "no warning once the index is current"
check "install through the index, with its dependency" 0 tr a -y install rp-one
exists "package installed" usr/share/rp-one/f
exists "its dependency from the same repository" usr/share/rp-two/f

echo "# repositories: several, file:// URLs, the default location"
rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
mkp "$RP/a" rp-dup 1.0 - - usr/share/rp-dup/f:from-a
mkp "$RP/b" rp-dup 1.0 - - usr/share/rp-dup/f:from-b
printf 'ra = %s\nrb = %s\n' "$RP/a" "$RP/b" > "$RP/ab.repos"
printf 'rb = %s\nra = %s\n' "$RP/b" "$RP/a" > "$RP/ba.repos"
check "update indexes every configured repository" 0 tr ab update
has "first repository" "Indexed [0-9]+ packages? in .*/a/repo.solv"
has "second repository" "Indexed [0-9]+ packages? in .*/b/repo.solv"
check "the same version in two repositories: the first one listed is used" 0 tr ab -y install rp-dup
[ "$(cat "$ROOT/usr/share/rp-dup/f")" = from-a ] && ok "installed from the first repository (a)" || bad "wrong repository used" "$(cat "$ROOT/usr/share/rp-dup/f")"
check "remove it" 0 tr ab -y remove rp-dup
check "with the order reversed" 0 tr ba -y install rp-dup
[ "$(cat "$ROOT/usr/share/rp-dup/f")" = from-b ] && ok "installed from the first repository (b)" || bad "wrong repository used" "$(cat "$ROOT/usr/share/rp-dup/f")"
tr ba -y remove rp-dup >/dev/null 2>&1
echo "rb = file://$RP/b" > "$RP/url.repos"
check "a file:// URL is a repository" 0 tr url show rp-dup
echo "web = https://example.invalid/repo" > "$RP/http.repos"
check "an unfetched remote repository is skipped with a hint" 0 tr http list --available
has "it says to run update" "has not been fetched yet, run 'tatami update'"
mkdir -p "$ROOT/var/lib/tatami/packages"
mkp "$ROOT/var/lib/tatami/packages" rp-local 1.0 - - usr/share/rp-local/f:local
check "without a repos.conf the repository is <root>/var/lib/tatami/packages" 0 tr default -y install rp-local
exists "installed from the default repository inside the root" usr/share/rp-local/f
tr default -y remove rp-local >/dev/null 2>&1
: > "$ROOT/etc/tatami/repos.conf"
check "an empty repos.conf falls back to the default repository too" 0 "$TATAMI" -r "$ROOT" -c "$RP/base.conf" -y install rp-local
printf '# only a comment\n' > "$ROOT/etc/tatami/repos.conf"; "$TATAMI" -r "$ROOT" -c "$RP/base.conf" -y remove rp-local >/dev/null 2>&1
check "so does one with only comments" 0 "$TATAMI" -r "$ROOT" -c "$RP/base.conf" -y install rp-local
printf 'REPO_DIRS = %s\n' "$RP/a" > "$RP/olddirs.conf"
check "REPO_DIRS in tatami.conf is refused" 1 "$TATAMI" -r "$ROOT" -c "$RP/olddirs.conf" list
has "with a pointer to repos.conf" "REPO_DIRS is gone: list the repositories in etc/tatami/repos.conf"
ROOT="$ROOT_MAIN"

echo "# target architecture: the pool follows the target system, mismatches are refused"
AR="$T/arch"; rm -rf "$AR"; mkdir -p "$AR/repo" "$AR/root/etc"
# the arch goes into the file name, the package name may not contain '_': ar-x86_64 is ar-x8664
for a in riscv64 x86_64 i686 aarch64 noarch; do mkp "$AR/repo" "ar-${a//_/}" 1.0 "$a" - "usr/share/ar-${a//_/}/f:$a"; done
mkp "$AR/repo" ar-needs 1.0 noarch '"ar-aarch64"' usr/share/ar-needs/f:needs
publish_index "$AR/repo" >/dev/null 2>&1
ROOT="$AR/root"
arch_try() { # machine package... : install in a fresh root on a host that reports that machine
	local mach="$1"; shift
	rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
	set_repos "$ROOT" "$AR/repo"
	printf '' > "$AR/c.conf"
	OUT=$(machine "$mach" "$TATAMI" -r "$ROOT" -c "$AR/c.conf" -y install "$@" 2>&1); rc=$?
}
arch_try riscv64 ar-riscv64 ar-noarch; [ $rc -eq 0 ] && ok "a riscv64 target installs riscv64 and noarch packages" || bad "riscv64 target" "$OUT"
exists "riscv64 package installed" usr/share/ar-riscv64/f
arch_try riscv64 ar-aarch64; [ $rc -ne 0 ] && echo "$OUT" | grep -q "incompatible with this system (riscv64)" && ok "a riscv64 target refuses an aarch64 package, naming both" || bad "foreign arch accepted" "$OUT"
arch_try riscv64 ar-x8664; [ $rc -ne 0 ] && ok "and an x86_64 one" || bad "x86_64 accepted on riscv64" "$OUT"
arch_try x86_64 ar-x8664; [ $rc -eq 0 ] && ok "an x86_64 target installs x86_64 packages" || bad "x86_64 target" "$OUT"
arch_try x86_64 ar-i686; [ $rc -ne 0 ] && ok "an x86_64 target does not install i686 packages (no implicit multilib)" || bad "i686 accepted on a plain x86_64 target" "$OUT"
arch_try "$HARCH" ar-noarch; [ $rc -eq 0 ] && ok "noarch fits any target" || bad "noarch refused" "$OUT"
arch_try riscv64 ar-needs; [ $rc -ne 0 ] && echo "$OUT" | grep -q "ar-aarch64" && ok "a dependency that exists only for another architecture is not found" || bad "wrong-arch dependency accepted" "$OUT"
arch_try aarch64 ar-needs; [ $rc -eq 0 ] && exists "while on aarch64 it resolves" usr/share/ar-aarch64/f || bad "dependency on the right arch" "$OUT"
# tatami-mkpkg takes the architecture from the recipe, never from the configuration
mkdir -p "$AR/recipe"; printf 'name=ar-default\nversion=1\narch=riscv64\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$AR/recipe/Tatamifile"
printf '' > "$AR/mk.conf"
check "tatami-mkpkg builds for the architecture of the recipe" 0 mk -f "$AR/recipe/Tatamifile" -o "$AR/out"
[ -f "$AR/out/ar-default_1_riscv64.tar.pkg" ] && ok "ar-default_1_riscv64.tar.pkg" || bad "arch in file name" "$(ls "$AR/out")"
check "tatami read the architecture back" 0 "$TATAMI" -c "$AR/mk.conf" files "$AR/out/ar-default_1_riscv64.tar.pkg"
printf 'ARCH = riscv64\n' > "$AR/old.conf"
check "ARCH in tatami.conf is an error that says where it went" 1 "$TATAMI" -c "$AR/old.conf" list
has "it says the machine architecture is used" "ARCH is gone"
printf 'name=ar-plain\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$AR/recipe/Plain"
OUT=$(mk -f "$AR/recipe/Plain" -o "$AR/out" 2>"$AR/err.txt"); rc=$?
[ $rc -ne 0 ] && ok "tatami-mkpkg refuses a recipe without arch" || bad "recipe without arch built"
[ "$(cat "$AR/err.txt")" = "Error: arch is not defined in Tatamifile" ] && ok "with exactly the message on stderr" || bad "error message" "$(cat "$AR/err.txt")"
[ -z "$OUT" ] && ok "and nothing on stdout" || bad "stdout" "$OUT"
printf 'name=ar-empty\nversion=1\narch=\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$AR/recipe/Empty"
mk -f "$AR/recipe/Empty" -o "$AR/out" 2>"$AR/err.txt"; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$AR/err.txt")" = "Error: arch is not defined in Tatamifile" ] && ok "an empty arch= is the same error" || bad "empty arch" "$(cat "$AR/err.txt")"
[ -z "$(ls "$AR/out" | grep 'ar-plain\|ar-empty')" ] && ok "no package was produced" || bad "package produced" "$(ls "$AR/out")"
printf 'ARCH = riscv64\n' > "$AR/ignored.conf"
ROOT="$ROOT_MAIN"

echo "# --root: nothing outside the root is touched (usr-merged root with an ABSOLUTE link /lib -> /usr/lib)"
IR="$T/iso-root"; rm -rf "$IR"; mkdir -p "$IR/usr/lib" "$IR/usr/bin" "$IR/etc" "$T/iso-repo"
ln -s /usr/lib "$IR/lib"; ln -s usr/bin "$IR/bin"
HF=$(for f in /usr/lib/*; do [ -f "$f" ] && [ ! -L "$f" ] && { basename "$f"; break; }; done)
HOSTSUM=$(md5sum "/usr/lib/$HF" | cut -d' ' -f1)
HOSTLINK=$(readlink /lib 2>/dev/null)
had_pkg=0; [ -e /var/lib/pkg ] && had_pkg=1
had_tatami=0; [ -e /var/lib/tatami ] && had_tatami=1
ldcache=$(stat -c %Y /etc/ld.so.cache 2>/dev/null)
STAMP="$T/iso.stamp"; touch "$STAMP"; sleep 1
# this package ships a file under lib/ whose name is also a real file in the HOST's /usr/lib
mkp "$T/iso-repo" iso-pkg 1.0 - - "lib/$HF:from the package" lib/isolib.so:lib bin/isotool:tool usr/share/iso/data:data
publish_index "$T/iso-repo" >/dev/null 2>&1
printf '' > "$T/iso.conf"
set_repos "$IR" "$T/iso-repo"
ti() { "$TATAMI" -r "$IR" -c "$T/iso.conf" "$@"; }
OUT=$(ti -y install iso-pkg 2>&1); rc=$?
[ $rc -eq 0 ] && ok "install into the usr-merged root" || bad "install failed" "$OUT"
[ -f "$IR/usr/lib/isolib.so" ] && ok "lib/isolib.so went through the link to <root>/usr/lib" || bad "file not in the root's usr/lib" "$(find "$IR" -name isolib.so)"
[ -f "$IR/usr/bin/isotool" ] && ok "bin/isotool went through the relative link to <root>/usr/bin" || bad "isotool missing"
[ "$(cat "$IR/usr/lib/$HF")" = "from the package" ] && ok "the package's lib/$HF is <root>/usr/lib/$HF" || bad "wrong content" "$(cat "$IR/usr/lib/$HF")"
[ "$(md5sum "/usr/lib/$HF" | cut -d' ' -f1)" = "$HOSTSUM" ] && ok "the host's /usr/lib/$HF is unchanged (same name, installed over the link)" || bad "HOST FILE CHANGED"
[ ! -e /usr/lib/isolib.so ] && ok "nothing new appeared in the host's /usr/lib" || bad "HOST /usr/lib/isolib.so EXISTS"
[ -L "$IR/lib" ] && [ "$(readlink "$IR/lib")" = /usr/lib ] && ok "the root's own link is still /lib -> /usr/lib" || bad "link changed"
ti -y install iso-pkg >/dev/null 2>&1
mkp "$T/iso-repo" iso-pkg 2.0 - - "lib/$HF:from the package v2" lib/isolib.so:lib2 bin/isotool:tool2
publish_index "$T/iso-repo" >/dev/null 2>&1
OUT=$(ti -y upgrade 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$IR/usr/lib/isolib.so")" = lib2 ] && ok "upgrade through the links" || bad "upgrade" "$OUT"
[ "$(md5sum "/usr/lib/$HF" | cut -d' ' -f1)" = "$HOSTSUM" ] && ok "the host file is still unchanged after the upgrade" || bad "HOST FILE CHANGED BY UPGRADE"
OUT=$(ti -y remove iso-pkg 2>&1); rc=$?
[ $rc -eq 0 ] && ok "remove through the links" || bad "remove" "$OUT"
[ ! -e "$IR/usr/lib/isolib.so" ] && [ ! -e "$IR/usr/lib/$HF" ] && ok "the files were removed from the root" || bad "files left in the root"
[ -f "/usr/lib/$HF" ] && [ "$(md5sum "/usr/lib/$HF" | cut -d' ' -f1)" = "$HOSTSUM" ] && ok "REMOVING did not delete the host's /usr/lib/$HF (the link was resolved inside the root)" || bad "HOST FILE DELETED OR CHANGED BY REMOVE"
[ -L "$IR/lib" ] && ok "the root's /lib link survived the removal" || bad "link removed"
# the database and the journal are the root's
[ -f "$IR/var/lib/tatami/db" ] && ok "database: <root>/var/lib/tatami/db" || bad "no database in the root"
[ -d "$IR/var/lib/tatami/meta" ] && ok "state: <root>/var/lib/tatami" || bad "no state in the root"
[ ! -e "$IR/var/lib/tatami/transaction.journal" ] && ok "no journal left in the root" || bad "journal left"
[ "$(readlink /lib 2>/dev/null)" = "$HOSTLINK" ] && ok "the host's /lib is as it was" || bad "host /lib changed"
[ -e /var/lib/pkg ] && [ $had_pkg = 0 ] && bad "tatami created /var/lib/pkg on the host" || ok "no /var/lib/pkg was created on the host (unused)"
[ -e /var/lib/tatami ] && [ $had_tatami = 0 ] && bad "tatami created /var/lib/tatami on the host" || ok "no /var/lib/tatami was created on the host"
[ "$(stat -c %Y /etc/ld.so.cache 2>/dev/null)" = "$ldcache" ] && ok "the host's ld.so.cache is untouched" || bad "host ld.so.cache changed"
CHANGED=$(find /usr /etc /var/lib /bin /sbin /lib /lib64 /opt -xdev -newer "$STAMP" 2>/dev/null | head -5)
[ -z "$CHANGED" ] && ok "no file below /usr /etc /var/lib /bin /sbin /lib /opt on the host is newer than the start of the test" || bad "the host was modified" "$CHANGED"
# a symlink loop in the root is an error, not a hang or an escape
ln -s loop "$IR/loop"
mkp "$T/iso-repo" iso-loop 1.0 - - loop/x:x
publish_index "$T/iso-repo" >/dev/null 2>&1
OUT=$(timeout 20 "$TATAMI" -r "$IR" -c "$T/iso.conf" -y install iso-loop 2>&1); rc=$?
[ $rc -ne 0 ] && [ $rc -ne 124 ] && echo "$OUT" | grep -q "too many levels of symbolic links" && ok "a symbolic link loop in the root is reported" || bad "link loop (rc $rc)" "$OUT"
rm -f "$IR/loop"
# without --root the root is /: read-only commands work on the host's database and create nothing
check "without -r the root is /" 0 "$TATAMI" -c "$T/iso.conf" list
[ ! -e /var/lib/tatami ] || [ $had_tatami = 1 ] && ok "a read-only command on / created no state" || bad "list created /var/lib/tatami"
OUT=$("$TATAMI" -c "$T/iso.conf" -r / --version 2>&1); echo "$OUT" | grep -q '^tatami' && ok "-r / is accepted" || bad "-r /"

echo "# hooks: post-transaction triggers, nothing hard-coded"
HK="$T/hk-root"; rm -rf "$HK"; mkdir -p "$HK/etc/tatami/hooks.d" "$HK/etc"
mkdir -p "$T/hk-repo"
mkp "$T/hk-repo" hk-lib 1.0 - - usr/lib/libhk.so:lib
mkp "$T/hk-repo" hk-lib2 1.0 - - usr/lib/libhk2.so:lib2
mkp "$T/hk-repo" hk-data 1.0 - - usr/share/hk-data/f:data
publish_index "$T/hk-repo" >/dev/null 2>&1
printf '' > "$T/hk.conf"
set_repos "$HK" "$T/hk-repo"
th() { "$TATAMI" -r "$HK" -c "$T/hk.conf" "$@"; }
cat > "$HK/etc/tatami/hooks.d/10-libs.hook" <<'HOOK'
# runs when something below usr/lib changed; checks that the database already lists the package
Trigger   = ^usr/lib/
Operation = install upgrade
Exec      = /bin/sh -c 'echo "libs: $(grep -c "^hk-lib" "%ROOT%/var/lib/tatami/db") $TATAMI_ROOT" >> "%ROOT%/hook.log"'
HOOK
cat > "$HK/etc/tatami/hooks.d/20-removed.hook" <<'HOOK'
Trigger   = ^usr/lib/
Operation = remove
Exec      = /bin/sh -c 'echo removed >> "%ROOT%/hook.log"'
HOOK
cat > "$HK/etc/tatami/hooks.d/30-needs.hook" <<'HOOK'
Trigger   = ^usr/
Needs     = etc/this-file-does-not-exist
Exec      = /bin/sh -c 'echo SHOULD-NOT-RUN >> "%ROOT%/hook.log"'
HOOK
check "install two libraries in one transaction" 0 th -y install hk-lib hk-lib2
has "the hook ran" "Running hook 10-libs"
[ "$(grep -c '^libs:' "$HK/hook.log")" = 1 ] && ok "once per transaction, not once per package" || bad "hook count" "$(cat "$HK/hook.log")"
grep -q "^libs: 2 $HK\$" "$HK/hook.log" && ok "after the database commit (it saw both packages) with %ROOT% and TATAMI_ROOT set" || bad "hook environment or timing" "$(cat "$HK/hook.log")"
grep -q SHOULD-NOT-RUN "$HK/hook.log" && bad "a hook whose Needs is missing ran" || ok "a hook whose Needs path is missing does not run"
hasnt "and it is not even announced" "30-needs"
check "install a package that triggers nothing" 0 th -y install hk-data
hasnt "no hook runs" "Running hook"
[ "$(grep -c '^libs:' "$HK/hook.log")" = 1 ] && ok "the log did not grow" || bad "hook ran for an unrelated package"
check "remove a library" 0 th -y remove hk-lib
has "the remove hook ran" "Running hook 20-removed"
hasnt "the install/upgrade hook did not" "Running hook 10-libs"
grep -q '^removed$' "$HK/hook.log" && ok "remove hook output logged" || bad "remove hook" "$(cat "$HK/hook.log")"
cat > "$HK/etc/tatami/hooks.d/40-fails.hook" <<'HOOK'
Trigger = ^usr/
Exec    = /bin/sh -c 'exit 3'
HOOK
check "a failing hook does not undo the transaction or fail the command" 0 th -y install hk-lib
has "it is reported" "hook 40-fails failed \(exit status 3\)"
[ -f "$HK/usr/lib/libhk.so" ] && ok "the package is installed" || bad "the package is not installed"
rm "$HK/etc/tatami/hooks.d/40-fails.hook"
cat > "$HK/etc/tatami/hooks.d/50-missing.hook" <<'HOOK'
Trigger = ^usr/
Exec    = /no/such/program --flag
HOOK
OUT=$(th -y remove hk-data 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$OUT" | grep -q "could not run /no/such/program" && ok "a hook whose program does not exist is reported, not fatal" || bad "missing hook program (rc $rc)" "$OUT"
rm "$HK/etc/tatami/hooks.d/50-missing.hook"
printf 'Trigger = ^usr/\nColor = blue\nExec = true\n' > "$HK/etc/tatami/hooks.d/60-bad.hook"
check "a malformed hook is an error" 1 th -y install hk-data
has "with the file and line" "60-bad.hook:2: unknown key 'Color'"
[ ! -e "$HK/usr/share/hk-data/f" ] && ok "and it stopped the transaction before anything was installed" || bad "package installed despite the malformed hook"
rm "$HK/etc/tatami/hooks.d/60-bad.hook"
printf 'Exec = true\n' > "$HK/etc/tatami/hooks.d/61-notrigger.hook"
check "a hook without a Trigger is an error" 1 th -y install hk-data
has "naming the hook" "61-notrigger.hook: hook has no Trigger"
rm "$HK/etc/tatami/hooks.d/61-notrigger.hook"
# the shipped ldconfig hook, for real, inside the scratch root
rm -f "$HK/etc/tatami/hooks.d/"*.hook "$HK/hook.log"
if [ -x /sbin/ldconfig ] && [ -f "$PWD/hooks/ldconfig.hook" ]; then
	cp "$PWD/hooks/ldconfig.hook" "$HK/etc/tatami/hooks.d/"
	th -y remove hk-lib hk-lib2 hk-data >/dev/null 2>&1
	OUT=$(th -y install hk-lib 2>&1)
	hasnt "the shipped ldconfig hook needs etc/ld.so.conf, which the root lacks: it does not run" "Running hook ldconfig"
	: > "$HK/etc/ld.so.conf"
	th -y remove hk-lib >/dev/null 2>&1
	OUT=$(th -y install hk-lib 2>&1)
	has "with etc/ld.so.conf in the root the shipped hook runs" "Running hook ldconfig"
	[ -e "$HK/etc/ld.so.cache" ] && ok "ldconfig -r <root> built the cache inside the root" || bad "no ld.so.cache in the root" "$OUT"
	[ "$(stat -c %Y /etc/ld.so.cache 2>/dev/null)" = "$ldcache" ] && ok "and not the host's" || bad "host ld.so.cache changed by the hook"
else
	echo "skip - the shipped ldconfig hook (no /sbin/ldconfig)"
fi

echo "# file names: <name>_<version>.<ext>"
mkpkg libfoo-dev 2.0 "depends=libfoo >= 1.0" file=usr/include/foo.h
[ -f "$REPO/libfoo-dev_2.0-1_$HARCH.$EXT" ] && ok "name with a hyphen: libfoo-dev_2.0-1_$HARCH.$EXT" || bad "hyphenated package file name" "$(ls "$REPO")"
check "update indexes it under the right name" 0 t update
check "search finds the hyphenated name" 0 t search '^libfoo-dev$'
has "name and version taken apart correctly" "^libfoo-dev/2.0-1"
cp "$REPO/ed_1.0-1_$HARCH.$EXT" "$REPO/renamed_9.9-1_$HARCH.$EXT"
check "update with a misnamed file" 0 t update
has "warns that the name differs from the contents" "renamed_9.9-1_$HARCH.$EXT is named differently from its contents \(ed_1.0-1_$HARCH"
rm -f "$REPO/renamed_9.9-1_$HARCH.$EXT"; t update >/dev/null 2>&1
mkdir -p "$T/recipes/under_score"
printf 'name=under_score\nversion=1\narch='$HARCH'\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/under_score/Tatamifile"
check "tatami-mkpkg refuses '_' in a package name" 1 mk -f "$T/recipes/under_score/Tatamifile" -o "$T/failout"
has "explains why" "separates name and version"
mkdir -p "$T/underdir/x"; echo x > "$T/underdir/x/f"
printf 'name: us_er\nversion: 1\n' > "$T/underdir/.META"
(cd "$T/underdir" && tar -cf "$T/us-er.$EXT" .META x/f)
[ -f "$T/us-er.$EXT" ] && ok "fixture package with '_' in its name exists" || bad "fixture missing"
check "tatami refuses '_' in a package name" 1 ty install "$T/us-er.$EXT"
has "names the offending package" "invalid package name 'us_er'"

echo "# safety"
mkdir -p "$T/evil/x"; echo bad > "$T/evil/x/f"
printf 'name: evil\nversion: 1\n' > "$T/evil/.META"
(cd "$T/evil" && tar -cf "$T/evil.$EXT" .META --transform 's,^x/,../escaped/,' x/f 2>/dev/null)
check "path traversal is refused" 1 ty install "$T/evil.$EXT"
absent "nothing escaped" ../escaped/f
[ ! -e "$T/escaped/f" ] && ok "nothing outside root" || bad "file escaped the root"
# symlink pointing outside of the root, then a file written through it
mkdir -p "$T/outside"
python3 - "$T" "$EXT" <<'PY'
import tarfile, io, sys
t, ext = sys.argv[1], sys.argv[2]
def add(tf, name, data=b"", typ=tarfile.REGTYPE, link=""):
    i = tarfile.TarInfo(name); i.type = typ; i.linkname = link; i.size = len(data) if typ == tarfile.REGTYPE else 0
    i.mode = 0o755 if typ != tarfile.REGTYPE else 0o644
    tf.addfile(i, io.BytesIO(data) if typ == tarfile.REGTYPE else None)
with tarfile.open(t + "/sym." + ext, "w:gz") as tf:
    add(tf, ".META", b"name: sym\nversion: 1\n")
    add(tf, "esc", typ=tarfile.SYMTYPE, link=t + "/outside")
    add(tf, "esc/pwned", b"pwn")
with tarfile.open(t + "/nl." + ext, "w:gz") as tf:
    add(tf, ".META", b"name: nl\nversion: 1\n")
    add(tf, "a\n\nvictim\n9\nbin/evil", b"x")
with tarfile.open(t + "/db." + ext, "w:gz") as tf:
    add(tf, ".META", b"name: dbp\nversion: 1\n")
    add(tf, "var/lib/tatami/db", b"corrupt")
PY
# the package's symlink points at an absolute host path; inside the root that path means <root>/<path>
check "a package symlink with an absolute target is confined to the root" 0 ty install "$T/sym.$EXT"
[ ! -e "$T/outside/pwned" ] && ok "nothing was written to the host through the symlink" || bad "file written outside the root via symlink"
[ -f "$ROOT$T/outside/pwned" ] && ok "the write went to the same path inside the root instead" || bad "write did not land inside the root" "$(find "$ROOT" -name pwned)"
check "newline in a member name is refused" 1 ty install "$T/nl.$EXT"
check "package may not overwrite the database" 1 ty install "$T/db.$EXT"
check "empty root argument is refused" 1 "$TATAMI" -r "" list
echo notapackage > "$T/junk.$EXT"
check "garbage is refused" 1 ty install "$T/junk.$EXT"
check "unknown command" 1 t frobnicate
check "unknown option" 1 t --frobnicate list
check "version" 0 "$TATAMI" --version

echo "# remote repositories: FETCHCMD, repos.conf, cache"
RR="$T/rem-root"; SRVDIR="$T/rem-srv"; FLOG="$T/rem-fetch.log"; export SRVDIR FLOG
rm -rf "$RR" "$SRVDIR" "$FLOG"; mkdir -p "$RR/etc/tatami" "$SRVDIR/core"
mkp "$SRVDIR/core" rm-app 1.0 - rm-lib usr/share/rm-app/f:app
mkp "$SRVDIR/core" rm-lib 1.0 - - usr/share/rm-lib/f:lib
publish_index "$SRVDIR/core" >/dev/null
# the "network": a fetch command that logs and copies from $SRVDIR instead of connecting
cat > "$T/rem.conf" <<'CONF'
ALLOW_UNSIGNED = yes
FETCHCMD = sh -c 'echo "$0" >> "$FLOG"; cp "$SRVDIR/${0#https://mirror.test/}" "$1"' %URL% %DEST%
CONF
rr() { "$TATAMI" -r "$RR" -c "$T/rem.conf" "$@"; }
echo "core = https://mirror.test/core" > "$RR/etc/tatami/repos.conf"
check "remote repository not fetched yet: skipped" 0 rr list --available
has "with a hint" "has not been fetched yet"
[ ! -e "$FLOG" ] && ok "list never ran FETCHCMD" || bad "FETCHCMD ran for list"
check "update fetches the remote index" 0 rr update
[ "$(cat "$FLOG")" = "https://mirror.test/core/repo.solv" ] && ok "FETCHCMD got the repo.solv URL" || bad "unexpected fetches" "$(cat "$FLOG")"
[ "$(head -c 4 "$RR/var/lib/tatami/repos/core/repo.solv")" = SOLV ] && ok "index cached in <root>/var/lib/tatami/repos/core/" || bad "no cached index"
check "install from the cached index" 0 rr -y install rm-app
FILE="rm-app_1.0_${HARCH}"; grep -q "^https://mirror.test/core/$FILE\." "$FLOG" && ok "the package was downloaded" || bad "no download" "$(cat "$FLOG")"
[ -z "$(ls "$RR/var/cache/tatami/packages/" 2>/dev/null)" ] && ok "after the commit the downloaded packages are deleted from <root>/var/cache/tatami/packages" || bad "cache not cleaned" "$(ls "$RR/var/cache/tatami/packages")"
[ -f "$RR/usr/share/rm-app/f" ] && [ -f "$RR/usr/share/rm-lib/f" ] && ok "package and dependency installed" || bad "not installed"
[ "$(grep -c '^https://mirror.test/core/rm-' "$FLOG")" = 2 ] && ok "both package URLs were built from the repository URL" || bad "package fetches" "$(cat "$FLOG")"
rr -y remove rm-app rm-lib >/dev/null 2>&1
: > "$FLOG"
check "reinstall" 0 rr -y install rm-app
[ "$(grep -c '^https://mirror.test/core/rm-' "$FLOG")" = 2 ] && ok "the cache was cleaned, so both packages are downloaded again" || bad "unexpected fetches" "$(cat "$FLOG")"
rr -y remove rm-app rm-lib >/dev/null 2>&1
rm -rf "$RR/var/cache"; : > "$FLOG"
check "simulate does not download" 0 rr -s install rm-app
[ ! -s "$FLOG" ] && [ ! -e "$RR/var/cache/tatami/packages" ] && ok "nothing fetched when simulating" || bad "simulate fetched" "$(cat "$FLOG")"
# a corrupt download is refused and leaves the system alone
for f in "$SRVDIR"/core/rm-lib_1.0_*; do [ "${f##*/}" = repo.solv ] || printf garbage > "$f"; done
check "a corrupt package download is refused" 1 rr -y install rm-lib
[ ! -e "$RR/usr/share/rm-lib/f" ] && ok "nothing installed from it" || bad "installed garbage"
# a repo.solv that is not an index must not replace the good one
cp "$RR/var/lib/tatami/repos/core/repo.solv" "$T/good.solv"
echo "<html>404</html>" > "$SRVDIR/core/repo.solv"
rr update >/dev/null 2>&1
has_o=$(rr update 2>&1); echo "$has_o" | grep -q "not a valid index" && ok "an invalid downloaded index is rejected" || bad "invalid index accepted" "$has_o"
cmp -s "$T/good.solv" "$RR/var/lib/tatami/repos/core/repo.solv" && ok "the previous index was kept" || bad "index replaced"
# a failing / missing fetch command
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = false %%URL%% %%DEST%%\n' > "$T/rem-fail.conf"
check "update with a failing FETCHCMD only warns" 0 "$TATAMI" -r "$RR" -c "$T/rem-fail.conf" update
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = no-such-fetcher-xyz %%URL%% %%DEST%%\n' > "$T/rem-miss.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/rem-miss.conf" update 2>&1); echo "$OUT" | grep -q "could not run no-such-fetcher-xyz" && ok "missing fetch program is reported" || bad "missing program" "$OUT"
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = curl %%URL%%\n' > "$T/rem-bad.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/rem-bad.conf" update 2>&1); echo "$OUT" | grep -q "must contain %URL% and %DEST%" && ok "FETCHCMD without %DEST% is refused" || bad "bad FETCHCMD" "$OUT"
# the default FETCHCMD is curl -f -L -# "%URL%" -o "%DEST%"
printf 'ALLOW_UNSIGNED = yes\n' > "$T/rem-def.conf"
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "$@" > "$FLOG"\nexit 1\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
PATH="$T/fakebin:$PATH" "$TATAMI" -r "$RR" -c "$T/rem-def.conf" update >/dev/null 2>&1
grep -q -- '^-f -L -# https://mirror.test/core/repo.solv -o .*/repos/core/repo.solv.part$' "$FLOG" && ok "default FETCHCMD is: curl -f -L -# URL -o DEST" || bad "default command" "$(cat "$FLOG")"
# a hostile URL cannot run anything: the command is not started through a shell
echo 'evil = https://mirror.test/x$(touch${IFS}'"$T"'/pwned)' > "$RR/etc/tatami/repos.conf"
rr update >/dev/null 2>&1
[ ! -e "$T/pwned" ] && ok "shell syntax in a URL is not executed" || bad "URL injection"
# repos.conf format
printf 'noequals\n' > "$RR/etc/tatami/repos.conf"
check "a malformed repos.conf line is an error" 1 rr list --available
printf 'a=/x\na=/y\n' > "$RR/etc/tatami/repos.conf"
check "a repository defined twice is an error" 1 rr list --available
printf 'x=gopher://h/p\n' > "$RR/etc/tatami/repos.conf"
check "an unsupported URL scheme is refused" 1 rr list --available
rm "$RR/etc/tatami/repos.conf"; mkdir -p "$RR/etc/tatami/repos.d"
echo "core = https://mirror.test/core" > "$RR/etc/tatami/repos.d/10-core.conf"
echo "# comment" > "$RR/etc/tatami/repos.d/20-none.conf"
: > "$FLOG"; cp "$T/good.solv" "$SRVDIR/core/repo.solv"
check "repos.d/*.conf is read" 0 rr update
grep -q repo.solv "$FLOG" && ok "a repository from repos.d was fetched" || bad "repos.d ignored" "$(cat "$FLOG")"

echo "# remote repositories: progress bar"
cat > "$T/prog-fetch" <<'PF'
#!/bin/sh
# behaves like curl -#: progress on stderr, \r-separated, then the file
printf '\r#####                  25.0%%' >&2
printf '\r###########            50.0%%' >&2
printf '\r######################100.0%%\n' >&2
cp "$SRVDIR/${1#https://mirror.test/}" "$2"
PF
chmod +x "$T/prog-fetch"
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = %s %%URL%% %%DEST%%\n' "$T/prog-fetch" > "$T/prog.conf"
echo "core = https://mirror.test/core" > "$RR/etc/tatami/repos.conf"; rm -rf "$RR/etc/tatami/repos.d"
cp "$T/good.solv" "$SRVDIR/core/repo.solv" 2>/dev/null || publish_index "$SRVDIR/core" >/dev/null
rm -f "$SRVDIR"/core/rm-*_1.0_*; mkp "$SRVDIR/core" rm-app 1.0 - - usr/share/rm-app/f:app; publish_index "$SRVDIR/core" >/dev/null
PROGOUT=$(python3 - "$TATAMI" "$RR" "$T/prog.conf" <<'PY'
import os, pty, sys, select
tatami, root, conf = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.execv(tatami, [tatami, "-r", root, "-c", conf, "-y", "update"])
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d: break
    out += d
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r", "<CR>"))
PY
)
echo "$PROGOUT" | grep -q 'repo.solv  *\[#\{7\}\.\{23\}\]  25%' && ok "a pacman style bar is drawn from the parsed percentages: name [#######.....] 25%" || bad "no bar at 25%" "$PROGOUT"
echo "$PROGOUT" | grep -q 'repo.solv  *\[#\{30\}\] 100%' && ok "the bar ends full at 100%" || bad "no full bar" "$PROGOUT"
echo "$PROGOUT" | grep -q '<CR>repo.solv' && ok "each step redraws the same line with a carriage return" || bad "no carriage return redraw" "$PROGOUT"
[ "$(echo "$PROGOUT" | grep -o '<CR>repo.solv.*' | head -3 | awk '{print length($0)}' | sort -u | wc -l)" = 1 ] && ok "every redraw has the same width, so it covers the one before" || bad "bar width changes" "$PROGOUT"
echo "$PROGOUT" | grep -q '100\.0%' && bad "raw curl progress leaked through" "$PROGOUT" || ok "the raw progress text is hidden"
echo "$PROGOUT" | grep -q '\[=' && bad "the old bar style is still drawn" "$PROGOUT" || ok "no = or > bar characters, no colours or escape codes"
echo "$PROGOUT" | grep -q $'\033' && bad "an escape code was printed" || ok "no ANSI escape codes"
OUT=$("$TATAMI" -r "$RR" -c "$T/prog.conf" update 2>&1)
echo "$OUT" | grep -q '\[#' && bad "a bar was drawn without a terminal" "$OUT" || ok "no bar when stdout is not a terminal"
echo "$OUT" | grep -q '#' && bad "raw text without terminal" "$OUT" || ok "raw progress hidden without a terminal too"
printf '#!/bin/sh\necho "curl: (22) The requested URL returned error: 404" >&2\nexit 22\n' > "$T/fail-fetch"; chmod +x "$T/fail-fetch"
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = %s %%URL%% %%DEST%%\n' "$T/fail-fetch" > "$T/failmsg.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/failmsg.conf" update 2>&1)
echo "$OUT" | grep -q "exit status 22: curl: (22) The requested URL returned error: 404" && ok "a failing command's last message is in the error" || bad "no failure message" "$OUT"
echo

echo "# transaction summary and prompt on a terminal"
ptyrun() { # <stdin text or ""> <tatami args...>: runs tatami on a pseudo terminal, prints what it wrote
	python3 - "$@" <<'PY'
import os, pty, sys, time
text = sys.argv[1]; args = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(args[0], args)
out = b""
if text:
    time.sleep(0.5); os.write(fd, text.encode())
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d: break
    out += d
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
PY
}
SM="$T/summary"; rm -rf "$SM"; mkdir -p "$SM/root/etc" "$SM/repo"
mkp "$SM/repo" sm-a 1.0 - sm-b usr/share/sm-a/f:one
mkp "$SM/repo" sm-b 1.0 - - usr/share/sm-b/f:one
mkp "$SM/repo" sm-c 1.0 - - usr/share/sm-c/f:one
printf '' > "$SM/c.conf"
set_repos "$SM/root" "$SM/repo"
sm() { "$TATAMI" -r "$SM/root" -c "$SM/c.conf" "$@"; }
smp() { ptyrun "" "$TATAMI" -r "$SM/root" -c "$SM/c.conf" "$@"; }
sm update >/dev/null 2>&1
OUT=$(smp -s install sm-a); OUT=$(echo "$OUT" | sed 's/\t/>/')
has "installs are grouped under a header" "^New packages to be INSTALLED:$"
has "the requested package is indented under it" "^>sm-a: 1.0$"
has "dependencies get their own header" "^Dependencies to be INSTALLED:$"
has "with the dependency under it" "^>sm-b: 1.0$"
[ "$(echo "$OUT" | grep '^>sm-a\|^>sm-b\|^New packages\|^Dependencies' | paste -sd'|' -)" = "New packages to be INSTALLED:|>sm-a: 1.0|Dependencies to be INSTALLED:|>sm-b: 1.0" ] && ok "each package is under the right header, requested ones first" || bad "grouping" "$OUT"
has "the count shows the breakdown" "^Number of packages to be installed: 2 \(1 requested, 1 dependencies\)$"
has "the space needed" "^The process will require [0-9.<]+ ?[0-9.]* ?MiB more space\.$"
OUT=$(smp -s install sm-b | sed 's/\t/>/')
has "a package nothing else is needed for has no dependencies header" "^Number of packages to be installed: 1 \(1 requested, 0 dependencies\)$"
hasnt "no empty Dependencies header" "^Dependencies to be INSTALLED"
OUT=$(smp -s install sm-a | sed 's/\t/>/')
hasnt "no download line for local packages" "to be downloaded"
hasnt "the plain format is not used on a terminal" "to install, "
hasnt "no ANSI escape codes" $'\033'
OUT=$(sm -s install sm-a 2>&1)
has "without a terminal the plain list stays" "The following NEW packages will be installed:"
has "and the plain counts" "2 to install, 0 to upgrade, 0 to remove"
hasnt "and none of the new summary" "Number of packages to be|The process will"
sm -y install sm-a sm-c >/dev/null 2>&1
mkp "$SM/repo" sm-a 2.0 - sm-b usr/share/sm-a/f:two
sm update >/dev/null 2>&1
OUT=$(smp -s upgrade | sed 's/\t/>/')
has "upgrades show old -> new" "^Packages to be UPGRADED:$"
has "for each package" "^>sm-a: 1.0 -> 2.0$"
has "with its count" "^Number of packages to be upgraded: 1$"
OUT=$(smp -s remove sm-c | sed 's/\t/>/')
has "removals are grouped too" "^Packages to be REMOVED:$"
has "with the package" "^>sm-c: 1.0$"
has "the count" "^Number of packages to be removed: 1$"
has "and the space freed" "^The process will free [0-9.<]+ ?[0-9.]* ?MiB space\.$"
OUT=$(ptyrun "n
" "$TATAMI" -r "$SM/root" -c "$SM/c.conf" remove sm-c)
has "the question is 'Proceed with this action? [Y/n]: '" "Proceed with this action\? \[Y/n\]: "
has "answering n aborts" "aborted"
[ -f "$SM/root/usr/share/sm-c/f" ] && ok "and nothing was removed" || bad "removed although refused"
OUT=$(ptyrun "y
" "$TATAMI" -r "$SM/root" -c "$SM/c.conf" remove sm-c)
[ ! -f "$SM/root/usr/share/sm-c/f" ] && ok "answering y removes it" || bad "not removed after y" "$OUT"
# a remote package: the download size
OUT=$(ptyrun "" "$TATAMI" -r "$RR" -c "$T/prog.conf" -s install rm-app)
echo "$OUT" | grep -qE "^[0-9.<]+ ?[0-9.]* ?MiB to be downloaded\.$" && ok "a remote package announces the size to be downloaded" || bad "no download size" "$OUT"
echo

echo "# signatures: Ed25519, checked for remote repositories and packages only"
SG="$T/sig"; rm -rf "$SG"; mkdir -p "$SG/srv/core" "$SG/root/etc/tatami" "$SG/home"
# the Ed25519ph test vector of RFC 8032 section 7.3 ("abc") pins the crypto itself
printf abc > "$SG/abc"; echo 833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42 > "$SG/rfc.key"; chmod 600 "$SG/rfc.key"
check "tatami sign writes <file>.sig" 0 "$TATAMI" sign "$SG/abc" "$SG/rfc.key"
[ "$(cat "$SG/abc.sig")" = 98a70222f0b8121aa9d30f813d683f809e462b469c7ff87639499bb94e6dae4131f85042463c2a355a2003d062adf5aaa10b8c61e636062aaad11c2a26083406 ] && ok "the signature is the RFC 8032 Ed25519ph vector" || bad "wrong signature" "$(cat "$SG/abc.sig")"
check "keygen makes a key pair in ~/.tatami" 0 env HOME="$SG/home" "$TATAMI" keygen
has "it says to copy the public key into /etc/tatami/keys/" "cp .*privkey.pub /etc/tatami/keys/"
hasnt "and no longer mentions PUBKEY" "PUBKEY"
PUB=$(cat "$SG/home/.tatami/privkey.pub")
echo "$PUB" | grep -Eq "^[0-9a-f]{64}$" && ok "the .pub file holds the 64-digit public key" || bad "pub file content" "$PUB"
[ "$(stat -c %a "$SG/home/.tatami/privkey")" = 600 ] && [ "$(stat -c %a "$SG/home/.tatami")" = 700 ] && ok "private key is 0600 in a 0700 directory" || bad "key permissions"
[ -f "$SG/home/.tatami/privkey.pub" ] && [ "$(stat -c %a "$SG/home/.tatami/privkey.pub")" = 644 ] && ok "the public key is written next to it, world-readable" || bad "pub file"
check "keygen does not overwrite a key" 1 env HOME="$SG/home" "$TATAMI" keygen
check "keygen -f replaces it" 0 env HOME="$SG/home" "$TATAMI" keygen -f
PUB=$(cat "$SG/home/.tatami/privkey.pub")
check "sign of a missing file fails" 1 "$TATAMI" sign "$SG/nothing" "$SG/home/.tatami/privkey"
check "sign with a missing key fails" 1 "$TATAMI" sign "$SG/abc" "$SG/nokey"
echo notakey > "$SG/bad.key"; chmod 600 "$SG/bad.key"
check "sign with a malformed key fails" 1 "$TATAMI" sign "$SG/abc" "$SG/bad.key"

# tatami-mkpkg signs as part of the build: the package, and the refreshed repo.solv
cat > "$SG/Tatamifile" <<'RCP'
name=sg-app
version=1.0
arch=@ARCH@
build() { mkdir -p $PKG/usr/share/sg-app; echo signed > $PKG/usr/share/sg-app/f; }
RCP
sed -i "s/@ARCH@/$HARCH/" "$SG/Tatamifile"
# gzip: a few appended bytes (the tampering below) still leave a readable archive, so the index step sees the package
( cd "$SG" && HOME="$SG/home" mk -z gz -f "$SG/Tatamifile" -o "$SG/srv/core" ) > "$SG/mk.log" 2>&1
P="sg-app_1.0_${HARCH}.tar.pkg"
[ -f "$SG/srv/core/$P.sig" ] && [ -f "$SG/srv/core/repo.solv" ] && [ -f "$SG/srv/core/repo.solv.sig" ] && ok "tatami-mkpkg (with ~/.tatami/privkey) left the package, repo.solv and both .sig files" || bad "tatami-mkpkg did not sign" "$(cat "$SG/mk.log"; ls "$SG/srv/core")"

# the same package, unsigned: built without a key (the later tests use it as a local repository)
( cd "$SG" && HOME="$SG/nohome" mk -f "$SG/Tatamifile" -o "$SG/unsigned" ) > "$SG/mk2.log" 2>&1
[ -f "$SG/unsigned/$P" ] && ok "an unsigned copy of the package for the local-repository tests" || bad "unsigned build" "$(cat "$SG/mk2.log")"

# remote repository with a trusted key in etc/tatami/keys: everything fetched is verified
KEYS="$SG/root/etc/tatami/keys"; mkdir -p "$KEYS"; cp "$SG/home/.tatami/privkey.pub" "$KEYS/core.pub"
nokeys() { rm -rf "$KEYS.off"; mv "$KEYS" "$KEYS.off"; }
restorekeys() { rm -rf "$KEYS"; mv "$KEYS.off" "$KEYS"; }
cat > "$SG/ok.conf" <<'CONF'
FETCHCMD = sh -c 'echo "$0" >> "$FLOG"; cp "$SRVDIR/${0#https://mirror.test/}" "$1"' %URL% %DEST%
CONF
SRVDIR="$SG/srv"; export SRVDIR FLOG; FLOG="$SG/fetch.log"; : > "$FLOG"
echo "core = https://mirror.test/core" > "$SG/root/etc/tatami/repos.conf"
sr() { "$TATAMI" -r "$SG/root" -c "$SG/ok.conf" "$@"; }
check "update of a signed remote repository" 0 sr update
grep -qx "https://mirror.test/core/repo.solv.sig" "$FLOG" && ok "the .sig of the index was fetched" || bad "no .sig fetched" "$(cat "$FLOG")"
[ -f "$SG/root/var/lib/tatami/repos/core/repo.solv.sig" ] && ok "index and signature are cached together" || bad "no cached signature"
OUT=$(sr show sg-app 2>&1)
has "tatami index put the package's SHA-256 into repo.solv" "^SHA256: $(sha256sum "$SG/srv/core/$P" | cut -d' ' -f1)$"
check "install from the signed repository" 0 sr -y install sg-app
grep -qx "https://mirror.test/core/$P.sig" "$FLOG" && ok "the package signature was fetched" || bad "package .sig" "$(cat "$FLOG")"
[ -z "$(ls "$SG/root/var/cache/tatami/packages/" 2>/dev/null)" ] && ok "package and .sig are deleted from the cache after the commit" || bad "cache not cleaned" "$(ls "$SG/root/var/cache/tatami/packages")"
[ -f "$SG/root/usr/share/sg-app/f" ] && ok "installed" || bad "not installed"
sr -y remove sg-app >/dev/null 2>&1
: > "$FLOG"
# a transaction that fails keeps the cache; the retry reuses the verified download
mkdir -p "$SG/root/usr/share/sg-app"; echo mine > "$SG/root/usr/share/sg-app/f"
check "an install that fails on a conflicting file" 1 sr -y install sg-app
ls "$SG/root/var/cache/tatami/packages/" | grep -q "^$P$" && ls "$SG/root/var/cache/tatami/packages/" | grep -q "^$P.sig$" && ok "after the rollback the downloaded package and its .sig are still cached" || bad "cache lost on rollback" "$(ls "$SG/root/var/cache/tatami/packages")"
rm -rf "$SG/root/usr/share/sg-app"; : > "$FLOG"
check "the retry" 0 sr -y install sg-app
[ ! -s "$FLOG" ] && ok "a cached package with a valid signature is reused, nothing downloaded again" || bad "re-downloaded" "$(cat "$FLOG")"
[ -z "$(ls "$SG/root/var/cache/tatami/packages/" 2>/dev/null)" ] && ok "and it is deleted once the retry committed" || bad "cache not cleaned after retry"
sr -y remove sg-app >/dev/null 2>&1

# a different key, a tampered package, a missing signature: all refused
HOME="$SG/home2" "$TATAMI" keygen >/dev/null
nokeys; mkdir -p "$KEYS"; cp "$SG/home2/.tatami/privkey.pub" "$KEYS/core.pub"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "update aborts when the index is signed with another key" || bad "wrong key accepted (exit $rc)" "$OUT"
cp "$SG/home/.tatami/privkey.pub" "$KEYS/second.pub"
check "with both keys in the directory the signature of either is good" 0 "$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update
restorekeys
cp "$SG/root/var/lib/tatami/repos/core/repo.solv" "$SG/good.solv"
cp "$SG/srv/core/$P" "$SG/pkg.good"
printf 'tampered' >> "$SG/srv/core/$P"
rm -rf "$SG/root/var/cache"
# 1. the package was swapped on the server but the (signed) index still promises the original
OUT=$(sr -y install sg-app 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "CHECKSUM MISMATCH" && ok "a package that differs from the checksum in the index is refused" || bad "substituted package accepted (exit $rc)" "$OUT"
[ ! -e "$SG/root/usr/share/sg-app/f" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami/packages" 2>/dev/null)" ] && ok "nothing installed, the download (.part) was deleted" || bad "tampered data survived" "$(ls -A "$SG/root/var/cache/tatami/packages")"
# 2. the index was re-signed to match, but the package's own .sig no longer fits
publish_index "$SG/srv/core" >/dev/null; "$TATAMI" sign "$SG/srv/core/repo.solv" "$SG/home/.tatami/privkey" >/dev/null
check "the client takes the re-signed index" 0 sr update
OUT=$(sr -y install sg-app 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "a tampered package is refused by its signature" || bad "tampered package accepted (exit $rc)" "$OUT"
[ ! -e "$SG/root/usr/share/sg-app/f" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami/packages" 2>/dev/null)" ] && ok "nothing installed, nothing left in the cache" || bad "tampered data survived" "$(ls -A "$SG/root/var/cache/tatami/packages")"
cp "$SG/pkg.good" "$SG/srv/core/$P"
publish_index "$SG/srv/core" >/dev/null; "$TATAMI" sign "$SG/srv/core/repo.solv" "$SG/home/.tatami/privkey" >/dev/null
sr update >/dev/null 2>&1
mv "$SG/srv/core/$P.sig" "$SG/pkg.sig"
OUT=$(sr -y install sg-app 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "cannot get the signature" && ok "a missing .sig is refused" || bad "unsigned package accepted (exit $rc)" "$OUT"
mv "$SG/pkg.sig" "$SG/srv/core/$P.sig"
cp "$SG/srv/core/repo.solv" "$SG/srv.solv"
printf 'x' >> "$SG/srv/core/repo.solv"
OUT=$(sr update 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "a tampered index is refused by update" || bad "tampered index accepted (exit $rc)" "$OUT"
cmp -s "$SG/good.solv" "$SG/root/var/lib/tatami/repos/core/repo.solv" && ok "the previous index was kept" || bad "index replaced"
cp "$SG/srv.solv" "$SG/srv/core/repo.solv"
printf 'x' >> "$SG/root/var/lib/tatami/repos/core/repo.solv"
OUT=$(sr list --available 2>&1); rc=$?
echo "$OUT" | grep -q "ignoring repository core: SIGNATURE VERIFICATION FAILED" && ! echo "$OUT" | grep -q "sg-app" && ok "a tampered cached index is ignored with a warning, its packages are not offered" || bad "tampered cache used (exit $rc)" "$OUT"
cp "$SG/good.solv" "$SG/root/var/lib/tatami/repos/core/repo.solv"

# no key in etc/tatami/keys: the key is looked for at <repo url>/tatami.pub (https only)
nokeys; : > "$FLOG"; rm -f "$SG/srv/core/tatami.pub"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1); rc=$?
echo "$OUT" | grep -q "could not fetch the public key https://mirror.test/core/tatami.pub" && ok "no key and none on the server: the repository is skipped with a clear message" || bad "missing tatami.pub (exit $rc)" "$OUT"
cmp -s "$SG/good.solv" "$SG/root/var/lib/tatami/repos/core/repo.solv" && [ ! -e "$KEYS/core.pub" ] && [ -z "$(ls "$SG/root/var/cache/tatami" 2>/dev/null | grep quarantine)" ] && ok "nothing was trusted, replaced or left in quarantine" || bad "state after a missing key"
grep -q "repo.solv" "$FLOG" && bad "the index was fetched although there was no key" "$(cat "$FLOG")" || ok "and the index was not even downloaded"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" list --available 2>&1); rc=$?
echo "$OUT" | grep -q "ignoring repository core: .*no trusted key" && ! echo "$OUT" | grep -q "sg-app" && ok "its cached index is ignored too, not used unauthenticated" || bad "cache used without a key (exit $rc)" "$OUT"
# plain http: the key is never fetched automatically
echo "core = http://mirror.test/core" > "$SG/root/etc/tatami/repos.conf"; : > "$FLOG"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1); rc=$?
echo "$OUT" | grep -q "only fetched automatically over HTTPS" && ok "an http:// repository is refused for auto-fetching, with the reason" || bad "http key fetch (exit $rc)" "$OUT"
[ ! -s "$FLOG" ] && ok "nothing was downloaded" || bad "http repository fetched" "$(cat "$FLOG")"
echo "core = https://mirror.test/core" > "$SG/root/etc/tatami/repos.conf"
# a key that is not a key
echo "not a key" > "$SG/srv/core/tatami.pub"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1)
echo "$OUT" | grep -q "tatami.pub is not a public key" && [ ! -e "$KEYS/core.pub" ] && ok "a tatami.pub that is not a key is rejected" || bad "garbage tatami.pub" "$OUT"
# a key that does not match the index: the proof fails, nothing is kept
cp "$SG/home2/.tatami/privkey.pub" "$SG/srv/core/tatami.pub"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "a fetched key that did not sign the index aborts with a security error" || bad "mismatching key accepted (exit $rc)" "$OUT"
[ ! -e "$KEYS/core.pub" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami" 2>/dev/null | grep quarantine)" ] && [ -z "$(ls "$SG/root/var/lib/tatami/repos/core" | grep part)" ] && ok "the quarantine key and the .part files are deleted, no key trusted" || bad "leftovers after a failed proof" "$(find "$SG/root/var" -name '*quarantine*' -o -name '*.part*')"
cmp -s "$SG/good.solv" "$SG/root/var/lib/tatami/repos/core/repo.solv" && ok "the previous index is kept" || bad "index replaced"
# the right key: the proof holds, the key is trusted, the index committed
cp "$SG/home/.tatami/privkey.pub" "$SG/srv/core/tatami.pub"; : > "$FLOG"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$OUT" | grep -qx "Trusted new key for repository core" && ok "a key that signed the index is trusted: 'Trusted new key for repository core'" || bad "key not trusted (exit $rc)" "$OUT"
echo "$OUT" | grep -q "$PUB" && bad "the fingerprint was printed" "$OUT" || ok "without printing the key"
[ "$(cat "$KEYS/core.pub")" = "$PUB" ] && [ "$(stat -c %a "$KEYS/core.pub")" = 644 ] && ok "etc/tatami/keys/core.pub holds the key" || bad "key file" "$(cat "$KEYS/core.pub" 2>&1)"
[ -z "$(ls -A "$KEYS" | grep '^\.')" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami" 2>/dev/null | grep quarantine)" ] && ok "no temporary or quarantine file is left" || bad "temporary files left" "$(ls -A "$KEYS")"
grep -q "tatami.pub" "$FLOG" && grep -q "repo.solv.sig" "$FLOG" && ok "the key came through FETCHCMD, with the index" || bad "fetch log" "$(cat "$FLOG")"
: > "$FLOG"; check "the next update uses the stored key" 0 "$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update
grep -q "tatami.pub" "$FLOG" && bad "the key was fetched again" || ok "tatami.pub is not fetched again"
check "and installing works with it" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" install sg-app
"$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" remove sg-app >/dev/null 2>&1
rm -f "$SG/srv/core/tatami.pub"; nokeys
{ cat "$SG/ok.conf"; echo "ALLOW_UNSIGNED = yes"; } > "$SG/allow.conf"; : > "$FLOG"
check "ALLOW_UNSIGNED = yes accepts it without a key" 0 "$TATAMI" -r "$SG/root" -c "$SG/allow.conf" update
grep -q "tatami.pub" "$FLOG" && bad "a key was fetched although unsigned data is allowed" || ok "and no key is fetched then"
{ cat "$SG/ok.conf"; echo "ALLOW_UNSIGNED = maybe"; } > "$SG/maybe.conf"
check "ALLOW_UNSIGNED takes yes or no" 1 "$TATAMI" -r "$SG/root" -c "$SG/maybe.conf" list
{ cat "$SG/ok.conf"; echo "PUBKEY = $PUB"; } > "$SG/oldkey.conf"
check "PUBKEY in tatami.conf is refused" 1 "$TATAMI" -r "$SG/root" -c "$SG/oldkey.conf" list
has "and points to the keys directory" "PUBKEY is gone: put the public key file into etc/tatami/keys/"
mkdir -p "$KEYS"; echo garbage > "$KEYS/garbage.pub"; echo "$PUB" > "$KEYS/.hidden"; mkdir "$KEYS/subdir"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/ok.conf" list --available 2>&1); rc=$?
echo "$OUT" | grep -q "garbage.pub is not a public key" && echo "$OUT" | grep -q "no trusted key" && ok "a file that is not a key is skipped with a warning; dot files and directories are ignored" || bad "garbage key handling (exit $rc)" "$OUT"
BASE64=$(python3 -c "import base64,sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())" "$PUB")
echo "$BASE64" > "$KEYS/core.pub"
check "a key file may hold base64" 0 "$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update
rm -rf "$KEYS"; restorekeys
nokeys

# local installations are trusted: no signature, no key, no check
: > "$FLOG"
check "a package file is installed without any signature" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" install "$SG/unsigned/$P"
[ -f "$SG/root/usr/share/sg-app/f" ] && ok "installed from a local file" || bad "local file not installed"
"$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" remove sg-app >/dev/null 2>&1
echo "mine = file://$SG/unsigned" > "$SG/root/etc/tatami/repos.conf"
"$TATAMI" -r "$SG/root" -c "$SG/ok.conf" update >/dev/null 2>&1
check "a file:// repository needs no signature and no key" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" install sg-app
echo "mine = $SG/unsigned" > "$SG/root/etc/tatami/repos.conf"
"$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" remove sg-app >/dev/null 2>&1
check "neither does a plain path repository" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/ok.conf" install sg-app
[ ! -s "$FLOG" ] && ok "no fetch for local repositories" || bad "fetched" "$(cat "$FLOG")"
echo

echo "# install scripts: tatami.install is bundled as .INSTALL, pre_install and post_install run"
IS="$T/inst"; rm -rf "$IS"; mkdir -p "$IS/repo" "$IS/root/etc" "$IS/log"
ILOG="$IS/log/run.log"; export ILOG
# mki <name> <version> <install-script-body|-> : a package with one file and (maybe) a tatami.install
mki() {
	local name="$1" version="$2" body="$3" dir="$IS/recipes/$1-$2"
	mkdir -p "$dir"
	printf 'name=%s\nversion=%s\narch='$HARCH'\nbuild() { mkdir -p $PKG/usr/share/%s; echo "%s %s" > $PKG/usr/share/%s/f; }\n' "$name" "$version" "$name" "$name" "$version" "$name" > "$dir/Tatamifile"
	[ "$body" != - ] && printf '%s\n' "$body" > "$dir/tatami.install"
	mk -f "$dir/Tatamifile" -o "$IS/repo" > "$dir/log" 2>&1 || bad "tatami-mkpkg $name" "$(cat "$dir/log")"
}
mki ins-a 1.0 'pre_install() { echo "pre a $1 root=$TATAMI_ROOT file_there=$([ -e "$TATAMI_ROOT/usr/share/ins-a/f" ] && echo yes || echo no)" >> "$ILOG"; }
post_install() { echo "post a $1 file_there=$([ -e "$TATAMI_ROOT/usr/share/ins-a/f" ] && echo yes || echo no)" >> "$ILOG"; }
post_remove() { echo "post_remove a" >> "$ILOG"; }
pre_remove() { echo "pre_remove a" >> "$ILOG"; }'
mki ins-plain 1.0 -
PK="$IS/repo/ins-a_1.0_${HARCH}.tar.pkg"; PP="$IS/repo/ins-plain_1.0_${HARCH}.tar.pkg"
members() { python3 -c "import tarfile,sys; print(' '.join(m.name.removeprefix('./') for m in tarfile.open(sys.argv[1])))" "$1"; }
members "$PK" | grep -qw '\.INSTALL' && ok "tatami-mkpkg found tatami.install next to the Tatamifile and bundled it as .INSTALL" || bad "no .INSTALL in the package" "$(members "$PK")"
[ "$(python3 -c "import tarfile,sys; t=tarfile.open(sys.argv[1]); print(t.extractfile('.INSTALL').read().decode().count('pre_install'))" "$PK")" = 1 ] && ok "with the script's content" || bad ".INSTALL content"
members "$PP" | grep -qw '\.INSTALL' && bad "a package without tatami.install has .INSTALL" || ok "no tatami.install, no .INSTALL"
grep -q "Bundling tatami.install" "$IS/recipes/ins-a-1.0/log" && ok "tatami-mkpkg says so" || bad "no message"

IR() { "$TATAMI" -r "$IS/root" -c "$CONF" -y "$@"; }
before_tmp=$(ls /tmp | grep -c '^tatami-install-')
check "install it" 0 IR install "$PK"
has "pre_install is announced" "Running pre_install of ins-a"
has "and post_install" "Running post_install of ins-a"
[ "$(sed -n 1p "$ILOG")" = "pre a 1.0 root=$IS/root/ file_there=no" ] && ok "pre_install ran first, with the version and TATAMI_ROOT, before the files exist" || bad "pre_install" "$(cat "$ILOG")"
[ "$(sed -n 2p "$ILOG")" = "post a 1.0 file_there=yes" ] && ok "post_install ran after the commit, the files are there" || bad "post_install" "$(cat "$ILOG")"
[ "$(wc -l < "$ILOG")" = 2 ] && ok "nothing else ran" || bad "extra calls" "$(cat "$ILOG")"
[ ! -e "$IS/root/.INSTALL" ] && IR files ins-a | grep -qv INSTALL && ok ".INSTALL is not installed and not owned by the package" || bad ".INSTALL leaked into the system"
[ "$(ls /tmp | grep -c '^tatami-install-')" = "$before_tmp" ] && ok "the temporary script files are removed" || bad "temporary files left"
: > "$ILOG"
check "removing runs no script (pre_remove/post_remove are not supported)" 0 IR remove ins-a
[ ! -s "$ILOG" ] && ok "no remove function was called" || bad "remove scripts ran" "$(cat "$ILOG")"
check "a package with no tatami.install installs as usual" 0 IR install "$PP"

# a failing pre_install aborts and rolls back the whole transaction, earlier packages included
mki ins-ok 1.0 'pre_install() { echo "pre ok" >> "$ILOG"; }'
mki ins-bad 1.0 'pre_install() { echo "pre bad" >> "$ILOG"; exit 1; }
post_install() { echo "post bad (must not run)" >> "$ILOG"; }'
ROOT="$IS/root"; IR remove ins-plain >/dev/null 2>&1; : > "$ILOG"
before=$(snap)
check "pre_install exits 1: the transaction is refused" 1 IR install "$IS/repo/ins-ok_1.0_${HARCH}.tar.pkg" "$IS/repo/ins-bad_1.0_${HARCH}.tar.pkg"
has "it says which" "pre_install of ins-bad failed"
has "and that it rolled back" "the transaction failed, nothing was changed"
[ "$before" = "$(snap)" ] && ok "rolled back: ins-ok, extracted or not, is gone too, the filesystem is as before" || bad "state differs" "$(diff <(echo "$before") <(echo "$(snap)") | head -6)"
! grep -q "post bad" "$ILOG" && ok "post_install of the failed package did not run" || bad "post ran" "$(cat "$ILOG")"
[ "$(ls /tmp | grep -c '^tatami-install-')" = "$before_tmp" ] && ok "temporary files cleaned up after the failure" || bad "temporary files left"
IR list 2>&1 | grep -q "ins-ok\|ins-bad" && bad "database changed" || ok "the database is untouched"
ROOT="$ROOT_MAIN"

# a failing post_install is only a warning: the files are committed
mki ins-post 1.0 'post_install() { echo "post fails" >> "$ILOG"; return 3; }'
check "post_install exits non-zero: still succeeds" 0 IR install "$IS/repo/ins-post_1.0_${HARCH}.tar.pkg"
has "with a warning" "warning: post_install of ins-post failed"
[ -f "$IS/root/usr/share/ins-post/f" ] && IR list 2>&1 | grep -q "^ins-post/1.0" && ok "the package stays installed" || bad "rolled back by mistake"

# an upgrade runs the new version's functions with the new version
mki ins-a 2.0 'pre_install() { echo "pre a $1" >> "$ILOG"; }
post_install() { echo "post a $1" >> "$ILOG"; }'
check "install ins-a 1.0 again, then upgrade" 0 IR install "$PK"
: > "$ILOG"
check "upgrade to 2.0" 0 IR install "$IS/repo/ins-a_2.0_${HARCH}.tar.pkg"
[ "$(cat "$ILOG")" = "pre a 2.0
post a 2.0" ] && ok "pre_install and post_install of the new version ran with 2.0" || bad "upgrade scripts" "$(cat "$ILOG")"
echo

echo "# HoldPkg: held packages are not upgraded, the others are"
HP="$T/hold"; rm -rf "$HP"; mkdir -p "$HP/srv/core" "$HP/root/etc/tatami"
SRVDIR="$HP/srv"; FLOG="$HP/fetch.log"; export SRVDIR FLOG; : > "$FLOG"
echo "core = https://mirror.test/core" > "$HP/root/etc/tatami/repos.conf"
printf 'ALLOW_UNSIGNED = yes\nFETCHCMD = sh -c '"'"'cp "$SRVDIR/${0#https://mirror.test/}" "$1"'"'"' %%URL%% %%DEST%%\n' > "$HP/plain.conf"
cp "$HP/plain.conf" "$HP/hold.conf"
# the held packages are read from <root>/etc/tatami/hold: hold_with <names...> / hold_none
hold_with() { printf '%s\n' "$@" > "$HP/root/etc/tatami/hold"; }
hold_none() { rm -f "$HP/root/etc/tatami/hold"; }
hr() { "$TATAMI" -r "$HP/root" -c "$1" "${@:2}"; }
mkp "$HP/srv/core" hp-held 1.0 - - usr/share/hp-held/f:one
mkp "$HP/srv/core" hp-free 1.0 - - usr/share/hp-free/f:one
mkp "$HP/srv/core" hp-dep 1.0 - - usr/share/hp-dep/f:one
publish_index "$HP/srv/core" >/dev/null
check "update" 0 hr "$HP/plain.conf" update
check "install the three packages" 0 hr "$HP/plain.conf" -y install hp-held hp-free hp-dep
mkp "$HP/srv/core" hp-held 2.0 - - usr/share/hp-held/f:two
mkp "$HP/srv/core" hp-free 2.0 - - usr/share/hp-free/f:two
publish_index "$HP/srv/core" >/dev/null
check "update fetches the new index" 0 hr "$HP/plain.conf" update
hold_with hp-held
OUT=$(hr "$HP/hold.conf" -y upgrade 2>&1); rc=$?
[ $rc -eq 0 ] && ok "the upgrade with the hold file works" || bad "upgrade failed ($rc)" "$OUT"
has "the held package is reported" "Skipping upgrade for held package: hp-held \(1.0 -> 2.0\)"
[ "$(cat "$HP/root/usr/share/hp-held/f")" = one ] && ok "hp-held stays at version 1.0" || bad "held package changed" "$(cat "$HP/root/usr/share/hp-held/f")"
[ "$(cat "$HP/root/usr/share/hp-free/f")" = two ] && ok "hp-free, not held, was upgraded to 2.0" || bad "free package not upgraded"
hr "$HP/hold.conf" list 2>&1 | grep -q "^hp-held/1.0" && ok "the database still has hp-held 1.0" || bad "database"
OUT=$(hr "$HP/hold.conf" -y upgrade 2>&1)
has "a second upgrade has nothing to do" "Nothing to do"
has "and still says why" "Skipping upgrade for held package: hp-held"
# an explicit request wins over the hold
check "naming the held package in install upgrades it" 0 hr "$HP/hold.conf" -y install hp-held
[ "$(cat "$HP/root/usr/share/hp-held/f")" = two ] && ok "explicitly requested: upgraded despite the hold" || bad "explicit install blocked"
# several names, several lines, a package that is not installed
mkp "$HP/srv/core" hp-held 3.0 - - usr/share/hp-held/f:three
mkp "$HP/srv/core" hp-free 3.0 - - usr/share/hp-free/f:three
publish_index "$HP/srv/core" >/dev/null; hr "$HP/plain.conf" update >/dev/null
printf '# held\n\n  hp-dep  \nnot-installed-anywhere\n#hp-free\nhp-held\n' > "$HP/root/etc/tatami/hold"
check "a hold file with comments, blanks, blanks around names and unknown packages" 0 hr "$HP/plain.conf" -y upgrade
[ "$(cat "$HP/root/usr/share/hp-held/f")" = two ] && [ "$(cat "$HP/root/usr/share/hp-free/f")" = three ] && ok "hp-held held (two), hp-free upgraded (three)" || bad "multi-line hold" "$(cat "$HP/root/usr/share/hp-held/f") $(cat "$HP/root/usr/share/hp-free/f")"
# without a hold file everything is upgraded
hold_none
check "no hold file: the same upgrade takes everything" 0 hr "$HP/plain.conf" -y upgrade
[ "$(cat "$HP/root/usr/share/hp-held/f")" = three ] && ok "hp-held upgraded once it is no longer held" || bad "still held"
{ cat "$HP/plain.conf"; echo "HoldPkg = hp-held"; } > "$HP/oldhold.conf"
check "HoldPkg in tatami.conf is refused" 1 hr "$HP/oldhold.conf" list
has "and points to the hold file" "HoldPkg moved to etc/tatami/hold"
{ cat "$HP/plain.conf"; echo "UPGRADE ^etc/.*\$ NO"; } > "$HP/oldrule.conf"
check "a rule in tatami.conf is refused" 1 hr "$HP/oldrule.conf" list
has "and points to upgrade.rules" "live in etc/tatami/upgrade.rules"
printf 'UPGRADE ^x NOPE\n' > "$HP/root/etc/tatami/upgrade.rules"
check "a bad line in upgrade.rules is an error naming the file" 1 hr "$HP/plain.conf" list
has "with the line" "upgrade.rules:1: 'NOPE' unknown action"
rm -f "$HP/root/etc/tatami/upgrade.rules"
check "no upgrade.rules and no hold file: fine" 0 hr "$HP/plain.conf" list
echo

echo "# package checksums are for remote packages only: local files and file:// repositories skip them"
LC="$T/chk"; rm -rf "$LC"; mkdir -p "$LC/repo" "$LC/other" "$LC/root/etc/tatami"
mkp "$LC/repo" ck-app 1.0 - - usr/share/ck-app/f:original
mkp "$LC/other" ck-app 1.0 - - usr/share/ck-app/f:substituted
publish_index "$LC/repo" >/dev/null
CP="ck-app_1.0_${HARCH}.tar.pkg"
cp "$LC/other/$CP" "$LC/repo/$CP"       # same name and version, other content: the index's SHA-256 is now wrong
printf 'ALLOW_UNSIGNED = yes\n' > "$LC/c.conf"
echo "mine = file://$LC/repo" > "$LC/root/etc/tatami/repos.conf"
check "a file:// repository whose index has a wrong checksum still installs" 0 "$TATAMI" -y -r "$LC/root" -c "$LC/c.conf" install ck-app
[ "$(cat "$LC/root/usr/share/ck-app/f")" = substituted ] && ok "the local file was used as it is, no hash check" || bad "unexpected content" "$(cat "$LC/root/usr/share/ck-app/f")"
"$TATAMI" -y -r "$LC/root" -c "$LC/c.conf" remove ck-app >/dev/null 2>&1
check "so does a package file given by path" 0 "$TATAMI" -y -r "$LC/root" -c "$LC/c.conf" install "$LC/repo/$CP"
"$TATAMI" -y -r "$LC/root" -c "$LC/c.conf" remove ck-app >/dev/null 2>&1
echo "mine = $LC/repo" > "$LC/root/etc/tatami/repos.conf"
check "and a plain path repository" 0 "$TATAMI" -y -r "$LC/root" -c "$LC/c.conf" install ck-app
echo

echo "# remote repositories: local ones never use FETCHCMD"
rm -rf "$RR"; mkdir -p "$RR/etc/tatami" "$T/loc-repo"
mkp "$T/loc-repo" lc-app 1.0 - - usr/share/lc-app/f:app
: > "$FLOG"
printf 'FETCHCMD = sh -c '"'"'echo called >> "$FLOG"; exit 1'"'"' %%URL%% %%DEST%%\n' > "$T/loc.conf"
lr() { "$TATAMI" -r "$RR" -c "$T/loc.conf" "$@"; }
echo "mine = $T/loc-repo" > "$RR/etc/tatami/repos.conf"
check "update of a local path repository" 0 lr update
check "install from a local path repository" 0 lr -y install lc-app
lr -y remove lc-app >/dev/null 2>&1
echo "mine = file://$T/loc-repo" > "$RR/etc/tatami/repos.conf"
check "install from a file:// repository" 0 lr -y install lc-app
lr -y remove lc-app >/dev/null 2>&1
rm "$RR/etc/tatami/repos.conf"; echo "" > "$RR/etc/tatami/repos.conf"
mkdir -p "$RR/var/lib/tatami/packages"; cp "$T/loc-repo/"lc-app_* "$RR/var/lib/tatami/packages/"
check "empty repos.conf: default <root>/var/lib/tatami/packages" 0 lr -y install lc-app
lr -y remove lc-app >/dev/null 2>&1
rm "$RR/etc/tatami/repos.conf"
check "no repos.conf at all: default repository" 0 lr -y install lc-app
[ -f "$RR/usr/share/lc-app/f" ] && ok "installed offline" || bad "not installed"
[ ! -s "$FLOG" ] && ok "FETCHCMD was never started for a local repository" || bad "FETCHCMD ran" "$(cat "$FLOG")"
[ ! -e "$RR/var/cache/tatami/packages" ] && ok "no package cache for local repositories" || bad "cache created"
echo

echo "# sensible defaults: nothing configured at all"
DF="$T/defaults"; rm -rf "$DF"; mkdir -p "$DF/recipe" "$DF/out" "$DF/root"
printf 'name=dflt\nversion=1.0\narch='$HARCH'\nbuild() { mkdir -p "$PKG/usr/bin"; echo hi > "$PKG/usr/bin/dflt"; }\n' > "$DF/recipe/Tatamifile"
# no config file (-c points nowhere): the build-time extension and compression
( cd "$DF/recipe" && mk -o "$DF/out" ) >"$DF/mk.log" 2>&1
[ -f "$DF/out/dflt_1.0_$HARCH.tar.pkg" ] && ok "default package is <name>_<version>_<arch of the recipe>.tar.pkg" || bad "default package name"
check "tatami reads the unconfigured package" 0 bash -c "'$TATAMI' -r '$DF/root' -c '$DF/none.conf' show '$DF/out/dflt_1.0_$HARCH.tar.pkg' >/dev/null || true"
mkdir -p "$DF/root/etc/tatami"
# default config missing, empty, unreadable -> internal defaults, default repository <root>/var/lib/tatami/packages
mkdir -p "$DF/root/var/lib/tatami/packages"; cp "$DF/out/"* "$DF/root/var/lib/tatami/packages/"
check "no etc/tatami/tatami.conf: update works" 0 "$TATAMI" -r "$DF/root" update
check "no etc/tatami/tatami.conf: install from the default repository" 0 "$TATAMI" -y -r "$DF/root" install dflt
[ -f "$DF/root/usr/bin/dflt" ] && ok "installed with no configuration and no hooks.d" || bad "file not installed"
check "remove with no hooks.d directory" 0 "$TATAMI" -y -r "$DF/root" remove dflt
: > "$DF/root/etc/tatami/tatami.conf"
check "empty etc/tatami/tatami.conf" 0 "$TATAMI" -y -r "$DF/root" install dflt
"$TATAMI" -y -r "$DF/root" remove dflt >/dev/null 2>&1
if [ "$(id -u)" = 0 ]; then
	: # root reads everything: an unreadable file cannot be simulated; a directory in its place instead
	rm -f "$DF/root/etc/tatami/tatami.conf"; mkdir "$DF/root/etc/tatami/tatami.conf"
	check "etc/tatami/tatami.conf is a directory: falls back to defaults" 0 "$TATAMI" -y -r "$DF/root" install dflt
fi
mkdir -p "$DF/root/etc/tatami/hooks.d"
check "empty hooks.d directory" 0 "$TATAMI" -y -r "$DF/root" upgrade
echo

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
