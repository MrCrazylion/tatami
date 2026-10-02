#!/bin/bash
# Root privilege enforcement: a non-root user must not be able to run a
# mutating command, but must be able to run read-only ones.
#
#   A. ./tatami install dummy   as a non-root user  -> must FAIL (non-zero)
#   B. ./tatami --help          as a non-root user  -> must SUCCEED (exit 0)
#
# Needs to be run as root (it drops privileges with su). It only reads the
# binary; override its location with TATAMI_BIN=/path/to/tatami.
#
# The binary is copied to a temporary world-readable directory first, because
# the unprivileged user usually cannot traverse the directory the project
# lives in (e.g. /root is mode 0700), which would make both scenarios fail
# for the wrong reason. The copy is removed on exit.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TATAMI_BIN="${TATAMI_BIN:-$REPO/tatami}"
RUN_AS="${RUN_AS:-nobody}"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; [ -n "$2" ] && echo "$2" | sed 's/^/       /'; }

if [ "$(id -u)" -ne 0 ]; then
	echo "error: run this script as root (it needs su to become '$RUN_AS')" >&2
	exit 2
fi
if [ ! -x "$TATAMI_BIN" ]; then
	echo "error: $TATAMI_BIN not found or not executable; build it first (make) or set TATAMI_BIN" >&2
	exit 2
fi
if ! id "$RUN_AS" >/dev/null 2>&1; then
	echo "error: user '$RUN_AS' does not exist" >&2
	exit 2
fi

STAGE="$(mktemp -d)" || exit 2
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"
cp "$TATAMI_BIN" "$STAGE/tatami" && chmod 755 "$STAGE/tatami" || { echo "error: could not stage the binary" >&2; exit 2; }

# Run a command line as the unprivileged user; exit status and output are kept
# in $rc and $OUT. A scratch root (-r) is used so nothing can touch the system.
as_user() {
	OUT=$(su -s /bin/sh "$RUN_AS" -c "$1" 2>&1); rc=$?
}

echo "# sanity: the test really runs without root"
as_user 'id -u'
if [ "$rc" -eq 0 ] && [ "$OUT" != "0" ] && [ -n "$OUT" ]; then
	ok "commands run as '$RUN_AS' (uid $OUT)"
else
	bad "could not drop privileges to '$RUN_AS' (rc $rc)" "$OUT"
fi

echo "# scenario A: mutating command as non-root must fail"
as_user "$STAGE/tatami -y install dummy"
if [ "$rc" -ne 0 ]; then
	ok "tatami install dummy exits non-zero (exit $rc)"
else
	bad "tatami install dummy succeeded as non-root" "$OUT"
fi
# A failure for the wrong reason (missing binary, no permission to execute it)
# must not count as "enforcement works".
if echo "$OUT" | grep -q "only root can run 'install'"; then
	ok "it is refused because of the privilege check"
else
	bad "refusal does not come from the root check" "$OUT"
fi

echo "# scenario B: read-only command as non-root must succeed"
as_user "$STAGE/tatami --help"
if [ "$rc" -eq 0 ]; then
	ok "tatami --help exits 0"
else
	bad "tatami --help failed as non-root (exit $rc)" "$OUT"
fi
if echo "$OUT" | grep -q "^usage: tatami"; then
	ok "it prints the usage text"
else
	bad "no usage text in the output" "$OUT"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
