// Build-time in-place string obfuscation.
//
// Goal: the client changes nothing in their repo. Their source files stay where they are, are NOT
// moved into a separate folder, and are NOT committed in obfuscated form. Instead, a pre-"Compile
// Sources" build phase obfuscates the configured files *in place* (saving pristine backups), the
// compiler builds the obfuscated form, and a post-compile phase restores the originals -- so the
// working tree is identical before and after the build.
//
//   stage(config:backupDir:)   back up + obfuscate every configured file in place
//   restore(backupDir:)        put every backed-up original back, then clear the backup dir
//
// Restoring is idempotent and safe to call when nothing was staged, so the stage phase can call
// restore first to self-heal after an interrupted build.

import Foundation

public struct InPlaceSummary: Sendable {
    public var filesObfuscated = 0
    public var literalsObfuscated = 0
    public var literalsSkipped = 0
    public var filesBackedUp = 0
    public var filesRestored = 0
    public var filesFailed = 0
}

public enum InPlaceRunner {
    static let manifestName = "appvault-manifest.tsv"

    /// Absolute, standardized path so the manifest is independent of the working directory the
    /// restore phase happens to run in.
    private static func absolute(_ p: String) -> String {
        let abs = (p as NSString).isAbsolutePath
            ? p
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
        return (abs as NSString).standardizingPath
    }

    private static func enumerateSwift(root: String) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else {
            FileHandle.standardError.write(Data("warning: path not found: \(root)\n".utf8))
            return []
        }
        if !isDir.boolValue { return root.hasSuffix(".swift") ? [absolute(root)] : [] }
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let rel as String in en where rel.hasSuffix(".swift") {
            out.append(absolute((root as NSString).appendingPathComponent(rel)))
        }
        return out.sorted()
    }

    /// Obfuscate every configured `.swift` file in place, backing up each pristine original into
    /// `backupDir` and recording it in a manifest so `restore` can put it back exactly.
    @discardableResult
    public static func stage(config: AppVaultConfig, backupDir: String) throws -> InPlaceSummary {
        let fm = FileManager.default
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        var summary = InPlaceSummary()
        var manifestLines: [String] = []
        var index = 0

        // De-dup files (packages/sources may overlap) while preserving order.
        var seen = Set<String>()
        let files = config.sources.flatMap(enumerateSwift(root:)).filter { seen.insert($0).inserted }

        for abs in files {
            guard let text = try? String(contentsOfFile: abs, encoding: .utf8) else {
                FileHandle.standardError.write(Data("warning: could not read \(abs)\n".utf8))
                summary.filesFailed += 1
                continue
            }
            let base = ((abs as NSString).lastPathComponent as NSString).deletingPathExtension
            let result = SourceObfuscator.obfuscate(source: text, fileBase: base,
                                                    targets: config.classes, allClasses: config.allClasses)
            guard result.rewrittenCount > 0 else { continue }   // nothing to hide -> leave untouched

            let backupFile = (backupDir as NSString).appendingPathComponent("\(index).swift")
            do {
                // Back the original up FIRST, so a later write failure never loses the pristine file.
                try text.write(toFile: backupFile, atomically: true, encoding: .utf8)
                try result.transformedSource.write(toFile: abs, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("warning: could not obfuscate \(abs): \(error)\n".utf8))
                try? fm.removeItem(atPath: backupFile)
                summary.filesFailed += 1
                continue
            }
            manifestLines.append("\(abs)\t\(backupFile)")
            index += 1
            summary.filesBackedUp += 1
            summary.filesObfuscated += 1
            summary.literalsObfuscated += result.rewrittenCount
            summary.literalsSkipped += result.skippedInterpolated
        }

        try manifestLines.joined(separator: "\n")
            .write(toFile: (backupDir as NSString).appendingPathComponent(manifestName),
                   atomically: true, encoding: .utf8)
        return summary
    }

    /// Restore every file recorded in the backup manifest to its pristine original, then remove the
    /// backup directory. A no-op (not an error) when nothing was staged.
    @discardableResult
    public static func restore(backupDir: String) throws -> InPlaceSummary {
        let fm = FileManager.default
        var summary = InPlaceSummary()
        let manifestPath = (backupDir as NSString).appendingPathComponent(manifestName)
        guard let manifest = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            return summary
        }
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (orig, backup) = (parts[0], parts[1])
            guard let bytes = try? String(contentsOfFile: backup, encoding: .utf8) else {
                FileHandle.standardError.write(Data("warning: backup missing, cannot restore \(orig)\n".utf8))
                summary.filesFailed += 1
                continue
            }
            do {
                try bytes.write(toFile: orig, atomically: true, encoding: .utf8)
                summary.filesRestored += 1
            } catch {
                FileHandle.standardError.write(Data("warning: could not restore \(orig): \(error)\n".utf8))
                summary.filesFailed += 1
            }
        }
        try? fm.removeItem(atPath: backupDir)
        return summary
    }
}
