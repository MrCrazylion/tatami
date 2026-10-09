#!/bin/bash
# End-to-end tests: builds packages with tatamk into a scratch repository and
# drives tatami against a scratch root. Needs root (like tatami itself) and
# is run with: make check
cd "$(dirname "$0")/.." || exit 1
export TATAMI="$PWD/tatami"   # tatamk builds packages through the tatami binary
TATAMK="$PWD/tatamk"
T="$PWD/tests/work"
ROOT="$T/root"
REPO="$T/repo"
CONF="$T/tatami.conf"
EXT="tpkg"             # a user-chosen extension, different from the default tar.<compression>
HARCH=$(uname -m)      # packages built here carry the host architecture in their name

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; [ -n "$2" ] && echo "$2" | sed 's/^/       /'; }

t() { "$TATAMI" -r "$ROOT" -c "$CONF" "$@"; }
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
${arch:+arch=$arch}
build() {
	mkdir -p \$PKG/usr/share/$name
	echo "$name $version" > \$PKG/usr/share/$name/version$body
}
RECIPE
	"$TATAMK" -c "$CONF" -f "$dir/Tatamifile" -o "$REPO" > "$T/tatamk.log" 2>&1 || { bad "tatamk $name $version" "$(cat "$T/tatamk.log")"; return 1; }
}

rm -rf "$T"
mkdir -p "$T/home"; export HOME="$T/home"      # tatamk looks for a signing key in ~/.tatami
mkdir -p "$ROOT/etc" "$REPO" "$T/recipes"
cat > "$CONF" <<CONFIG
PKG_EXT = $EXT
REPO_DIRS   =   $REPO
PKG_COMPRESSION=  gz
BULKHEAD = no
UPGRADE ^etc/.*\$ NO
CONFIG

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

echo "# tatamk"
mkdir -p "$T/recipes/failing"
cat > "$T/recipes/failing/Tatamifile" <<RECIPE
name=failing
version=1
build() {
	mkdir -p \$PKG/usr/bin
	false
	echo late > \$PKG/usr/bin/failing
}
RECIPE
check "a failing command in build() fails the build" 1 "$TATAMK" -c "$CONF" -f "$T/recipes/failing/Tatamifile" -o "$T/failout"
[ ! -e "$T/failout/failing_1_$HARCH.$EXT" ] && ok "no package produced by failing build" || bad "package produced by failing build"
mkdir -p "$T/recipes/commas"
printf 'name=commas\nversion=1\ndepends=("a, b")\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/commas/Tatamifile"
check "relation containing a comma is refused" 1 "$TATAMK" -c "$CONF" -f "$T/recipes/commas/Tatamifile" -o "$T/failout"
mkdir -p "$T/recipes/dash"
printf 'name=dash\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/-rf; }\n' > "$T/recipes/dash/Tatamifile"
check "file names starting with a dash are packaged" 0 "$TATAMK" -c "$CONF" -f "$T/recipes/dash/Tatamifile" -o "$T/failout"
check "dash file is in the package" 0 tar -tf "$T/failout/dash_1_$HARCH.$EXT"
has "listed" "x/-rf"

echo "# bulkhead (bwrap is mocked: this host cannot create user namespaces)"
MOCK="$T/mockbin"; DEST="$T/destdir"; mkdir -p "$MOCK" "$DEST"
cat > "$MOCK/bwrap" <<'MOCKEOF'
#!/bin/bash
# Mock bubblewrap: verifies the complete argument vector, then behaves as told.
printf '%s\n' "$@" > "$MOCK_LOG"
args=("$@")
fail() { echo "mock bwrap: $1" >&2; exit 97; }
expect() { # expect <index> <value...>: consecutive arguments from <index>
	local i=$1; shift
	for v in "$@"; do
		[ "${args[$i]}" = "$v" ] || fail "argument $i is '${args[$i]}', expected '$v'"
		i=$((i+1))
	done
}
# system read-only, own /dev and /proc, empty /tmp, /home and /root
expect 0 --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /home --tmpfs /root
i=13
# optional read-only re-exposed host paths, only valid after the tmpfs mounts
while [ "${args[$i]}" = --ro-bind ]; do
	[ "${args[$((i+1))]}" = "${args[$((i+2))]}" ] || fail "--ro-bind of '${args[$((i+1))]}' to a different path"
	i=$((i+3))
done
nro=$(( (i-13)/3 ))
expect $i --bind; DESTIDX=$((i+1))
[ -n "$MOCK_ANY_DEST" ] || expect $DESTIDX "$MOCK_DEST"
expect $((i+2)) /tmp/destdir --unshare-net --unshare-pid --die-with-parent --
rest=("${args[@]:$((i+7))}")
[ -n "$MOCK_EXIT" ] && exit "$MOCK_EXIT"
[ -n "$MOCK_KILL" ] && kill -"$MOCK_KILL" $$
if [ -n "$MOCK_EMULATE" ]; then
	# crude stand-in for the mounts, only used when explicitly requested
	ln -sfn "${args[$DESTIDX]}" /tmp/destdir; mkdir -p /tmp/build
	trap 'rm -f /tmp/destdir; rm -rf /tmp/build' EXIT
	"${rest[@]}"; exit $?
fi
exec "${rest[@]}"
MOCKEOF
chmod +x "$MOCK/bwrap"
export MOCK_LOG="$T/bwrap.args" MOCK_DEST="$DEST"
bh() { PATH="$MOCK:$PATH" "$TATAMI" bulkhead "$@"; }

