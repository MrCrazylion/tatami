#!/bin/bash
# End-to-end tests: builds packages with tatamk into a scratch repository and
# drives tatami against a scratch root. Needs root (like tatami itself) and
# is run with: make check
cd "$(dirname "$0")/.." || exit 1
TATAMI="$PWD/tatami"
TATAMK="$PWD/tatamk"
T="$PWD/tests/work"
ROOT="$T/root"
REPO="$T/repo"
CONF="$T/tatami.conf"
EXT="tpkg"             # a user-chosen extension, different from the build-time default

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
[ -f "$REPO/libfoo_1.0-1.$EXT" ] && ok "package built with custom extension .$EXT" || bad "package file name" "$(ls "$REPO")"
tar -tf "$REPO/libfoo_1.0-1.$EXT" | head -1 | grep -qx .META && ok ".META is the first member" || bad ".META first"

echo "# update / search"
check "simulated update writes nothing" 0 t -s update
absent "no index from -s update" var/lib/tatami/index
check "dependencies resolve without a prior update (index built on demand)" 0 t -s install app
has "on-demand index finds libfoo" "libfoo \(1.0-1\)"
absent "simulate writes no index" var/lib/tatami/index
check "update" 0 t update
has "update counts packages" "10 packages available"
check "search by name" 0 t search '^lib'
has "search finds libfoo" "libfoo/1.0-1"
check "search by description" 0 t search 'test package ed'
has "search description" "^ed/1.0-1"
check "show" 0 t show app
has "show depends" "Depends: libfoo >= 1.0, virtual-editor"
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
exists ".META not extracted" var/lib/tatami/db
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
check "files of a package file" 0 t files "$REPO/libfoo_1.0-1.$EXT"
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

echo "# rejected files (UPGRADE ^etc/ NO)"
mkpkg app 2.0 "depends=libfoo >= 1.0, virtual-editor" file=usr/bin/app file=etc/app.conf
# no explicit update: tatami notices the repository changed
check "upgrade app" 0 ty install app
has "reject message" "rejecting etc/app.conf"
check "locally modified config kept" 0 cat "$ROOT/etc/app.conf"
has "kept content" "locally modified"
exists "new config in rejected dir" var/lib/tatami/rejected/etc/app.conf
check "app binary upgraded" 0 cat "$ROOT/usr/bin/app"
has "new binary" "app 2.0"

echo "# install from a package file"
check "install a file argument" 0 ty install "$REPO/oldname_1.0-1.$EXT"
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
[ ! -e "$T/failout/failing_1.$EXT" ] && ok "no package produced by failing build" || bad "package produced by failing build"
mkdir -p "$T/recipes/commas"
printf 'name=commas\nversion=1\ndepends=("a, b")\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/commas/Tatamifile"
check "relation containing a comma is refused" 1 "$TATAMK" -c "$CONF" -f "$T/recipes/commas/Tatamifile" -o "$T/failout"
mkdir -p "$T/recipes/dash"
printf 'name=dash\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/-rf; }\n' > "$T/recipes/dash/Tatamifile"
check "file names starting with a dash are packaged" 0 "$TATAMK" -c "$CONF" -f "$T/recipes/dash/Tatamifile" -o "$T/failout"
check "dash file is in the package" 0 tar -tf "$T/failout/dash_1.$EXT"
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
[ ! -e "$T/boxout/boxed_1.$EXT" ] && ok "no package without bwrap" || bad "package built without bwrap"
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
	tar -xOf "$T/boxout/boxed_1.$EXT" usr/share/boxed/env 2>/dev/null | grep -qx "/tmp/destdir /tmp/destdir from helper /tmp/build/src" \
		&& ok "inside: PKG and DESTDIR are /tmp/destdir, recipe functions work, cwd is /tmp/build/src" \
		|| bad "environment inside the sandbox" "$(tar -xOf "$T/boxout/boxed_1.$EXT" usr/share/boxed/env 2>&1)"
	mkdir -p "$T/recipes/boxfail"
	printf 'name=boxfail\nversion=1\nbuild() { mkdir -p $PKG/x; false; echo hi > $PKG/x/f; }\n' > "$T/recipes/boxfail/Tatamifile"
	OUT=$(PATH="$MOCK:$PATH" TATAMI="$TATAMI" "$TATAMK" -c "$CONF_BULK" -f "$T/recipes/boxfail/Tatamifile" -o "$T/boxout" 2>&1); rc=$?
	[ $rc -ne 0 ] && [ ! -e "$T/boxout/boxfail_1.$EXT" ] && ok "failing build inside the sandbox fails tatamk" || bad "failing sandboxed build" "$OUT"
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
check "noarch also installs from a file argument" 0 ty install "$REPO/na-any_1.0-1.$EXT"
check "noarch installs when the host architecture is unknown to libsolv" 0 bash -c "echo 'ARCH = zz80' > '$T/zz.conf'; cat '$CONF' >> '$T/zz.conf'; '$TATAMI' -r '$ROOT' -c '$T/zz.conf' -s install na-noarch"

