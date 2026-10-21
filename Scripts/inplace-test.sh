#!/bin/bash
# End-to-end test for in-place, build-time obfuscation.
#
# Proves the whole client-invisible round-trip:
#   1. Source files live NORMALLY in the compiled target (no Protected/ relocation, no mirror).
#   2. `stage` obfuscates every class under the named package folder IN PLACE (originals backed up).
#   3. The target compiles + runs the obfuscated form: runtime values are correct, and the compiled
#      binary contains no plaintext (while a control string outside the package remains).
#   4. `restore` returns every source file byte-for-byte, so the working tree is unchanged.
#
# Usage: Scripts/inplace-test.sh
set -euo pipefail

APPVAULT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== building appvault-obfuscate =="
( cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate >/dev/null 2>&1 )
OBF="$(cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate --show-bin-path)/appvault-obfuscate"

echo "== scaffolding a normal consumer package (no relocation) =="
APP="$WORK/Consumer"
mkdir -p "$APP/Sources/Demo/Secure" "$APP/Sources/Demo/Other"

cat > "$APP/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Demo",
    platforms: [.macOS(.v13)],
    dependencies: [ .package(path: "$APPVAULT_DIR") ],
    targets: [ .executableTarget(name: "Demo", dependencies: [ .product(name: "AppVault", package: "AppVault") ]) ]
)
EOF

# A secret-bearing class, living normally inside the compiled target.
cat > "$APP/Sources/Demo/Secure/ApiClient.swift" <<'EOF'
import Foundation
final class ApiClient {
    let baseURL = "https://api.secret-bank.example"
    let apiKey  = "sk-live-9f8e7d6c5b4a"
    enum Route: String { case login = "/login" }               // raw value stays literal
    func describe(_ u: String) -> String { "user \(u)" }        // interpolated -> skipped
}
extension ApiClient {
    func header() -> String { "x-ext-secret-1234" }            // extension literal -> obfuscated
}
EOF

# A file OUTSIDE the named package -- must stay plaintext.
cat > "$APP/Sources/Demo/Other/Flags.swift" <<'EOF'
enum FeatureFlag { static let control = "control-plaintext-visible" }
EOF

cat > "$APP/Sources/Demo/main.swift" <<'EOF'
let c = ApiClient()
print("baseURL=" + c.baseURL)
print("apiKey=" + c.apiKey)
print("route=" + ApiClient.Route.login.rawValue)
print("header=" + c.header())
print("flag=" + FeatureFlag.control)
EOF

# Package config: just name the folder.
cat > "$APP/appvault-classes.yml" <<'EOF'
packages:
  - Sources/Demo/Secure
EOF

# Snapshot pristine sources to verify a byte-for-byte restore later.
PRISTINE="$WORK/pristine"; mkdir -p "$PRISTINE"
cp -R "$APP/Sources" "$PRISTINE/Sources"

echo "== [pre-compile hook] stage: obfuscate the package in place =="
BACKUP="$APP/.build/avbackup"
( cd "$APP" && "$OBF" --stage-config appvault-classes.yml --backup "$BACKUP" )
grep -q '__AppVaultSecrets_ApiClient' "$APP/Sources/Demo/Secure/ApiClient.swift" && ok "package class obfuscated in place" || bad "class not obfuscated"
grep -q 'control-plaintext-visible' "$APP/Sources/Demo/Other/Flags.swift" && ok "file outside the package left untouched" || bad "out-of-package file changed"

echo "== compiling + running the obfuscated form =="
OUT="$(cd "$APP" && swift run 2>/dev/null)"
echo "---- program output ----"; echo "$OUT" | sed 's/^/    /'; echo "------------------------"
check() { echo "$OUT" | grep -qF "$1" && ok "runtime: $1" || bad "runtime missing: $1"; }
check "baseURL=https://api.secret-bank.example"
check "apiKey=sk-live-9f8e7d6c5b4a"
check "route=/login"
check "header=x-ext-secret-1234"
check "flag=control-plaintext-visible"

echo "== scanning the compiled binary for plaintext =="
BIN="$(cd "$APP" && swift build --show-bin-path 2>/dev/null)/Demo"
hidden() { if strings "$BIN" | grep -qF "$1"; then bad "LEAK: '$1' in binary"; else ok "hidden from binary: '$1'"; fi; }
present() { if strings "$BIN" | grep -qF "$1"; then ok "control present: '$1'"; else bad "control absent: '$1'"; fi; }
hidden "https://api.secret-bank.example"
hidden "sk-live-9f8e7d6c5b4a"
hidden "x-ext-secret-1234"
present "control-plaintext-visible"

echo "== [post-compile hook] restore: working tree must be byte-for-byte unchanged =="
( cd "$APP" && "$OBF" --restore "$BACKUP" )
if diff -r "$PRISTINE/Sources" "$APP/Sources" >/dev/null 2>&1; then
  ok "every source file restored byte-for-byte (client sees no change)"
else
  bad "source tree differs after restore"; diff -r "$PRISTINE/Sources" "$APP/Sources" || true
fi
[ -d "$BACKUP" ] && bad "backup dir not cleaned up" || ok "backup dir cleaned up"

echo
echo "== SUMMARY: $pass passed, $fail failed =="
[ "$fail" = "0" ]
