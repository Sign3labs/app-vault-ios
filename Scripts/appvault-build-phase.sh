#!/bin/bash
# Xcode "Run Script" build phase (or CI step) for class-scoped obfuscation.
#
# Add a Run Script phase to your app target, placed BEFORE "Compile Sources", with:
#     APPVAULT_DIR="$SRCROOT/path/to/AppVault" "${APPVAULT_DIR}/Scripts/appvault-build-phase.sh"
#
# Environment:
#   APPVAULT_DIR     path to the AppVault package (required)
#   APPVAULT_CONFIG  path to appvault-classes.yml (default: $SRCROOT/appvault-classes.yml)
set -euo pipefail
: "${APPVAULT_DIR:?set APPVAULT_DIR to the AppVault package directory}"
CONFIG="${APPVAULT_CONFIG:-${SRCROOT:-$PWD}/appvault-classes.yml}"

swift build --package-path "$APPVAULT_DIR" --product appvault-obfuscate -c release >/dev/null
BIN="$(swift build --package-path "$APPVAULT_DIR" --product appvault-obfuscate -c release --show-bin-path)/appvault-obfuscate"
echo "AppVault: class-scoped obfuscation ($CONFIG)"
"$BIN" --config "$CONFIG"
