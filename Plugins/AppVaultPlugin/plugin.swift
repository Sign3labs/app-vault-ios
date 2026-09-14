import Foundation
import PackagePlugin

// AppVault build-tool plugin: reads `appvault.yml` and generates obfuscated secrets at build time,
// fronting the swift-confidential generator. The generated file's `import ConfidentialKit` is rewritten
// to `import AppVault`, so consumers only ever see AppVault.

private enum C {
    static let configName = "appvault"
    static let configExtensions = ["yml", "yaml"]
    static let outputDirName = "ObfuscatedSources"
    static let rawFileName = "_AppVaultRaw.swift"
    static let outputFileName = "AppVault.generated.swift"
    static let toolName = "swift-confidential"
}

private func buildCommands(toolURL: URL, workDir: URL, configURL: URL) -> [Command] {
    let outputDir = workDir.appending(component: C.outputDirName)
    let rawFile = outputDir.appending(component: C.rawFileName)
    let finalFile = outputDir.appending(component: C.outputFileName)

    let tool = toolURL.path(percentEncoded: false)
    let cfg = configURL.path(percentEncoded: false)
    let raw = rawFile.path(percentEncoded: false)
    let out = finalFile.path(percentEncoded: false)
    let dir = outputDir.path(percentEncoded: false)

    // 1) run the generator into a raw file, 2) rewrite the engine import to `import AppVault`.
    let script = "mkdir -p '\(dir)' && '\(tool)' obfuscate --configuration '\(cfg)' --output '\(raw)' && "
        + "/usr/bin/sed 's/^import ConfidentialKit$/import AppVault/' '\(raw)' > '\(out)'"

    return [
        .buildCommand(
            displayName: "AppVault: obfuscate secrets",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            inputFiles: [configURL],
            outputFiles: [finalFile]
        )
    ]
}

private func locateConfig(in directory: URL) -> URL? {
    for ext in C.configExtensions {
        let candidate = directory.appending(component: "\(C.configName).\(ext)")
        if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            return candidate
        }
    }
    return nil
}

@main
struct AppVaultPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let src = target as? SwiftSourceModuleTarget else { return [] }
        guard let config = locateConfig(in: src.directoryURL) else { return [] }
        let tool = try context.tool(named: C.toolName)
        return buildCommands(toolURL: tool.url, workDir: context.pluginWorkDirectoryURL, configURL: config)
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension AppVaultPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        guard let config = locateConfig(in: context.xcodeProject.directoryURL) else { return [] }
        let tool = try context.tool(named: C.toolName)
        return buildCommands(toolURL: tool.url, workDir: context.pluginWorkDirectoryURL, configURL: config)
    }
}
#endif
