#!/bin/bash
# In-place, build-time string obfuscation for an Xcode target.
#
# Add TWO "Run Script" build phases to your app target:
#   1. BEFORE "Compile Sources":   APPVAULT_DIR="$SRCROOT/path/to/AppVault" "${APPVAULT_DIR}/Scripts/appvault-inplace.sh" stage
#   2. as the LAST phase:          APPVAULT_DIR="$SRCROOT/path/to/AppVault" "${APPVAULT_DIR}/Scripts/appvault-inplace.sh" restore
#
# "stage" obfuscates every class under the folders named in appvault-classes.yml (`packages:`) IN
# PLACE, after backing up the pristine originals. "restore" puts the originals back, so the working
# tree is byte-identical before and after the build. "stage" restores any leftovers first, so an
# interrupted build self-heals on the next one.
#
# Environment:
#   APPVAULT_DIR      path to the AppVault package (required)
#   APPVAULT_CONFIG   path to appvault-classes.yml (default: $SRCROOT/appvault-classes.yml)
#   APPVAULT_BACKUP   backup directory (default: a build-local dir, never your source tree)
set -euo pipefail

CMD="${1:-stage}"
: "${APPVAULT_DIR:?set APPVAULT_DIR to the AppVault package directory}"
CONFIG="${APPVAULT_CONFIG:-${SRCROOT:-$PWD}/appvault-classes.yml}"
BACKUP="${APPVAULT_BACKUP:-${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}/appvault-backup}"

# When this runs inside an Xcode "Run Script" phase, Xcode exports an iOS SDKROOT (and friends). A
# nested `swift build` would then try to build this macOS command-line tool against the iOS SDK and
# fail ("unable to load standard library for target ...-macosx"). Clear those so the tool builds for
# the host. (Harmless when run from a normal shell, where these vars are unset anyway.)
av_swift() {
  env -u SDKROOT -u PLATFORM_NAME -u SUPPORTED_PLATFORMS -u EFFECTIVE_PLATFORM_NAME \
      -u ARCHS -u PLATFORM_PREFERRED_ARCH -u TOOLCHAINS \
      swift "$@"
}

av_swift build --package-path "$APPVAULT_DIR" --product appvault-obfuscate -c release >/dev/null
OBF="$(av_swift build --package-path "$APPVAULT_DIR" --product appvault-obfuscate -c release --show-bin-path)/appvault-obfuscate"

case "$CMD" in
  stage)
    # Self-heal: undo any leftover obfuscation from an interrupted previous build, then obfuscate.
    "$OBF" --restore "$BACKUP" >/dev/null 2>&1 || true
    echo "AppVault: in-place obfuscation ($CONFIG)"
    "$OBF" --stage-config "$CONFIG" --backup "$BACKUP"
    ;;
  restore)
    "$OBF" --restore "$BACKUP"
    ;;
  *)
    echo "usage: appvault-inplace.sh [stage|restore]" >&2; exit 2 ;;
esac
