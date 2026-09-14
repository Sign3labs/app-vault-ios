// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppVault",
    platforms: [.macOS(.v13), .iOS(.v13)],
    products: [
        // Runtime library consumers import. Re-exports the underlying obfuscation runtime.
        .library(name: "AppVault", targets: ["AppVault"]),
        // Build-tool plugin that obfuscates secrets from `appvault.yml` at build time.
        .plugin(name: "AppVaultPlugin", targets: ["AppVaultPlugin"]),
    ],
    dependencies: [
        // We front this engine; consumers never name it.
        .package(url: "https://github.com/securevale/swift-confidential.git", .upToNextMinor(from: "0.5.2")),
    ],
    targets: [
        .target(
            name: "AppVault",
            dependencies: [
                .product(name: "ConfidentialKit", package: "swift-confidential"),
            ]
        ),
        // The same prebuilt generator the upstream plugin uses -- fronted, not forked.
        .binaryTarget(
            name: "SwiftConfidentialGenerator",
            url: "https://github.com/securevale/swift-confidential/releases/download/0.5.2/SwiftConfidentialBinary-macos.artifactbundle.zip",
            checksum: "104b4c05046ae1fb9d54790488112d71730d4afedf1f715869b8fe99edac8f9b"
        ),
        .plugin(
            name: "AppVaultPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftConfidentialGenerator"]
        ),
    ]
)
