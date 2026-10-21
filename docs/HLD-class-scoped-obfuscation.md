# HLD — Class-Scoped String Obfuscation (AppVault Part 1)

**Status:** Implemented, tested; in-place package mode + hardening in AppVault `0.2.0`
**Owner:** Sign3
**Last updated:** 2026-10-19

---

## 1. Context & goal

AppVault already hides **hand-declared** secrets listed in `appvault.yml` (e.g. `clientId`,
`clientSecret`). Teams asked for a second mode:

> Point at a **class by name** and have every string literal already written inside it obfuscated —
> without rewriting call sites by hand.

The plaintext must not appear in the shipped binary, and the runtime behaviour must be identical.
Renaming the class symbol itself is **out of scope** (that is "Part 2"; see §9).

### Non-goals
- Class/method/symbol renaming (needs a source renamer or binary hardener — see §9).
- Protecting strings that originate in third-party frameworks (see §7).
- A replacement for RASP or runtime self-protection.

---

## 2. Design in one picture

```
 your source (a named class)                 build time                      runtime
 ─────────────────────────────    ─────────────────────────────────    ────────────────────
 class ApiClient {                 1. SwiftSyntax finds literals         __AppVaultSecrets…$s0
   let base = "https://…"    ──▶   2. literal → projected reference ──▶    deobfuscates via
 }                                 3. literal moves into a generated       AES-256-GCM + shuffle
                                      #Obfuscate namespace                 and returns "https://…"
                                   4. the macro ENCRYPTS it while
                                      the Swift compiler builds
```

Key idea: we **reuse AppVault's existing `#Obfuscate` engine**. We never re-implement crypto; we
only *move* each literal into a generated namespace and leave a reference behind. The AES-256-GCM +
shuffle encryption happens inside the macro at compile time, exactly as for hand-declared secrets.

---

## 3. Components

All new code lives in the AppVault package.

| Component | Path | Responsibility |
|---|---|---|
| `ClassStringCollector` | `Sources/AppVaultObfuscationCore/Finding.swift` | SwiftSyntax visitor: find string literals inside target classes; flag interpolated ones |
| `SourceObfuscator` | `Sources/AppVaultObfuscationCore/SourceObfuscator.swift` | SwiftSyntax rewriter: literal → `__AppVaultSecrets_<Class>_<File>.$sN`; emit the `#Obfuscate` namespace |
| `ConfigLoader` / `AppVaultConfig` | `Sources/AppVaultObfuscationCore/Config.swift` | Parse `appvault-classes.yml` (`sources` / `output` / `classes`, `*` = all) |
| `BatchRunner` | `Sources/AppVaultObfuscationCore/BatchRunner.swift` | "Mirror" mode: transform a source tree into an output tree (build hook entry point) |
| `appvault-scan` | `Sources/AppVaultScan` | Dry run: list what would be obfuscated |
| `appvault-obfuscate` | `Sources/AppVaultObfuscate` | CLI: `--config` (mirror) + ad-hoc `--class/--in-place/--output` |
| build-phase script | `Scripts/appvault-build-phase.sh` | Xcode Run Script wrapper |

Dependency note: SwiftSyntax is pinned to `603.0.2` — the **same** revision swift-confidential
already resolves, so no new version enters the graph.

---

## 4. Transformation detail

Input:
```swift
class ApiClient {
    let baseURL = "https://api.example.com"   // plain String literal
}
```

Output compiled by the build:
```swift
import AppVault                                 // added only if absent

class ApiClient {
    let baseURL = __AppVaultSecrets_ApiClient_ApiClient.$s0
}

// MARK: - AppVault generated
private enum __AppVaultSecrets_ApiClient_ApiClient {
    static #Obfuscate(algorithm: .custom([.encrypt(algorithm: .aes256GCM), .shuffle])) {
        let s0 = "https://api.example.com"
    }
}
```

Rules enforced:
- Literals **lexically inside** a target class are touched — including **nested types** and the
  class's **`extension`s** (extension literals share the class's `(class, file)` namespace).
