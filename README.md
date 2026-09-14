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
.package(url: "https://github.com/Sign3labs/app-vault-ios", from: "1.0.0")
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
Place `appvault.yml` at your target's source directory (SwiftPM) or the Xcode **project's top-level
directory**:
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
```

## Step 3 — Use the deobfuscated values
The plugin generates an `AppVaultSecrets` namespace at build time. Read values via the `$` projection:
```swift
import AppVault

let secret  = AppVaultSecrets.$clientSecret
let baseURL = AppVaultSecrets.$baseURL
```
No plaintext for these values lands in the binary; they are reconstructed at runtime.

---

## What it protects (and what it does not)
- ✅ Defeats `strings` / casual static inspection / grep of the binary — raises the reverse-engineering bar.
- ⚠️ This is **obfuscation, not secrecy**: the decode key ships inside the app, so a determined reverser or
  a runtime hook can still recover values. For genuinely sensitive material, prefer fetching it from a
  server at runtime rather than shipping it in the app.

## License / attribution
AppVault fronts the open-source **swift-confidential** engine (Apache-2.0). See `NOTICE`.
