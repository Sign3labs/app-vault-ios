#!/bin/bash
# CLI contract + hang-guard tests for appvault-obfuscate and appvault-scan.
#
# Covers argument-safety behaviour the in-process unit tests cannot reach (the arg parsers live in
# the executables' main.swift), plus a watchdog-bounded hang guard on pathological inputs.
#
# Usage: Scripts/cli-test.sh
set -uo pipefail

APPVAULT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== building CLIs =="
( cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate --product appvault-scan >/dev/null 2>&1 )
BIN="$(cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate --show-bin-path)"
OBF="$BIN/appvault-obfuscate"
SCAN="$BIN/appvault-scan"

# Run a command with a wall-clock watchdog. Returns the command's rc, or 137 if it was killed.
run_with_timeout() {
  local secs=$1; shift
  "$@" >/dev/null 2>&1 & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

echo "== argument safety =="
printf 'class A { let a = "secret" }\n' > "$WORK/in.swift"
ORIG="$(cat "$WORK/in.swift")"

# --in-place and --output together must be rejected (and must NOT touch the original source).
"$OBF" --class A --in-place --output "$WORK/out.swift" "$WORK/in.swift" >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] && ok "--in-place + --output rejected (exit 2)" || bad "--in-place + --output exit=$rc (expected 2)"
[ "$(cat "$WORK/in.swift")" = "$ORIG" ] && ok "original source untouched after rejected run" || bad "original source was modified"

# A value-taking flag that swallows the next flag must error instead of targeting a bogus class.
"$OBF" --class --in-place "$WORK/in.swift" >/dev/null 2>&1
[ "$?" = "2" ] && ok "--class <flag> rejected (exit 2)" || bad "--class <flag> not rejected"

# A value left off the end of the command must error, not silently no-op.
"$OBF" --class A "$WORK/in.swift" --output >/dev/null 2>&1
[ "$?" = "2" ] && ok "trailing --output with no value rejected (exit 2)" || bad "trailing --output not rejected"

# scan: no class and no wildcard must error.
"$SCAN" "$WORK/in.swift" >/dev/null 2>&1
[ "$?" = "2" ] && ok "scan with no --class rejected (exit 2)" || bad "scan with no --class not rejected"

echo "== scan/obfuscate wildcard parity =="
printf 'class A { let a = "one" }\nclass B { let b = "two" }\n' > "$WORK/multi.swift"
SCAN_OUT="$("$SCAN" --class '*' "$WORK/multi.swift" 2>/dev/null)"
echo "$SCAN_OUT" | grep -q '2 obfuscatable' && ok "scan '*' finds all classes (parity with obfuscate)" || bad "scan '*' did not find all classes"

echo "== --output always writes (even with nothing to obfuscate) =="
"$OBF" --class Missing --output "$WORK/passthrough.swift" "$WORK/in.swift" >/dev/null 2>&1
if [ -f "$WORK/passthrough.swift" ]; then
  ok "--output wrote a file though no literal matched (build step won't hit 'no such file')"
  grep -q 'let a = "secret"' "$WORK/passthrough.swift" && ok "passthrough output is the verbatim source" || bad "passthrough output not verbatim"
else
  bad "--output wrote no file when nothing matched"
fi

echo "== mirror mode warns on a missing/empty source path =="
mkdir -p "$WORK/emptygen"
cat > "$WORK/classes.yml" <<YML
sources:
  - $WORK/does-not-exist
output: $WORK/emptygen
classes:
  - A
YML
WARN="$("$OBF" --config "$WORK/classes.yml" 2>&1 >/dev/null)"
echo "$WARN" | grep -qi "no .swift files" && ok "missing source path emits a warning" || bad "no warning for missing source path"

echo "== hang guard (watchdog-bounded) =="
# 1) Blank-line-heavy file: the old \s* import regex was O(N^2) and hung here.
{ printf 'class A { let x = "s" }\n'; for _ in $(seq 1 200000); do printf '\n'; done; } > "$WORK/blank.swift"
run_with_timeout 20 "$OBF" --class A --output "$WORK/blank.out.swift" "$WORK/blank.swift"
rc=$?
if [ "$rc" = "137" ]; then bad "blank-line-heavy file hung (killed by 20s watchdog)"
elif [ -f "$WORK/blank.out.swift" ]; then ok "blank-line-heavy file processed under watchdog"
else bad "blank-line-heavy file: no output (rc=$rc)"; fi

# 2) One ~1 MB string literal.
python3 -c "open('$WORK/big.swift','w').write('class A { let s = \"' + 'x'*1000000 + '\" }\n')"
run_with_timeout 20 "$OBF" --class A --output "$WORK/big.out.swift" "$WORK/big.swift"
rc=$?
if [ "$rc" = "137" ]; then bad "1 MB string literal hung (killed by 20s watchdog)"
elif [ -f "$WORK/big.out.swift" ]; then ok "1 MB string literal processed under watchdog"
else bad "1 MB string literal: no output (rc=$rc)"; fi

# 3) Broken / malformed source must not hang or crash the CLI.
printf 'class A { let x = "ok" ; func f( {{{ let y = "also"\n' > "$WORK/broken.swift"
run_with_timeout 20 "$OBF" --class A --output "$WORK/broken.out.swift" "$WORK/broken.swift"
[ "$?" != "137" ] && ok "malformed source did not hang" || bad "malformed source hung"

echo
echo "== SUMMARY: $pass passed, $fail failed =="
[ "$fail" = "0" ]