- **Interpolated** literals (`"id=\(x)"`) are skipped — they cannot be static secrets.
- **Enum string raw values** (`case a = "x"`) are left as literals — Swift requires an enum raw value
  to be a literal, so rewriting them would break the build.
- Namespace is keyed per `(class, file)` → no collisions, and re-running is **idempotent**.
- Escapes, raw strings (`#"…"#`), multiline (`"""…"""`), unicode/emoji are preserved verbatim.

**Single source of truth.** `ClassStringCollector` (a `SyntaxVisitor`, which walks the real tree with
reliable scope/parent information) decides *what* to obfuscate — scoping, extensions, interpolation,
and enum-raw-value skipping. The `SyntaxRewriter` only *applies* those decisions by source position.
This keeps `appvault-scan` (preview) and `appvault-obfuscate` (rewrite) in exact agreement, and avoids
relying on a `SyntaxRewriter`'s unreliable parent pointers.

---

## 5. Integration models & client-side footprint

The requirement is **minimal-to-no change on the client (app) side**. Two models:

### 5a. Mirror (recommended) — zero committed source change
- Protected classes live in a folder the target does **not** compile directly.
- A pre-build step (`appvault-obfuscate --config appvault-classes.yml`) writes obfuscated copies
  into an `output` folder, which the build compiles instead.
- **Client footprint:** one Run Script build phase + one `appvault-classes.yml`. **No source edits.**
  Original files are never modified.

### 5b. In-place — no project config, but source is rewritten
- `appvault-obfuscate --class X --in-place file.swift` rewrites the file (literal → reference +
  appended namespace). Idempotent and safe to re-run, but the committed source changes.
- Useful for a quick demo or a one-shot; not preferred when "no client source change" is a hard
  requirement.

### 5c. Package-scoped, in-place at build time with restore (recommended)
- The client names **folders ("packages")** in `appvault-classes.yml` (`packages:`), and every class
  inside is obfuscated. No per-class list, and **no file relocation**.
- Two Xcode Run Script phases wrap the compile (`Scripts/appvault-inplace.sh`):
  - **stage** (before Compile Sources): back up each pristine original, then obfuscate it in place.
  - **restore** (last phase): put the originals back from the backup.
- The compiler builds the obfuscated form; after the build the working tree is **byte-for-byte
  unchanged**, and nothing obfuscated is committed. `stage` restores leftovers first, so an
  interrupted build self-heals on the next one.
- **Client footprint:** the package dependency + two Run Script phases + one `packages:` config.
  Application source and project structure are otherwise untouched — the closest iOS analog to a
  bytecode transform available on some other platforms.
- Backups live in a build-local directory (`DERIVED_FILE_DIR`/`TMPDIR`), never the source tree.
- **Tradeoff:** between a cancelled build and the next, on-disk files may transiently hold the
  obfuscated form; the next `stage` (or an explicit `restore`) returns them. This is inherent to
  source-level build obfuscation on a platform with no cheap bytecode-rewrite hook.

> For XYZ_Bank we recommend **5c**: it needs no `Protected/`/`Generated/` restructuring. The app's
> only persistent change is the build phases + the AppVault version bump in `Package.resolved`;
> application source stays byte-for-byte unchanged.

Constraint behind the model: a SwiftPM build-tool plugin cannot *exclude* a target's own source
files, so it cannot replace in-place literals automatically. The mirror model (compile a transformed
copy, keep originals out of the target) is the clean way to keep source pristine.

---

## 6. How we verified obfuscation actually happened

Verification is **evidence-based**, not assumed:

1. **Binary string scan (before vs after).** Build the app, then
   `strings -a XYZ_Bank.app/XYZ_Bank.debug.dylib | grep -F "<secret>"`.
   - *Before:* the literal is present (plaintext in `__TEXT`).
   - *After:* the literal is **absent** — proving it never reached the binary.
   (Debug builds put app code in `*.debug.dylib`, not the thin main binary — scan the dylib.)