check "mock bwrap accepts the exact argument vector and succeeds" 0 bh "$DEST" -- echo hello
has "the sandboxed command ran" "^hello$"
check "log: ro-bind of the root" 0 grep -qx -- --ro-bind "$MOCK_LOG"
check "log: network unshared" 0 grep -qx -- --unshare-net "$MOCK_LOG"
check "log: pid namespace" 0 grep -qx -- --unshare-pid "$MOCK_LOG"
check "log: dies with parent" 0 grep -qx -- --die-with-parent "$MOCK_LOG"
check "log: destdir mapped to /tmp/destdir" 0 grep -qx -- /tmp/destdir "$MOCK_LOG"
check "log: no separate /build tmpfs" 1 grep -qx -- /build "$MOCK_LOG"
check "log: own /proc (host processes hidden)" 0 grep -qx -- --proc "$MOCK_LOG"
check "log: /home is an empty tmpfs" 0 bash -c "grep -x -A1 -- --tmpfs '$MOCK_LOG' | grep -qx /home"
check "log: /root is an empty tmpfs" 0 bash -c "grep -x -A1 -- --tmpfs '$MOCK_LOG' | grep -qx /root"
check "log: command follows --" 0 bash -c "tail -n 2 '$MOCK_LOG' | tr '\n' ' ' | grep -q 'echo hello'"
mkdir -p "$T/rodir"; echo recipe > "$T/rodir/Tatamifile"
check "--ro paths are accepted and passed as read-only binds" 0 bh --ro "$T/rodir/Tatamifile" --ro "$T/rodir" "$DEST" -- true
check "log: each --ro path is bound to itself (source and target)" 0 bash -c "[ \$(grep -Fxc '$T/rodir/Tatamifile' '$MOCK_LOG') = 2 ] && [ \$(grep -Fxc '$T/rodir' '$MOCK_LOG') = 2 ]"
check "log: --ro binds come after the /home tmpfs" 0 bash -c "tail -n +1 '$MOCK_LOG' | grep -nx -e /home -e '$T/rodir/Tatamifile' | head -2 | cut -d: -f2 | tr '\n' ' ' | grep -qx '/home $T/rodir/Tatamifile '"
"$TATAMI" bulkhead --ro "$T/no-such-path" "$DEST" -- true >/dev/null 2>&1; [ $? -eq 2 ] && ok "--ro with a missing path is a usage error (2)" || bad "missing --ro path"
"$TATAMI" bulkhead --ro >/dev/null 2>&1; [ $? -eq 2 ] && ok "--ro without a value is a usage error (2)" || bad "--ro without value"
check "command arguments pass through unchanged" 0 bh "$DEST" -- bash -c 'echo "a b" "$1"' x 'c d'
has "arguments with spaces intact" "^a b c d$"
MOCK_EXIT=0 bh "$DEST" -- true >/dev/null 2>&1; [ $? -eq 0 ] && ok "mock exiting 0 gives 0" || bad "mock exit 0"
MOCK_EXIT=42 bh "$DEST" -- true >/dev/null 2>&1; rc=$?
[ $rc -eq 42 ] && ok "mock exiting 42 gives exactly 42" || bad "mock exit 42 (got $rc)"
OUT=$(MOCK_KILL=TERM bh "$DEST" -- true 2>&1); rc=$?
[ $rc -eq 143 ] && ok "death by SIGTERM gives 128+15" || bad "signal exit code (got $rc)" "$OUT"
echo "$OUT" | grep -q "terminated by signal 15" && ok "terminating signal is reported" || bad "signal message" "$OUT"
OUT=$(PATH=/nonexistent "$TATAMI" bulkhead "$DEST" -- true 2>&1); rc=$?
[ $rc -eq 255 ] && ok "bwrap not found gives 255" || bad "missing bwrap (got $rc)" "$OUT"
echo "$OUT" | grep -q "could not run bwrap" && ok "launch failure message" || bad "launch message" "$OUT"
printf '#!/bin/sh\n' > "$T/notexec"; mkdir -p "$T/badbin"; cp "$T/notexec" "$T/badbin/bwrap"
OUT=$(PATH="$T/badbin" "$TATAMI" bulkhead "$DEST" -- true 2>&1); rc=$?
[ $rc -eq 255 ] && ok "non-executable bwrap gives 255" || bad "non-executable bwrap (got $rc)" "$OUT"
"$TATAMI" bulkhead "$DEST" true >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing -- is a usage error (2)" || bad "usage error"
"$TATAMI" bulkhead "$DEST" -- >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing command is a usage error (2)" || bad "usage error 2"
OUT=$(bh "$T/no-such-dir" -- true 2>&1); rc=$?
[ $rc -eq 2 ] && ok "missing destdir is a usage error (2)" || bad "missing destdir (got $rc)" "$OUT"

echo "# tatamk with bulkhead"
CONF_BULK="$T/tatami-bulk.conf"; grep -v '^BULKHEAD' "$CONF" > "$CONF_BULK"
mkdir -p "$T/recipes/boxed"
cat > "$T/recipes/boxed/Tatamifile" <<'RECIPE'
name=boxed
version=1
helper() { echo "from helper"; }
build() {
	mkdir -p $PKG/usr/share/boxed
	echo "$PKG $DESTDIR $(helper) $(pwd)" > $PKG/usr/share/boxed/env
}
RECIPE
bk() { TATAMI="$TATAMI" "$TATAMK" -c "$CONF_BULK" -f "$T/recipes/boxed/Tatamifile" -o "$T/boxout" "$@"; }

check "isolated build refuses to run without bwrap" 1 bk
has "error names bwrap" "require bwrap"
has "error names the opt-out" "no-bulkhead"
[ ! -e "$T/boxout/boxed_1_$HARCH.$EXT" ] && ok "no package without bwrap" || bad "package built without bwrap"
check "--no-bulkhead builds without bwrap" 0 bk --no-bulkhead
check "--no-sandbox is an alias" 0 bk --no-sandbox
rm -rf "$T/boxout"
echo "BULKHEAD = no" >> "$CONF_BULK"
check "BULKHEAD = no in the config builds without bwrap" 0 bk
sed -i '/^BULKHEAD/d' "$CONF_BULK"; rm -rf "$T/boxout"
check "--bulkhead overrides BULKHEAD = no" 1 bash -c "echo 'BULKHEAD = no' >> '$CONF_BULK'; TATAMI='$TATAMI' '$TATAMK' -c '$CONF_BULK' -f '$T/recipes/boxed/Tatamifile' -o '$T/boxout' --bulkhead"
sed -i '/^BULKHEAD/d' "$CONF_BULK"
echo "BULKHEAD = maybe" >> "$CONF_BULK"
check "invalid BULKHEAD value is refused by tatamk" 1 bk
check "invalid BULKHEAD value is refused by tatami" 1 "$TATAMI" -c "$CONF_BULK" list
sed -i '/^BULKHEAD/d' "$CONF_BULK"

