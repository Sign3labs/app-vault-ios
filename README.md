# AppVault (iOS)

**AppVault** is a Swift Package for **compile-time string obfuscation**, offered by **Sign3**. Secret
literals are encrypted at build time and transparently deobfuscated at runtime, so sensitive strings —
endpoints, API keys/secrets, detection signatures — do not appear as plaintext in the app binary.

You integrate through AppVault's own build-tool plugin + `appvault.yml`; you never reference the
underlying engine in your code or config.

> **Distribution note:** AppVault is a build-time obfuscator (a Swift Package **build-tool plugin**), so it
> is distributed as a **source Swift Package (SPM-only)** — it cannot ship as a prebuilt XCFramework or a
> CocoaPods pod.

---

## Requirements
- Xcode 16+ / Swift 6 toolchain (build-time plugin is macOS-only; the runtime is iOS 13+).

## Step 1 — Add the package
Xcode: **File → Add Package Dependencies…** → enter the repository URL:
```
https://github.com/Sign3labs/app-vault-ios
```
Or in a `Package.swift`:
```swift
.package(url: "https://github.com/Sign3labs/app-vault-ios", from: "0.1.0")
```

Add to your app target:
```swift
dependencies: [
    .product(name: "AppVault", package: "app-vault-ios"),
],
plugins: [
    .plugin(name: "AppVaultPlugin", package: "app-vault-ios"),
]
```
In an Xcode app target: add the **AppVault** library under *Frameworks, Libraries…* and enable the
**AppVaultPlugin** build-tool plugin under *Build Phases → Run Build Tool Plug-ins*.

## Step 2 — Declare your secrets in `appvault.yml`

**Where the file goes** — the plugin looks in exactly one place, and finding nothing is not an error:

| Integration | Location |
|---|---|
| Xcode project | The **project's top-level directory** (next to `.xcodeproj`) |
| SwiftPM target | The **target's source directory** (e.g. `Sources/MyApp/`) |

Either `appvault.yml` or `appvault.yaml` is accepted.

```yaml
algorithm:
  - encrypt using aes-256-gcm
  - shuffle
defaultNamespace: create AppVaultSecrets
defaultAccessModifier: internal
secrets:
  - name: clientSecret
    value: your-real-secret-here
  - name: baseURL
    value: https://api.example.com/v1
  # A list value generates a [String]
  - name: suspiciousPaths
    value:
      - /usr/sbin/frida-server
      - /Applications/Cydia.app
```

### Configuration reference

| Key | Meaning |
|---|---|
| `algorithm` | Ordered list of techniques applied to every secret. Compose your own and keep it private. Use `random` for a per-secret random algorithm. |
| `defaultNamespace` | `create <Name>` generates the namespace; `extend <Name>` adds to one you already declare. |
| `defaultAccessModifier` | `internal` (default), `public`, or `package`. |
| `secrets[].name` | Becomes `AppVaultSecrets.$<name>`. |
| `secrets[].value` | A single value generates a `String`; a YAML list generates a `[String]`. |

Per-secret `algorithm`, `namespace`, and `accessModifier` keys override the defaults above.

**Available techniques for `algorithm`:**

| Syntax | Options |
|---|---|
| `encrypt using <alg>` | `aes-128-gcm`, `aes-192-gcm`, `aes-256-gcm`, `chacha20-poly` |
| `compress using <alg>` | `lzfse`, `lz4`, `lzma`, `zlib` |
| `shuffle` | *(no options)* |

## Step 3 — Use the deobfuscated values
The plugin generates an `AppVaultSecrets` namespace at build time. Read values via the `$` projection:
```swift
import AppVault

let secret  = AppVaultSecrets.$clientSecret
let baseURL = AppVaultSecrets.$baseURL
```
No plaintext for these values lands in the binary; they are reconstructed at runtime.

`AppVaultSecrets` is generated into **build intermediates**, not into your source tree, so it will not
appear in the Xcode navigator and must not be committed. Adding a secret is therefore two steps and a
build: add the YAML entry, reference `AppVaultSecrets.$name`, rebuild.

## Verifying it worked
Check the built binary directly — a secret that is still plaintext will show up here:
```bash
strings -a "$APP_PATH/YourApp" | grep -c 'your-real-secret-here'   # expect 0
```

---

## Troubleshooting

**`cannot find 'AppVaultSecrets' in scope`**
The plugin found no config and generated nothing — it does **not** fail the build when `appvault.yml` is
missing or misplaced. Confirm the file is in the exact location from the table in Step 2 (the *project*
directory for Xcode, the *target's source* directory for SwiftPM), and that the plugin is listed under
*Build Phases → Run Build Tool Plug-ins* for the target being built.

**`Internal error … malformed response` from the plugin in a headless build**
Caused by passing `-sdk` to `xcodebuild`. AppVault's generator is a macOS host tool, and `-sdk
iphonesimulator` forces it onto the simulator SDK, which corrupts the plugin protocol. Specify the
destination only:
```bash
xcodebuild -scheme YourApp -destination 'generic/platform=iOS' archive   # correct
xcodebuild -scheme YourApp -sdk iphonesimulator ...                      # breaks the plugin
```
Building from Xcode's GUI is unaffected.

**First build is slow.** The plugin's macro toolchain is compiled once per derived-data directory.
Subsequent builds are incremental.

---

## What it protects (and what it does not)
- ✅ Defeats `strings` / casual static inspection / grep of the binary — raises the reverse-engineering bar.
- ⚠️ This is **obfuscation, not secrecy**: the decode key ships inside the app, so a determined reverser or
  a runtime hook can still recover values. For genuinely sensitive material, prefer fetching it from a
  server at runtime rather than shipping it in the app.

## License / attribution
AppVault fronts the open-source **swift-confidential** engine (Apache-2.0). See `NOTICE`.