2. **Control strings.** A non-target literal and an interpolated literal are expected to **remain**
   visible — this proves the scan is meaningful and the tool is selective, not blanket-stripping.
3. **Runtime round-trip.** Run the app/program and confirm every obfuscated value is reconstructed
   correctly (identical behaviour).
4. **Live app proof (XYZ_Bank).** With `AppDelegate` obfuscated, the Sign3 SDK still initialised and
   returned a live session (Request/Session/Device IDs), and `TAG_AppInstance`,
   `keyboard_third_party_attempted`, `Default Configuration` were gone from the dylib.

---

## 7. Known caveats

- **Literal-required / access-restricted positions.** A `StaticString`-typed property or parameter,
  and a **default argument value of a `public`/`open` method**, must be initialised from a literal at
  least as accessible as the declaration; the generated namespace is `private`, so rewriting these
  would not compile. These are **not yet auto-detected** — keep such members out of a targeted class.
  (Enum string raw values, the most common literal-required case, *are* detected and left untouched.)
- **Semantic-sensitive literals.** Replacing a literal with a runtime `String` can change meaning
  where the literal is **not** a plain `String`: SwiftUI `Text("…")` / `Image("…")`
  (`LocalizedStringKey`), `#selector`, `@objc` names, dictionary-literal keys. Keep those classes out
  of `classes:`. UIKit controller/manager code is safe.
- **Third-party framework residue.** Obfuscating *your* literal does not remove the same string if a
  linked framework ships it independently. Example observed: `"App Delegate"` still appeared in the
  binary — it came from **Firebase** ("App Delegate Proxy…"), not app code.
- **Extreme class nesting.** SwiftParser enforces a maximum nesting level (~20 nested class levels).
  Beyond it the inner literals are simply not rewritten — the tool degrades gracefully (no crash, no
  hang). Real code never approaches this.

---

## 8. Test & stability coverage

| Suite | What it covers | Result |
|---|---|---|
| Unit (`swift test`) | scoping, **extensions**, **enum raw-value skip**, interpolation skip, nesting, struct/non-target ignore, wildcard, import dedup, escapes/raw/multiline, idempotency, config parsing (`packages:`, `#`-in-value, CRLF) | 29 pass |
| Robustness (`swift test`) | 5k literals, deep + pathological nesting, malformed Swift, empty, interpolation-only, unicode/emoji, 200k-char string, 300-class wildcard, **blank-line-heavy + many-import hang guards** | 12 pass |
| Batch runner (`swift test`) | mirror layout preserved, passthrough, **write-failure resilience**, missing output throws | 3 pass |
| In-place runner (`swift test`) | **stage obfuscates a package in place; restore returns the source byte-for-byte**; nothing-to-do skip; idempotent cycles | 4 pass |
| Integration (`Scripts/integration-test.sh`) | end-to-end mirror build → compile → run → binary scan + controls, incl. **enum raw value + extension secret** | 20 checks pass |
| In-place e2e (`Scripts/inplace-test.sh`) | **stage → compile → run → binary scan → restore** round-trip; source restored byte-for-byte | 13 checks pass |
| CLI (`Scripts/cli-test.sh`) | arg safety (`--in-place`/`--output` mutual-exclusion, missing/flag values, scan↔obfuscate `*` parity, always-write `--output`, missing-source warning) + **watchdog hang guard** (blank-line file, 1 MB string, malformed) | 12 checks pass |
| Live app (iPhone 17 sim) | app launch, SDK calls, menu interaction, background — no crash, no crash reports | stable |

Run everything:
```bash
cd AppVault && swift test && ./Scripts/integration-test.sh && ./Scripts/inplace-test.sh && ./Scripts/cli-test.sh
```

---

## 9. Out of scope / next (Part 2)

Class-name / symbol obfuscation (renaming `ApiClient` → `xA3bQ`) is **not** handled here. It needs a
source-symbol renamer or a post-build binary hardener (e.g. iXGuard, Appdome). Hand-building a Swift
renamer is risky (`Codable` keys, `@objc`, storyboard/XIB refs) and is tracked separately.
