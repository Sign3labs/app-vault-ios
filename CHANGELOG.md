# Changelog

All notable changes to AppVault are documented here. AppVault follows semantic versioning; SwiftPM
resolves a version from the matching git tag.

## 0.2.0 — 2026-10-19

Adds a package-scoped, client-invisible integration and hardens the class-scoped obfuscator.

### Added — package-scoped, in-place, build-time obfuscation
- **`packages:` config** — name folders ("packages") and *every class inside them* is obfuscated,
  so you never list classes one by one.
- **In-place build mode with restore.** `appvault-obfuscate --stage-config <yml> --backup <dir>`
  obfuscates the target's own files in place (backing up pristine originals); `--restore <dir>` puts
  them back. `Scripts/appvault-inplace.sh stage|restore` wires this into two Xcode Run Script phases
  (stage before Compile Sources, restore last). The client moves no files, commits nothing in
  obfuscated form, and the working tree is byte-for-byte unchanged after each build. The stage phase
  restores leftovers first, so an interrupted build self-heals.
- **One-command Xcode wiring.** `Scripts/appvault-setup.rb <App.xcodeproj>` adds the stage/restore
  Run Script phases (stage before Compile Sources, restore last) and sets
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`, idempotently, so the client never opens Build Phases. Needs
  the `xcodeproj` gem.
- **`Scripts/inplace-test.sh`** — end-to-end proof: stage → compile → run → binary scan → restore.
- `InPlaceRunnerTests` and `packages:` parser tests.

### Fixed
- **Enum string raw values are no longer rewritten.** `case login = "/login"` must stay a literal;
  rewriting it to a member access produced `raw value for enum case must be a literal` and broke the
  build. Raw values (including `CodingKeys` with custom JSON names) are now left untouched.
- **Literals inside an `extension` of a target class are now obfuscated.** Previously only the class
  body was scanned, so secrets written in `extension ApiClient { … }` leaked as plaintext with no
  warning. They now share the class's generated namespace.
- **Removed an O(n²) hang** in the "already imports AppVault?" check. A `\s`-based regex scanned every
  line start across all following blank lines; a blank-line-heavy file hung for seconds. Replaced with
  a linear scan.
- **`appvault-obfuscate` rejects `--in-place` together with `--output`** instead of silently letting
  one ordering overwrite the original source.
- **Value-taking flags validate their argument.** `--class`, `--output`, `--config`, `--suffix` now
  error (exit 2) when the value is missing or is itself a flag, instead of silently no-oping or
  swallowing the next flag as a value.
- **`--output` always writes**, even when nothing matched, so a build step compiling the output never
  hits "no such file."
- **Config parser:** a `#` inside a value (path or URL fragment, e.g. `out#v2`) is preserved instead
  of being truncated as a comment; CRLF and lone-CR line endings are handled.
- **Mirror mode is resilient:** a file that cannot be written is skipped with a warning and counted
  (`filesFailed`) rather than aborting the whole batch; a source path with no `.swift` files warns.

### Added — tests & CLI
- `appvault-scan` supports `--class '*'` (parity with `appvault-obfuscate`).
- `Scripts/cli-test.sh` — CLI contract + watchdog-bounded hang-guard checks.
- Tests for enum raw values, extensions, the config parser, the import-check hang, and the batch
  runner. Suite is now 48 unit/robustness tests, plus 20 end-to-end integration checks, 13 in-place
  round-trip checks, and 12 CLI checks.

## 0.1.2 — 2026-10-09
- Robustness / hang tests for the obfuscation engine and the Part 1 high-level design document.

## 0.1.1 — 2026-10-09
- Class-scoped string obfuscation (Part 1): point at a class by name and obfuscate every string
  literal inside it, reconstructed at runtime by the same `#Obfuscate` engine.

## 0.1.0 — 2026
- Initial AppVault package: compile-time string obfuscation via `appvault.yml` and `AppVaultPlugin`,
  fronting swift-confidential.