if [ "$(id -u)" = 0 ] && [ ! -e /tmp/build ] && [ ! -e /tmp/destdir ]; then
	export MOCK_EMULATE=1 MOCK_ANY_DEST=1
	rm -rf "$T/boxout"
	OUT=$(PATH="$MOCK:$PATH" bk 2>&1); rc=$?
	[ $rc -eq 0 ] && ok "build through the (mock) sandbox succeeds" || bad "sandboxed build (rc $rc)" "$OUT"
	tar -xOf "$T/boxout/boxed_1_$HARCH.$EXT" usr/share/boxed/env 2>/dev/null | grep -qx "/tmp/destdir /tmp/destdir from helper /tmp/build/src" \
		&& ok "inside: PKG and DESTDIR are /tmp/destdir, recipe functions work, cwd is /tmp/build/src" \
		|| bad "environment inside the sandbox" "$(tar -xOf "$T/boxout/boxed_1_$HARCH.$EXT" usr/share/boxed/env 2>&1)"
	mkdir -p "$T/recipes/boxfail"
	printf 'name=boxfail\nversion=1\nbuild() { mkdir -p $PKG/x; false; echo hi > $PKG/x/f; }\n' > "$T/recipes/boxfail/Tatamifile"
	OUT=$(PATH="$MOCK:$PATH" TATAMI="$TATAMI" "$TATAMK" -c "$CONF_BULK" -f "$T/recipes/boxfail/Tatamifile" -o "$T/boxout" 2>&1); rc=$?
	[ $rc -ne 0 ] && [ ! -e "$T/boxout/boxfail_1_$HARCH.$EXT" ] && ok "failing build inside the sandbox fails tatamk" || bad "failing sandboxed build" "$OUT"
	unset MOCK_EMULATE MOCK_ANY_DEST
else
	echo "skip - sandboxed tatamk build (needs root and no /tmp/build or /tmp/destdir on this host)"
fi
unset MOCK_LOG MOCK_DEST

echo "# architecture-independent packages"
mkpkg na-noarch 1.0 arch=noarch file=usr/share/na/noarch
mkpkg na-any 1.0 arch=any file=usr/share/na/any
mkpkg na-all 1.0 arch=all file=usr/share/na/all
mkpkg na-mixed 1.0 arch=NoArch file=usr/share/na/mixed
mkpkg na-none 1.0 file=usr/share/na/none
mkpkg na-foreign 1.0 arch=riscv64z file=usr/share/na/foreign
check "noarch, any, all, NoArch and no-arch packages install on this host" 0 ty install na-noarch na-any na-all na-mixed na-none
exists "noarch installed" usr/share/na/noarch
exists "any installed" usr/share/na/any
exists "all installed" usr/share/na/all
exists "mixed-case NoArch installed" usr/share/na/mixed
exists "package without arch installed" usr/share/na/none
check "a package for another architecture is still refused" 1 ty install na-foreign
has "with the architecture message" "incompatible with this system"
absent "foreign package not installed" usr/share/na/foreign
check "noarch also installs from a file argument" 0 ty install "$REPO/na-any_1.0-1_noarch.$EXT"
check "noarch installs when the host architecture is unknown to libsolv" 0 bash -c "echo 'ARCH = zz80' > '$T/zz.conf'; cat '$CONF' >> '$T/zz.conf'; '$TATAMI' -r '$ROOT' -c '$T/zz.conf' -s install na-noarch"

echo "# package names: <name>_<version>-<release>_<arch>.tar.<compression>, or a fixed extension"
DEFEXT=$(sed -n 's/^PKG_EXT="\([^"]*\)".*/\1/p' "$TATAMK" | head -1)      # empty unless built with make PKG_EXT=...
[ "$DEFEXT" != "@DEFAULT_PKG_EXT@" ] && ok "the build-time extension was substituted in tatamk (${DEFEXT:-automatic})" || bad "default extension not substituted in tatamk" "$DEFEXT"
[ "$DEFEXT" != "$EXT" ] && ok "the suite's configured extension differs from the build default" || bad "test extension equals the default"
EXPECT="${DEFEXT:-tar.zst}"
mkdir -p "$T/extrepo" "$T/recipes/ext1"
printf 'name=ext1\nversion=1\nrelease=3\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext1/Tatamifile"
printf 'REPO_DIRS = %s\nBULKHEAD = no\n' "$T/extrepo" > "$T/noext.conf"
check "tatamk without PKG_EXT in the config names the package by the default" 0 "$TATAMK" -c "$T/noext.conf" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext1_1-3_${HARCH}.$EXPECT" ] && ok "package is named ext1_1-3_${HARCH}.$EXPECT" || bad "default-named package missing" "$(ls "$T/extrepo")"
check "tatami without PKG_EXT in the config recognises that name" 0 "$TATAMI" -r "$ROOT" -c "$T/noext.conf" index "$T/extrepo"
has "tatami found the default-named package" "1 package"
hasnt "no naming warning" "named differently"
if [ -z "$DEFEXT" ]; then
	for c in xz gz bz2 lz4 lzma; do
		check "tatamk -z $c names the package tar.$c" 0 "$TATAMK" -z $c -c "$T/noext.conf" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
		[ -f "$T/extrepo/ext1_1-3_${HARCH}.tar.$c" ] && ok "ext1_1-3_${HARCH}.tar.$c exists" || bad "tar.$c package missing" "$(ls "$T/extrepo")"
	done
	check "tatamk -z none names it .tar" 0 "$TATAMK" -z none -c "$T/noext.conf" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	[ -f "$T/extrepo/ext1_1-3_${HARCH}.tar" ] && ok "uncompressed package is ext1_1-3_${HARCH}.tar" || bad "plain tar package missing"
	check "tatamk refuses an unknown compression" 1 "$TATAMK" -z rot13 -c "$T/noext.conf" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
	check "tatami indexes every tar.<compression> in one repository" 0 "$TATAMI" -r "$ROOT" -c "$T/noext.conf" index "$T/extrepo"
	has "the same package in several formats is indexed once" "Indexed 1 package "
	has "and the extra copies are reported" "ext1 1-3 is already in the repository"
