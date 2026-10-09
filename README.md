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

---

# Class-scoped obfuscation (Part 1)

The steps above obfuscate strings you **declare by hand** in `appvault.yml`. This mode instead lets
you point at a **class by name** and obfuscate every string literal already written inside it — the
plaintext is removed from the binary and reconstructed at runtime by the same engine.

## How it works

A pre-build step rewrites each target literal into a reference to a generated, encrypted namespace:

```swift
// you write:
class ApiClient {
    let baseURL = "https://api.example.com"
}

// the build compiles (plaintext gone; encrypted by #Obfuscate at compile time):
class ApiClient {
    let baseURL = __AppVaultSecrets_ApiClient_ApiClient.$s0
}
private enum __AppVaultSecrets_ApiClient_ApiClient {
    static #Obfuscate(algorithm: .custom([.encrypt(algorithm: .aes256GCM), .shuffle])) {
        let s0 = "https://api.example.com"
    }
}
```

Your original source is never modified: protected files stay in their own folder, and the build
compiles a transformed **mirror** of them.

## Setup

1. **Move the classes to protect into a folder that your target does not compile directly**, e.g.
   `Protected/`. (In an Xcode target, untick Target Membership for those files; in SwiftPM, keep the
   folder outside `Sources/<target>/`.)

2. **Add `appvault-classes.yml`** (see `appvault-classes.example.yml`):
   ```yaml
   sources:
     - Protected
   output: .build/appvault-obfuscated
   classes:
     - ApiClient
     - LoginManager
   ```

3. **Compile the generated `output` folder** instead of the originals (add it to the target / its
   Compile Sources).

4. **Run the obfuscator before every build.** In Xcode, add a Run Script phase *before* Compile
   Sources:
   ```sh
   APPVAULT_DIR="$SRCROOT/path/to/AppVault" "${APPVAULT_DIR}/Scripts/appvault-build-phase.sh"
   ```

### Dry run

See what would be obfuscated without changing anything:
```sh
swift run appvault-scan --class ApiClient Protected/
```

## Caveats

- **Interpolated literals** (`"id=\(x)"`) are left untouched — they can't be static secrets.
- Replacing a literal with a runtime `String` can change meaning where the literal is **not** a
  plain `String`: SwiftUI `Text("…")` / `Image("…")` (`LocalizedStringKey`), `#selector`, `@objc`
  names, and dictionary-literal keys. Keep those classes out of `classes:`, or split the literal
  out. UIKit controller/manager code is generally safe.
- This hides literals from **static** analysis. It is not a substitute for RASP or symbol-level
  (class-name) obfuscation.
