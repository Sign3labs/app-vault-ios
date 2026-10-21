#!/bin/bash
# End-to-end integration test for the class-scoped obfuscator.
#
# Simulates exactly what a build hook does:
#   1. "Protected" sources live outside the compiled target (originals stay pristine).
#   2. appvault-obfuscate --config mirrors them into a generated dir, obfuscating named classes.
#   3. The build compiles the generated mirror, runs it, and we assert:
#        - the real strings are reconstructed correctly at runtime, and
#        - none of them appear as plaintext in the compiled binary, while a
#          deliberately-non-obfuscated control string does.
#
# Usage: Scripts/integration-test.sh
set -euo pipefail

APPVAULT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "== building appvault-obfuscate =="
OBF="$(cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate --show-bin-path)/appvault-obfuscate"
(cd "$APPVAULT_DIR" && swift build --product appvault-obfuscate >/dev/null 2>&1)

echo "== scaffolding consumer package =="
APP="$WORK/Consumer"
mkdir -p "$APP/Protected" "$APP/Sources/Demo/Generated"

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

# Protected originals -- NOT under Sources/, so SwiftPM never compiles them directly.
cat > "$APP/Protected/ApiClient.swift" <<'EOF'
import Foundation
class ApiClient {
    let baseURL = "https://api.secret-bank.example"
    let apiKey  = "sk-live-9f8e7d6c5b4a"
    func endpoint(_ path: String) -> String { baseURL + "/v2/" + path }  // "/v2/" obfuscated too
    func greeting(_ name: String) -> String { "hello \(name)" }           // interpolated -> skipped
    class Pinner { let spki = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }   // nested -> obfuscated
    enum Route: String { case login = "/login"; case logout = "/logout" }  // raw values MUST stay literal
}
extension ApiClient {
    func authHeader() -> String { "x-ext-secret-9f8e7d6c" }                 // extension literal -> obfuscated
}
EOF

cat > "$APP/Protected/Untracked.swift" <<'EOF'
// A file in Protected with no target class -- must be mirrored verbatim and still compile.
enum FeatureFlag { static let control = "control-plaintext-visible" }
EOF

cat > "$APP/appvault-classes.yml" <<EOF
sources:
  - $APP/Protected
output: $APP/Sources/Demo/Generated
classes:
  - ApiClient
EOF

cat > "$APP/Sources/Demo/main.swift" <<'EOF'
import AppVault
let c = ApiClient()
print("baseURL=" + c.baseURL)
print("apiKey=" + c.apiKey)
print("endpoint=" + c.endpoint("users"))
print("greeting=" + c.greeting("sahil"))
print("spki=" + ApiClient.Pinner().spki)
print("route=" + ApiClient.Route.login.rawValue)
print("header=" + ApiClient().authHeader())
print("flag=" + FeatureFlag.control)
EOF

echo "== [build hook] running mirror obfuscation =="
"$OBF" --config "$APP/appvault-classes.yml"

# The generated mirror must contain BOTH files (one obfuscated, one verbatim).
[ -f "$APP/Sources/Demo/Generated/ApiClient.swift" ] && ok "obfuscated file generated" || bad "obfuscated file missing"
[ -f "$APP/Sources/Demo/Generated/Untracked.swift" ] && ok "passthrough file mirrored" || bad "passthrough file missing"
grep -q '__AppVaultSecrets_ApiClient' "$APP/Sources/Demo/Generated/ApiClient.swift" && ok "literals rewritten to projected values" || bad "no rewrite in generated file"

echo "== [build hook] idempotency: run mirror again =="
"$OBF" --config "$APP/appvault-classes.yml" >/dev/null
NS_COUNT=$(grep -c 'private enum __AppVaultSecrets_ApiClient' "$APP/Sources/Demo/Generated/ApiClient.swift" || true)
[ "$NS_COUNT" = "1" ] && ok "re-running produced exactly one namespace (idempotent)" || bad "namespace count=$NS_COUNT (expected 1)"

echo "== compiling + running the mirror =="
OUT="$(cd "$APP" && swift run 2>/dev/null)"
echo "---- program output ----"; echo "$OUT" | sed 's/^/    /'; echo "------------------------"

check_runtime() { echo "$OUT" | grep -qF "$1" && ok "runtime: $1" || bad "runtime missing: $1"; }
check_runtime "baseURL=https://api.secret-bank.example"
check_runtime "apiKey=sk-live-9f8e7d6c5b4a"
check_runtime "endpoint=https://api.secret-bank.example/v2/users"
check_runtime "greeting=hello sahil"
check_runtime "spki=sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
check_runtime "route=/login"
check_runtime "header=x-ext-secret-9f8e7d6c"
check_runtime "flag=control-plaintext-visible"

echo "== scanning compiled binary for plaintext =="
BIN="$(cd "$APP" && swift build --show-bin-path 2>/dev/null)/Demo"
hidden() { if strings "$BIN" | grep -qF "$1"; then bad "LEAK: '$1' present in binary"; else ok "hidden from binary: '$1'"; fi; }
present() { if strings "$BIN" | grep -qF "$1"; then ok "control present in binary: '$1'"; else bad "control unexpectedly absent: '$1'"; fi; }
hidden "https://api.secret-bank.example"
hidden "sk-live-9f8e7d6c5b4a"
hidden "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
hidden "/v2/"
hidden "x-ext-secret-9f8e7d6c"    # extension literal obfuscated
# interpolated, enum-raw-value, and non-target literals are expected to remain visible:
present "/login"                  # enum raw value stays a literal (and the app compiled with it)
present "control-plaintext-visible"
present "hello "

echo
echo "== SUMMARY: $pass passed, $fail failed =="
[ "$fail" = "0" ]
