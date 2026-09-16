# AppVault (iOS)

**AppVault** is a Swift Package for **compile-time string obfuscation**, offered by **Sign3**. Secret
literals are encrypted at build time and transparently deobfuscated at runtime, so sensitive strings —
endpoints, API keys/secrets, detection signatures — do not appear as plaintext in the app binary.

---

## Requirements
- Xcode 16+ / Swift 6 toolchain (build-time plugin is macOS-only; the runtime is iOS 13+).

---

# Integration

Four steps: add the package, enable the plugin, declare your secrets, read them in code.

## Step 1 — Add the package

**In Xcode:** **File → Add Package Dependencies…** → enter the repository URL:
```
https://github.com/Sign3labs/app-vault-ios
```
Choose **Exact Version** and type the version number from the latest release, then add the package to your project.

**In a `Package.swift`:**
```swift
.package(url: "https://github.com/Sign3labs/app-vault-ios", from: "0.1.0")
```

## Step 2 — Attach the library and the plugin to your target

Both are required: the library is the runtime, the plugin does the build-time obfuscation.

**In Xcode**, select your app target, then:

| Where | What to add |
|---|---|
| *General → Frameworks, Libraries, and Embedded Content* | **AppVault** |
| *Build Phases → Run Build Tool Plug-ins* | **AppVaultPlugin** |

**In a `Package.swift` target:**
```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "AppVault", package: "app-vault-ios"),
    ],
    plugins: [
        .plugin(name: "AppVaultPlugin", package: "app-vault-ios"),
    ]
)
```

## Step 3 — Declare your secrets in `appvault.yml`

`appvault.yml` is a plain text file where you list the strings you want hidden. You write them out
normally here — AppVault encrypts them while your app is building, and the readable version never
reaches the shipped app. The file stays in your source repo; it is never bundled.

### Where to put the file

The plugin checks **one folder only**. Put the file in the folder that matches how you integrated:

**Xcode project** — beside your `.xcodeproj`, at the top level of the project:
```
MyApp/
├── MyApp.xcodeproj
├── appvault.yml        ← here
└── MyApp/
    └── AppDelegate.swift
```

**SwiftPM package** — inside the target's own source folder:
```
MyPackage/
├── Package.swift
└── Sources/
    └── MyApp/
        ├── appvault.yml    ← here
        └── App.swift
```

The name can be `appvault.yml` or `appvault.yaml`. Both works.

> **If the plugin cannot find the file, your build still succeeds.** It simply generates nothing, with
> no warning. You find out later, when the compiler says `cannot find 'AppVaultSecrets' in scope`. If
> you hit that error, check this folder first — a misplaced file is the usual cause.

### What goes in the file

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
  - name: suspiciousPaths
    value:
      - /usr/sbin/frida-server
      - /Applications/Cydia.app
```

Reading it line by line:

- **`algorithm`** — how each value is scrambled. The steps run in the order you list them. The two
  above are a sensible default; you can keep them as they are.
- **`defaultNamespace`** — `create AppVaultSecrets` tells AppVault to generate a container called
  `AppVaultSecrets`. This is the name you will type in your code.
- **`defaultAccessModifier`** — `internal` means the secrets are visible inside your own module,
  which is what an app target wants. Use `public` only if another module needs to read them.
- **`secrets`** — one entry per string. `name` is what you call it in code
  (`clientSecret` becomes `AppVaultSecrets.$clientSecret`), and `value` is the real string.
- **A value written as a list** — like `suspiciousPaths` above — comes back as a `[String]` array
  instead of a single `String`.

### Adding the file to an Xcode project

Drag `appvault.yml` into the project navigator so you can see and edit it. Then select it, open the
**File inspector** on the right, and under *Target Membership* make sure **no target is ticked**.

This matters. The plugin reads the file at build time, so it does not need to be part of the target.
If a target *is* ticked, Xcode copies the file into the app bundle — which would ship the plain,
readable secrets right next to the encrypted ones, undoing the whole point.

## Step 4 — Use the deobfuscated values

The plugin generates an `AppVaultSecrets` namespace at build time. Read values via the `$` projection:

```swift
import AppVault

let secret  = AppVaultSecrets.$clientSecret
let baseURL = AppVaultSecrets.$baseURL
```

No plaintext for these values lands in the binary; they are reconstructed at runtime.

`AppVaultSecrets` is generated into **build intermediates**, not into your source tree, so it will not
appear in the Xcode navigator and must not be committed.

## Adding a secret later

Two edits and a build:

1. Add an entry to `appvault.yml`:
   ```yaml
     - name: newToken
       value: my-new-secret-value
   ```
2. Reference it in code as `AppVaultSecrets.$newToken`.
3. Build — the plugin regenerates the namespace with the new entry included.