fi
OUT=$(PKG_EXT=envext "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo" 2>&1); [ -f "$T/extrepo/ext1_1-3_${HARCH}.envext" ] && ok "PKG_EXT in the environment overrides the config (and the default)" || bad "environment override" "$OUT"
OUT=$(PKG_EXT=.dotext "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo" 2>&1); [ -f "$T/extrepo/ext1_1-3_${HARCH}.dotext" ] && ok "a leading dot in the environment value is ignored" || bad "leading dot" "$OUT"
check "an invalid extension in the environment is refused" 1 env 'PKG_EXT=a/b' "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
check "the config beats the build-time default" 0 "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext1_1-3_${HARCH}.$EXT" ] && ok "config extension $EXT used" || bad "config extension not used" "$(ls "$T/extrepo")"
# the architecture is part of the name, and an underscore inside it (x86_64) does not confuse the parser
mkdir -p "$T/recipes/ext2"
printf 'name=ext-two\nversion=2.5\nrelease=1\narch=x86_64\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext2/Tatamifile"
check "build a package for x86_64 (hyphenated name, underscore in the arch)" 0 "$TATAMK" -c "$T/noext.conf" -f "$T/recipes/ext2/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext-two_2.5-1_x86_64.$EXPECT" ] && ok "named ext-two_2.5-1_x86_64.$EXPECT" || bad "x86_64 package name" "$(ls "$T/extrepo")"
check "tatami parses it back without a naming warning" 0 "$TATAMI" -r "$ROOT" -c "$T/noext.conf" index "$T/extrepo"
hasnt "no warning for a name whose arch contains an underscore" "named differently"
printf 'name=ext3\nversion=1\narch=NoArch\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext2/Tatamifile"
check "arch in any case: NoArch is written noarch" 0 "$TATAMK" -c "$T/noext.conf" -f "$T/recipes/ext2/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext3_1_noarch.$EXPECT" ] && ok "named ext3_1_noarch.$EXPECT" || bad "noarch name" "$(ls "$T/extrepo")"
rm -rf "$T/extrepo"