echo "# package extension: build-time default, config, environment"
DEFEXT=$(sed -n 's/^PKG_EXT="\([^"]*\)".*/\1/p' "$TATAMK" | head -1)
[ -n "$DEFEXT" ] && [ "$DEFEXT" != "@DEFAULT_PKG_EXT@" ] && ok "tatamk carries the build-time default extension ($DEFEXT)" || bad "default extension not substituted in tatamk" "$DEFEXT"
[ "$DEFEXT" != "$EXT" ] && ok "the suite's configured extension differs from the default" || bad "test extension equals the default"
mkdir -p "$T/extrepo" "$T/recipes/ext1"
printf 'name=ext1\nversion=1\nbuild() { mkdir -p $PKG/x; echo x > $PKG/x/f; }\n' > "$T/recipes/ext1/Tatamifile"
printf 'REPO_DIRS = %s\nBULKHEAD = no\n' "$T/extrepo" > "$T/noext.conf"
check "tatamk without PKG_EXT in the config uses the build-time default" 0 "$TATAMK" -c "$T/noext.conf" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext1_1.$DEFEXT" ] && ok "package is named ext1_1.$DEFEXT" || bad "default-named package missing" "$(ls "$T/extrepo")"
check "tatami without PKG_EXT in the config indexes the same extension" 0 "$TATAMI" -r "$ROOT" -c "$T/noext.conf" update
has "tatami found the default-named package" "1 package"
OUT=$(PKG_EXT=envext "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo" 2>&1); [ -f "$T/extrepo/ext1_1.envext" ] && ok "PKG_EXT in the environment overrides the config (and the default)" || bad "environment override" "$OUT"
OUT=$(PKG_EXT=.dotext "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo" 2>&1); [ -f "$T/extrepo/ext1_1.dotext" ] && ok "a leading dot in the environment value is ignored" || bad "leading dot" "$OUT"
check "an invalid extension in the environment is refused" 1 env 'PKG_EXT=a/b' "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
check "the config beats the build-time default" 0 "$TATAMK" -c "$CONF" -f "$T/recipes/ext1/Tatamifile" -o "$T/extrepo"
[ -f "$T/extrepo/ext1_1.$EXT" ] && ok "config extension $EXT used" || bad "config extension not used" "$(ls "$T/extrepo")"

echo "# compression formats (libarchive is vendored with zlib and zstd only)"
for comp in gz zst xz bz2; do
	mkdir -p "$T/comp-$comp/recipe" "$T/comp-$comp/repo" "$T/comp-$comp/root/etc"
	printf 'name=cmp-%s\nversion=1\nbuild() { mkdir -p $PKG/usr/share/cmp; echo "compressed with %s" > $PKG/usr/share/cmp/%s; }\n' "$comp" "$comp" "$comp" > "$T/comp-$comp/recipe/Tatamifile"
	printf 'PKG_EXT = %s\nPKG_COMPRESSION = %s\nREPO_DIRS = %s\nBULKHEAD = no\n' "$EXT" "$comp" "$T/comp-$comp/repo" > "$T/comp-$comp/conf"
	check "tatamk builds a $comp package" 0 "$TATAMK" -c "$T/comp-$comp/conf" -f "$T/comp-$comp/recipe/Tatamifile" -o "$T/comp-$comp/repo"
	pkgf="$T/comp-$comp/repo/cmp-${comp}_1.$EXT"
	case "$comp" in gz) magic='1f8b' ;; zst) magic='28b52ffd' ;; xz) magic='fd377a585a00' ;; bz2) magic='425a68' ;; esac
	[ "$(head -c 6 "$pkgf" | od -An -tx1 | tr -d ' \n' | cut -c1-${#magic})" = "$magic" ] && ok "the $comp package really is $comp-compressed" || bad "$comp package has the wrong compression" "$(head -c 6 "$pkgf" | od -An -tx1)"
	check "tatami lists the files of a $comp package" 0 "$TATAMI" -r "$T/comp-$comp/root" -c "$T/comp-$comp/conf" files "$pkgf"
	has "$comp: file list" "usr/share/cmp/$comp"
	check "tatami installs a $comp package" 0 "$TATAMI" -r "$T/comp-$comp/root" -c "$T/comp-$comp/conf" -y install "$pkgf"
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

echo "# file names: <name>_<version>.<ext>"
mkpkg libfoo-dev 2.0 "depends=libfoo >= 1.0" file=usr/include/foo.h
[ -f "$REPO/libfoo-dev_2.0-1.$EXT" ] && ok "name with a hyphen: libfoo-dev_2.0-1.$EXT" || bad "hyphenated package file name" "$(ls "$REPO")"
check "update indexes it under the right name" 0 t update
check "search finds the hyphenated name" 0 t search '^libfoo-dev$'
has "name and version taken apart correctly" "^libfoo-dev/2.0-1"
cp "$REPO/ed_1.0-1.$EXT" "$REPO/renamed_9.9-1.$EXT"
check "update with a misnamed file" 0 t update
has "warns that the name differs from the contents" "renamed_9.9-1.$EXT is named differently from its contents \(ed_1.0-1"
rm -f "$REPO/renamed_9.9-1.$EXT"; t update >/dev/null 2>&1
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
check "write through an escaping symlink is refused" 1 ty install "$T/sym.$EXT"
[ ! -e "$T/outside/pwned" ] && ok "nothing written outside the root via symlink" || bad "file written outside the root via symlink"
check "newline in a member name is refused" 1 ty install "$T/nl.$EXT"
check "package may not overwrite the database" 1 ty install "$T/db.$EXT"
check "empty root argument is refused" 1 "$TATAMI" -r "" list
echo notapackage > "$T/junk.$EXT"
check "garbage is refused" 1 ty install "$T/junk.$EXT"
check "unknown command" 1 t frobnicate
check "unknown option" 1 t --frobnicate list
check "version" 0 "$TATAMI" --version

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
