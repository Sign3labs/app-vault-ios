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
        // Part 1 engine: discover a class's string literals, and rewrite them in place.
        .executable(name: "appvault-scan", targets: ["AppVaultScan"]),
        .executable(name: "appvault-obfuscate", targets: ["AppVaultObfuscate"]),
    ],
    dependencies: [
        // We front this engine; consumers never name it.
        .package(url: "https://github.com/securevale/swift-confidential.git", exact: "0.5.2"),
        // SwiftSyntax drives the class-scoped scanner/rewriter. Pinned to the same revision
        // swift-confidential already resolves, so no new version enters the graph.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
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
        // Shared discovery + rewrite engine for the class-scoped obfuscator (Part 1).
        .target(
            name: "AppVaultObfuscationCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        // Reports string literals inside named classes (discovery / dry run).
        .executableTarget(
            name: "AppVaultScan",
            dependencies: ["AppVaultObfuscationCore"]
        ),
        // Rewrites string literals inside named classes into obfuscated references.
        .executableTarget(
            name: "AppVaultObfuscate",
            dependencies: ["AppVaultObfuscationCore"]
        ),
        // Unit tests for the discovery + rewrite engine.
        .testTarget(
            name: "AppVaultObfuscationCoreTests",
            dependencies: ["AppVaultObfuscationCore"]
        ),
    ]
)