echo "# compression formats: all read and written natively, no external program"
for comp in gz zst xz bz2 lz4 lzma; do
	mkdir -p "$T/comp-$comp/recipe" "$T/comp-$comp/repo" "$T/comp-$comp/root/etc"
	printf 'name=cmp-%s\nversion=1\nbuild() { mkdir -p $PKG/usr/share/cmp; echo "compressed with %s" > $PKG/usr/share/cmp/%s; }\n' "$comp" "$comp" "$comp" > "$T/comp-$comp/recipe/Tatamifile"
	printf 'PKG_EXT = %s\nPKG_COMPRESSION = %s\nREPO_DIRS = %s\nBULKHEAD = no\n' "$EXT" "$comp" "$T/comp-$comp/repo" > "$T/comp-$comp/conf"
	check "tatamk builds a $comp package" 0 "$TATAMK" -c "$T/comp-$comp/conf" -f "$T/comp-$comp/recipe/Tatamifile" -o "$T/comp-$comp/repo"
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
ROOT="$T/root-cfg"; rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
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
TCONF="$T/mk.conf"; printf 'PKG_COMPRESSION = gz\nBULKHEAD = no\n' > "$TCONF"
mkp() {
	local repo="$1" name="$2" version="$3" arch="$4" deps="$5"; shift 5
	local dir="$T/recipes-x/$name-$version-$RANDOM" body="" f
	mkdir -p "$dir" "$repo"
	for f in "$@"; do
		body="$body"$'\n\t'"mkdir -p \$PKG/$(dirname "${f%%:*}"); printf '%s\\n' '${f#*:}' > \$PKG/${f%%:*}"
	done
	{
		echo "name=$name"; echo "version=$version"
		[ "$arch" != - ] && echo "arch=$arch"
		[ "$deps" != - ] && echo "depends=($deps)"
		echo "build() {$body"; echo "}"
	} > "$dir/Tatamifile"
	"$TATAMK" -c "$TCONF" -f "$dir/Tatamifile" -o "$repo" > "$dir/log" 2>&1 || bad "tatamk $name $version" "$(cat "$dir/log")"
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
printf 'REPO_DIRS = %s\nBULKHEAD = no\n' "$RP/a" > "$RP/a.conf"
ROOT_MAIN="$ROOT"; ROOT="$RP/root"
tr() { "$TATAMI" -r "$ROOT" -c "$RP/$1.conf" "${@:2}"; }
check "tatami index writes repo.solv into the directory" 0 "$TATAMI" index "$RP/a"
has "it reports the packages" "Indexed 2 packages in .*/a/repo.solv"
[ "$(head -c 4 "$RP/a/repo.solv")" = SOLV ] && ok "repo.solv is a libsolv binary repository" || bad "repo.solv is not a SOLV file" "$(head -c 8 "$RP/a/repo.solv" | od -c | head -1)"
check "tatami index of a directory that does not exist fails" 1 "$TATAMI" index "$RP/nowhere"
check "tatami index without an argument fails" 1 "$TATAMI" index
# the index is used as it is when it is not older than the packages: with a garbage package file the
# scanner would skip it, only the index still knows it
cp "$RP/a/repo.solv" "$RP/repo.solv.saved"
rm -f "$RP"/a/rp-two_1.0*; echo garbage > "$RP/a/rp-two_1.0_garbage.tar.gz"; touch -d '2000-01-01' "$RP/a"
check "a fresh repo.solv is trusted (dependencies come from the index)" 0 tr a show rp-one
has "the dependency is known from the index" "^Depends: rp-two >= 1.0"
has "so are file name and size" "^Filename: .*/a/rp-one_1.0_"
check "the index knows the dependency package too" 0 tr a show rp-two
check "installing fails cleanly when the indexed file is not what it claims" 1 tr a -y install rp-one
hasnt "and nothing was half-installed" "Installing"
rm -f "$RP/a/rp-two_1.0_garbage.tar.gz"
mkp "$RP/a" rp-two 1.0 - - usr/share/rp-two/f:two
check "re-indexing after the repair" 0 "$TATAMI" index "$RP/a"
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
printf 'REPO_DIRS = %s %s\nBULKHEAD = no\n' "$RP/a" "$RP/b" > "$RP/ab.conf"
printf 'REPO_DIRS = %s %s\nBULKHEAD = no\n' "$RP/b" "$RP/a" > "$RP/ba.conf"
check "update indexes every configured repository" 0 tr ab update
has "first repository" "Indexed [0-9]+ packages? in .*/a/repo.solv"
has "second repository" "Indexed [0-9]+ packages? in .*/b/repo.solv"
check "the same version in two repositories: the first one listed is used" 0 tr ab -y install rp-dup
[ "$(cat "$ROOT/usr/share/rp-dup/f")" = from-a ] && ok "installed from the first repository (a)" || bad "wrong repository used" "$(cat "$ROOT/usr/share/rp-dup/f")"
check "remove it" 0 tr ab -y remove rp-dup
check "with the order reversed" 0 tr ba -y install rp-dup
[ "$(cat "$ROOT/usr/share/rp-dup/f")" = from-b ] && ok "installed from the first repository (b)" || bad "wrong repository used" "$(cat "$ROOT/usr/share/rp-dup/f")"
tr ba -y remove rp-dup >/dev/null 2>&1
printf 'REPO_DIRS = file://%s\nBULKHEAD = no\n' "$RP/b" > "$RP/url.conf"
check "a file:// URL is a repository" 0 tr url show rp-dup
printf 'REPO_DIRS = https://example.invalid/repo\nBULKHEAD = no\n' > "$RP/http.conf"
check "an unfetched remote repository is skipped with a hint" 0 tr http list --available
has "it says to run update" "has not been fetched yet, run 'tatami update'"
printf 'BULKHEAD = no\n' > "$RP/default.conf"
mkdir -p "$ROOT/var/lib/tatami/packages"
mkp "$ROOT/var/lib/tatami/packages" rp-local 1.0 - - usr/share/rp-local/f:local
check "without REPO_DIRS the repository is <root>/var/lib/tatami/packages" 0 tr default -y install rp-local
exists "installed from the default repository inside the root" usr/share/rp-local/f
ROOT="$ROOT_MAIN"

echo "# target architecture: the pool follows the target system, mismatches are refused"
AR="$T/arch"; rm -rf "$AR"; mkdir -p "$AR/repo" "$AR/root/etc"
# the arch goes into the file name, the package name may not contain '_': ar-x86_64 is ar-x8664
for a in riscv64 x86_64 i686 aarch64 noarch; do mkp "$AR/repo" "ar-${a//_/}" 1.0 "$a" - "usr/share/ar-${a//_/}/f:$a"; done
mkp "$AR/repo" ar-needs 1.0 noarch '"ar-aarch64"' usr/share/ar-needs/f:needs
"$TATAMI" index "$AR/repo" >/dev/null 2>&1
ROOT="$AR/root"
arch_try() { # arch-policy package... : install in a fresh root configured for that architecture
	local policy="$1"; shift
	rm -rf "$ROOT"; mkdir -p "$ROOT/etc"
	printf 'ARCH = %s\nREPO_DIRS = %s\nBULKHEAD = no\n' "$policy" "$AR/repo" > "$AR/c.conf"
	OUT=$("$TATAMI" -r "$ROOT" -c "$AR/c.conf" -y install "$@" 2>&1); rc=$?
}
arch_try riscv64 ar-riscv64 ar-noarch; [ $rc -eq 0 ] && ok "a riscv64 target installs riscv64 and noarch packages" || bad "riscv64 target" "$OUT"
exists "riscv64 package installed" usr/share/ar-riscv64/f
arch_try riscv64 ar-aarch64; [ $rc -ne 0 ] && echo "$OUT" | grep -q "incompatible with this system (riscv64)" && ok "a riscv64 target refuses an aarch64 package, naming both" || bad "foreign arch accepted" "$OUT"
arch_try riscv64 ar-x8664; [ $rc -ne 0 ] && ok "and an x86_64 one" || bad "x86_64 accepted on riscv64" "$OUT"
arch_try x86_64 ar-x8664; [ $rc -eq 0 ] && ok "an x86_64 target installs x86_64 packages" || bad "x86_64 target" "$OUT"
arch_try x86_64 ar-i686; [ $rc -ne 0 ] && ok "an x86_64 target does not install i686 packages (no implicit multilib)" || bad "i686 accepted on a plain x86_64 target" "$OUT"
arch_try x86_64:i686 ar-x8664 ar-i686; [ $rc -eq 0 ] && ok "ARCH = x86_64:i686 allows both" || bad "multilib target" "$OUT"
arch_try x86_64:i686 ar-aarch64; [ $rc -ne 0 ] && ok "but still not aarch64" || bad "aarch64 accepted on x86_64:i686" "$OUT"
arch_try "$HARCH" ar-noarch; [ $rc -eq 0 ] && ok "noarch fits any target" || bad "noarch refused" "$OUT"
arch_try riscv64 ar-needs; [ $rc -ne 0 ] && echo "$OUT" | grep -q "ar-aarch64" && ok "a dependency that exists only for another architecture is not found" || bad "wrong-arch dependency accepted" "$OUT"
arch_try aarch64 ar-needs; [ $rc -eq 0 ] && exists "while on aarch64 it resolves" usr/share/ar-aarch64/f || bad "dependency on the right arch" "$OUT"
# tatamk follows the same configuration: its default architecture is the first ARCH entry
mkdir -p "$AR/recipe"; printf 'name=ar-default\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$AR/recipe/Tatamifile"
printf 'ARCH = riscv64:foo\nBULKHEAD = no\nPKG_COMPRESSION = gz\n' > "$AR/mk.conf"
check "tatamk builds for the configured target architecture" 0 "$TATAMK" -c "$AR/mk.conf" -f "$AR/recipe/Tatamifile" -o "$AR/out"
[ -f "$AR/out/ar-default_1_riscv64.tar.gz" ] && ok "ar-default_1_riscv64.tar.gz" || bad "arch in file name" "$(ls "$AR/out")"
check "tatami read the architecture back" 0 "$TATAMI" -c "$AR/mk.conf" files "$AR/out/ar-default_1_riscv64.tar.gz"
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
"$TATAMI" index "$T/iso-repo" >/dev/null 2>&1
printf 'REPO_DIRS = %s\nBULKHEAD = no\n' "$T/iso-repo" > "$T/iso.conf"
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
"$TATAMI" index "$T/iso-repo" >/dev/null 2>&1
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
"$TATAMI" index "$T/iso-repo" >/dev/null 2>&1
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
"$TATAMI" index "$T/hk-repo" >/dev/null 2>&1
printf 'REPO_DIRS = %s\nBULKHEAD = no\n' "$T/hk-repo" > "$T/hk.conf"
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
printf 'name=under_score\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/under_score/Tatamifile"
check "tatamk refuses '_' in a package name" 1 "$TATAMK" -c "$CONF" -f "$T/recipes/under_score/Tatamifile" -o "$T/failout"
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
"$TATAMI" index "$SRVDIR/core" >/dev/null
# the "network": a fetch command that logs and copies from $SRVDIR instead of connecting
cat > "$T/rem.conf" <<'CONF'
PUBKEY = none
BULKHEAD = no
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
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = false %%URL%% %%DEST%%\n' > "$T/rem-fail.conf"
check "update with a failing FETCHCMD only warns" 0 "$TATAMI" -r "$RR" -c "$T/rem-fail.conf" update
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = no-such-fetcher-xyz %%URL%% %%DEST%%\n' > "$T/rem-miss.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/rem-miss.conf" update 2>&1); echo "$OUT" | grep -q "could not run no-such-fetcher-xyz" && ok "missing fetch program is reported" || bad "missing program" "$OUT"
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = curl %%URL%%\n' > "$T/rem-bad.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/rem-bad.conf" update 2>&1); echo "$OUT" | grep -q "must contain %URL% and %DEST%" && ok "FETCHCMD without %DEST% is refused" || bad "bad FETCHCMD" "$OUT"
# the default FETCHCMD is curl -f -L -# "%URL%" -o "%DEST%"
printf 'PUBKEY = none\nBULKHEAD = no\n' > "$T/rem-def.conf"
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
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = %s %%URL%% %%DEST%%\n' "$T/prog-fetch" > "$T/prog.conf"
echo "core = https://mirror.test/core" > "$RR/etc/tatami/repos.conf"; rm -rf "$RR/etc/tatami/repos.d"
cp "$T/good.solv" "$SRVDIR/core/repo.solv" 2>/dev/null || "$TATAMI" index "$SRVDIR/core" >/dev/null
rm -f "$SRVDIR"/core/rm-*_1.0_*; mkp "$SRVDIR/core" rm-app 1.0 - - usr/share/rm-app/f:app; "$TATAMI" index "$SRVDIR/core" >/dev/null
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
echo "$PROGOUT" | grep -q '\[=*>* *\]  *25%' && ok "a native bar is drawn from the parsed percentages (25%)" || bad "no bar at 25%" "$PROGOUT"
echo "$PROGOUT" | grep -q '\[=\{30\}\] 100%' && ok "the bar ends full at 100%" || bad "no full bar" "$PROGOUT"
echo "$PROGOUT" | grep -q '#' && bad "raw curl progress leaked through" "$PROGOUT" || ok "the raw progress text is hidden"
OUT=$("$TATAMI" -r "$RR" -c "$T/prog.conf" update 2>&1)
echo "$OUT" | grep -q '\[=' && bad "a bar was drawn without a terminal" "$OUT" || ok "no bar when stdout is not a terminal"
echo "$OUT" | grep -q '#' && bad "raw text without terminal" "$OUT" || ok "raw progress hidden without a terminal too"
printf '#!/bin/sh\necho "curl: (22) The requested URL returned error: 404" >&2\nexit 22\n' > "$T/fail-fetch"; chmod +x "$T/fail-fetch"
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = %s %%URL%% %%DEST%%\n' "$T/fail-fetch" > "$T/failmsg.conf"
OUT=$("$TATAMI" -r "$RR" -c "$T/failmsg.conf" update 2>&1)
echo "$OUT" | grep -q "exit status 22: curl: (22) The requested URL returned error: 404" && ok "a failing command's last message is in the error" || bad "no failure message" "$OUT"
echo

echo "# signatures: Ed25519, checked for remote repositories and packages only"
SG="$T/sig"; rm -rf "$SG"; mkdir -p "$SG/srv/core" "$SG/root/etc/tatami" "$SG/home"
# the Ed25519ph test vector of RFC 8032 section 7.3 ("abc") pins the crypto itself
printf abc > "$SG/abc"; echo 833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42 > "$SG/rfc.key"; chmod 600 "$SG/rfc.key"
check "tatami sign writes <file>.sig" 0 "$TATAMI" sign "$SG/abc" "$SG/rfc.key"
[ "$(cat "$SG/abc.sig")" = 98a70222f0b8121aa9d30f813d683f809e462b469c7ff87639499bb94e6dae4131f85042463c2a355a2003d062adf5aaa10b8c61e636062aaad11c2a26083406 ] && ok "the signature is the RFC 8032 Ed25519ph vector" || bad "wrong signature" "$(cat "$SG/abc.sig")"
check "keygen makes a key pair in ~/.tatami" 0 env HOME="$SG/home" "$TATAMI" keygen
has "it prints the PUBKEY line" "^PUBKEY = [0-9a-f]{64}$"
PUB=$(sed -n 's/^PUBKEY = //p' <<<"$OUT")
[ "$(stat -c %a "$SG/home/.tatami/privkey")" = 600 ] && [ "$(stat -c %a "$SG/home/.tatami")" = 700 ] && ok "private key is 0600 in a 0700 directory" || bad "key permissions"
[ "$(cat "$SG/home/.tatami/privkey.pub")" = "$PUB" ] && ok "the public key is written next to it" || bad "pub file"
check "keygen does not overwrite a key" 1 env HOME="$SG/home" "$TATAMI" keygen
check "keygen -f replaces it" 0 env HOME="$SG/home" "$TATAMI" keygen -f
PUB=$(sed -n 's/^PUBKEY = //p' <<<"$OUT")
check "sign of a missing file fails" 1 "$TATAMI" sign "$SG/nothing" "$SG/home/.tatami/privkey"
check "sign with a missing key fails" 1 "$TATAMI" sign "$SG/abc" "$SG/nokey"
echo notakey > "$SG/bad.key"; chmod 600 "$SG/bad.key"
check "sign with a malformed key fails" 1 "$TATAMI" sign "$SG/abc" "$SG/bad.key"

# tatamk signs as part of the build: the package, and the refreshed repo.solv
cat > "$SG/Tatamifile" <<'RCP'
name=sg-app
version=1.0
build() { mkdir -p $PKG/usr/share/sg-app; echo signed > $PKG/usr/share/sg-app/f; }
RCP
( cd "$SG" && HOME="$SG/home" "$TATAMK" -c "$TCONF" -f "$SG/Tatamifile" -o "$SG/srv/core" ) > "$SG/mk.log" 2>&1
P="sg-app_1.0_${HARCH}.tar.gz"
[ -f "$SG/srv/core/$P.sig" ] && [ -f "$SG/srv/core/repo.solv" ] && [ -f "$SG/srv/core/repo.solv.sig" ] && ok "tatamk (with ~/.tatami/privkey) left the package, repo.solv and both .sig files" || bad "tatamk did not sign" "$(cat "$SG/mk.log"; ls "$SG/srv/core")"
( cd "$SG" && HOME="$SG/nohome" "$TATAMK" -c "$TCONF" -f "$SG/Tatamifile" -o "$SG/unsigned" ) > "$SG/mk2.log" 2>&1
[ -f "$SG/unsigned/$P" ] && [ ! -e "$SG/unsigned/$P.sig" ] && [ ! -e "$SG/unsigned/repo.solv" ] && ok "without a key tatamk builds as before, unsigned" || bad "unsigned build" "$(cat "$SG/mk2.log")"
( cd "$SG" && HOME="$SG/home" "$TATAMK" --no-sign -c "$TCONF" -f "$SG/Tatamifile" -o "$SG/nosign" ) > "$SG/mk3.log" 2>&1
[ -f "$SG/nosign/$P" ] && [ ! -e "$SG/nosign/$P.sig" ] && ok "--no-sign" || bad "--no-sign" "$(cat "$SG/mk3.log")"
( cd "$SG" && TATAMI_PRIVKEY="$SG/missing" "$TATAMK" -c "$TCONF" -f "$SG/Tatamifile" -o "$SG/x" ) > "$SG/mk4.log" 2>&1 && bad "a missing TATAMI_PRIVKEY was ignored" || ok "TATAMI_PRIVKEY that does not exist is an error"

# remote repository with PUBKEY: everything fetched is verified
echo "PUBKEY = $PUB" > "$SG/ok.conf"
cat >> "$SG/ok.conf" <<'CONF'
BULKHEAD = no
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
echo "PUBKEY = $(sed -n 's/^PUBKEY = //p' <<<"$(HOME="$SG/home2" "$TATAMI" keygen)")" > "$SG/other.conf"; sed 1d "$SG/ok.conf" >> "$SG/other.conf"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/other.conf" update 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "update aborts when the index is signed with another key" || bad "wrong key accepted (exit $rc)" "$OUT"
cp "$SG/root/var/lib/tatami/repos/core/repo.solv" "$SG/good.solv"
cp "$SG/srv/core/$P" "$SG/pkg.good"
printf 'tampered' >> "$SG/srv/core/$P"
rm -rf "$SG/root/var/cache"
# 1. the package was swapped on the server but the (signed) index still promises the original
OUT=$(sr -y install sg-app 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "CHECKSUM MISMATCH" && ok "a package that differs from the checksum in the index is refused" || bad "substituted package accepted (exit $rc)" "$OUT"
[ ! -e "$SG/root/usr/share/sg-app/f" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami/packages" 2>/dev/null)" ] && ok "nothing installed, the download (.part) was deleted" || bad "tampered data survived" "$(ls -A "$SG/root/var/cache/tatami/packages")"
# 2. the index was re-signed to match, but the package's own .sig no longer fits
"$TATAMI" index "$SG/srv/core" >/dev/null; "$TATAMI" sign "$SG/srv/core/repo.solv" "$SG/home/.tatami/privkey" >/dev/null
check "the client takes the re-signed index" 0 sr update
OUT=$(sr -y install sg-app 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "SIGNATURE VERIFICATION FAILED" && ok "a tampered package is refused by its signature" || bad "tampered package accepted (exit $rc)" "$OUT"
[ ! -e "$SG/root/usr/share/sg-app/f" ] && [ -z "$(ls -A "$SG/root/var/cache/tatami/packages" 2>/dev/null)" ] && ok "nothing installed, nothing left in the cache" || bad "tampered data survived" "$(ls -A "$SG/root/var/cache/tatami/packages")"
cp "$SG/pkg.good" "$SG/srv/core/$P"
"$TATAMI" index "$SG/srv/core" >/dev/null; "$TATAMI" sign "$SG/srv/core/repo.solv" "$SG/home/.tatami/privkey" >/dev/null
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

# no key configured: remote data is refused unless PUBKEY = none
sed 1d "$SG/ok.conf" > "$SG/nokey.conf"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/nokey.conf" update 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$OUT" | grep -q "PUBKEY is not set" && ok "a remote repository without PUBKEY is refused" || bad "unauthenticated update (exit $rc)" "$OUT"
OUT=$("$TATAMI" -r "$SG/root" -c "$SG/nokey.conf" list --available 2>&1); rc=$?
echo "$OUT" | grep -q "ignoring repository core: .*PUBKEY is not set" && ! echo "$OUT" | grep -q "sg-app" && ok "its cached index is ignored too, not used unauthenticated" || bad "cache used without a key (exit $rc)" "$OUT"
printf 'PUBKEY = garbage\n' > "$SG/badkey.conf"
check "an invalid PUBKEY is a configuration error" 1 "$TATAMI" -r "$SG/root" -c "$SG/badkey.conf" list
BASE64=$(python3 -c "import base64,sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())" "$PUB")
{ echo "PUBKEY = $BASE64"; sed 1d "$SG/ok.conf"; } > "$SG/b64.conf"
check "PUBKEY may be base64" 0 "$TATAMI" -r "$SG/root" -c "$SG/b64.conf" update

# local installations are trusted: no signature, no key, no check
: > "$FLOG"
check "a package file is installed without any signature" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/nokey.conf" install "$SG/unsigned/$P"
[ -f "$SG/root/usr/share/sg-app/f" ] && ok "installed from a local file" || bad "local file not installed"
"$TATAMI" -y -r "$SG/root" -c "$SG/nokey.conf" remove sg-app >/dev/null 2>&1
echo "mine = file://$SG/unsigned" > "$SG/root/etc/tatami/repos.conf"
"$TATAMI" -r "$SG/root" -c "$SG/nokey.conf" update >/dev/null 2>&1
check "a file:// repository needs no signature and no PUBKEY" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/nokey.conf" install sg-app
echo "mine = $SG/unsigned" > "$SG/root/etc/tatami/repos.conf"
"$TATAMI" -y -r "$SG/root" -c "$SG/nokey.conf" remove sg-app >/dev/null 2>&1
check "neither does a plain path repository" 0 "$TATAMI" -y -r "$SG/root" -c "$SG/other.conf" install sg-app
[ ! -s "$FLOG" ] && ok "no fetch for local repositories" || bad "fetched" "$(cat "$FLOG")"
echo

echo "# HoldPkg: held packages are not upgraded, the others are"
HP="$T/hold"; rm -rf "$HP"; mkdir -p "$HP/srv/core" "$HP/root/etc/tatami"
SRVDIR="$HP/srv"; FLOG="$HP/fetch.log"; export SRVDIR FLOG; : > "$FLOG"
echo "core = https://mirror.test/core" > "$HP/root/etc/tatami/repos.conf"
printf 'PUBKEY = none\nBULKHEAD = no\nFETCHCMD = sh -c '"'"'cp "$SRVDIR/${0#https://mirror.test/}" "$1"'"'"' %%URL%% %%DEST%%\n' > "$HP/plain.conf"
{ cat "$HP/plain.conf"; echo "HoldPkg = hp-held"; } > "$HP/hold.conf"
hr() { "$TATAMI" -r "$HP/root" -c "$1" "${@:2}"; }
mkp "$HP/srv/core" hp-held 1.0 - - usr/share/hp-held/f:one
mkp "$HP/srv/core" hp-free 1.0 - - usr/share/hp-free/f:one
mkp "$HP/srv/core" hp-dep 1.0 - - usr/share/hp-dep/f:one
"$TATAMI" index "$HP/srv/core" >/dev/null
check "update" 0 hr "$HP/plain.conf" update
check "install the three packages" 0 hr "$HP/plain.conf" -y install hp-held hp-free hp-dep
mkp "$HP/srv/core" hp-held 2.0 - - usr/share/hp-held/f:two
mkp "$HP/srv/core" hp-free 2.0 - - usr/share/hp-free/f:two
"$TATAMI" index "$HP/srv/core" >/dev/null
check "update fetches the new index" 0 hr "$HP/plain.conf" update
OUT=$(hr "$HP/hold.conf" -y upgrade 2>&1); rc=$?
[ $rc -eq 0 ] && ok "the upgrade with HoldPkg works" || bad "upgrade failed ($rc)" "$OUT"
has "the held package is reported" "Skipping upgrade for held package: hp-held \(1.0 -> 2.0\)"
[ "$(cat "$HP/root/usr/share/hp-held/f")" = one ] && ok "hp-held stays at version 1.0" || bad "held package changed" "$(cat "$HP/root/usr/share/hp-held/f")"
[ "$(cat "$HP/root/usr/share/hp-free/f")" = two ] && ok "hp-free, not held, was upgraded to 2.0" || bad "free package not upgraded"
hr "$HP/hold.conf" list 2>&1 | grep -q "^hp-held/1.0" && ok "the database still has hp-held 1.0" || bad "database"
OUT=$(hr "$HP/hold.conf" -y upgrade 2>&1)
has "a second upgrade has nothing to do" "Nothing to do"
has "and still says why" "Skipping upgrade for held package: hp-held"
# an explicit request wins over the hold
check "naming the held package in install upgrades it" 0 hr "$HP/hold.conf" -y install hp-held
[ "$(cat "$HP/root/usr/share/hp-held/f")" = two ] && ok "explicitly requested: upgraded despite HoldPkg" || bad "explicit install blocked"
# several names, several lines, a package that is not installed
mkp "$HP/srv/core" hp-held 3.0 - - usr/share/hp-held/f:three
mkp "$HP/srv/core" hp-free 3.0 - - usr/share/hp-free/f:three
"$TATAMI" index "$HP/srv/core" >/dev/null; hr "$HP/plain.conf" update >/dev/null
{ cat "$HP/plain.conf"; echo "HoldPkg = hp-dep not-installed-anywhere"; echo "HoldPkg = hp-held"; } > "$HP/hold2.conf"
check "HoldPkg with several names on several lines" 0 hr "$HP/hold2.conf" -y upgrade
[ "$(cat "$HP/root/usr/share/hp-held/f")" = two ] && [ "$(cat "$HP/root/usr/share/hp-free/f")" = three ] && ok "hp-held held (two), hp-free upgraded (three)" || bad "multi-line hold" "$(cat "$HP/root/usr/share/hp-held/f") $(cat "$HP/root/usr/share/hp-free/f")"
# without HoldPkg everything is upgraded
check "no HoldPkg: the same upgrade takes everything" 0 hr "$HP/plain.conf" -y upgrade
[ "$(cat "$HP/root/usr/share/hp-held/f")" = three ] && ok "hp-held upgraded once it is no longer held" || bad "still held"
echo

echo "# package checksums are for remote packages only: local files and file:// repositories skip them"
LC="$T/chk"; rm -rf "$LC"; mkdir -p "$LC/repo" "$LC/other" "$LC/root/etc/tatami"
mkp "$LC/repo" ck-app 1.0 - - usr/share/ck-app/f:original
mkp "$LC/other" ck-app 1.0 - - usr/share/ck-app/f:substituted
"$TATAMI" index "$LC/repo" >/dev/null
CP="ck-app_1.0_${HARCH}.tar.gz"
cp "$LC/other/$CP" "$LC/repo/$CP"       # same name and version, other content: the index's SHA-256 is now wrong
printf 'BULKHEAD = no\nPUBKEY = none\n' > "$LC/c.conf"
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
printf 'BULKHEAD = no\nFETCHCMD = sh -c '"'"'echo called >> "$FLOG"; exit 1'"'"' %%URL%% %%DEST%%\n' > "$T/loc.conf"
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
printf 'name=dflt\nversion=1.0\nbuild() { mkdir -p "$PKG/usr/bin"; echo hi > "$PKG/usr/bin/dflt"; }\n' > "$DF/recipe/Tatamifile"
# no config file (-c points nowhere), no PKG_EXT, no compression, no arch in the recipe
( cd "$DF/recipe" && env -u PKG_EXT "$TATAMK" -c "$DF/none.conf" --no-bulkhead -o "$DF/out" ) >"$DF/mk.log" 2>&1
[ -f "$DF/out/dflt_1.0_$HARCH.tar.zst" ] && ok "default package is <name>_<version>_<uname -m>.tar.zst" || bad "default package name"
check "tatami reads the unconfigured package" 0 bash -c "'$TATAMI' -r '$DF/root' -c '$DF/none.conf' show '$DF/out/dflt_1.0_$HARCH.tar.zst' >/dev/null || true"
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
