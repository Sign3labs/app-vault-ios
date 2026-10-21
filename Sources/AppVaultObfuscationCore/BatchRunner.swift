// Batch "mirror" mode: the step a build hook calls.
//
// Reads every .swift file under `sources`, obfuscates the string literals in the configured
// classes, and writes the result into `output` preserving each file's path relative to its
// source root. Files with nothing to obfuscate are mirrored verbatim, so `output` is a complete,
// compilable copy of the input -- the originals are never modified. Individual files that cannot be
// read or written are skipped with a warning and counted (filesFailed) rather than aborting the
// whole batch, so one bad file never leaves the build step half-done with an unexplained throw.

import Foundation

public struct BatchSummary: Sendable {
    public var filesWritten = 0
    public var filesObfuscated = 0
    public var literalsObfuscated = 0
    public var literalsSkipped = 0
    public var filesFailed = 0
}

public enum BatchRunner {
    /// Returns a flat list of (absoluteFile, relativePathUnderRoot) for every .swift under `root`.
    private static func enumerateSwift(root: String) -> [(abs: String, rel: String)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return root.hasSuffix(".swift") ? [(root, (root as NSString).lastPathComponent)] : []
        }
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [(String, String)] = []
        for case let rel as String in en where rel.hasSuffix(".swift") {
            out.append(((root as NSString).appendingPathComponent(rel), rel))
        }
        return out
    }

    @discardableResult
    public static func run(config: AppVaultConfig) throws -> BatchSummary {
        guard let output = config.output else {
            throw ConfigError.missing("output")
        }
        let fm = FileManager.default
        var summary = BatchSummary()

        for root in config.sources {
            let files = enumerateSwift(root: root)
            if files.isEmpty {
                FileHandle.standardError.write(Data(
                    "warning: source path has no .swift files (missing or empty?): \(root)\n".utf8))
            }
            for (abs, rel) in files {
                guard let text = try? String(contentsOfFile: abs, encoding: .utf8) else {
                    FileHandle.standardError.write(Data("warning: could not read \(abs)\n".utf8))
                    continue
                }
                let base = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                let result = SourceObfuscator.obfuscate(
                    source: text, fileBase: base,
                    targets: config.classes, allClasses: config.allClasses
                )

                let dest = (output as NSString).appendingPathComponent(rel)
                do {
                    try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
                    try result.transformedSource.write(toFile: dest, atomically: true, encoding: .utf8)
                } catch {
                    FileHandle.standardError.write(Data("warning: could not write \(dest): \(error)\n".utf8))
                    summary.filesFailed += 1
                    continue
                }

                summary.filesWritten += 1
                if result.rewrittenCount > 0 {
                    summary.filesObfuscated += 1
                    summary.literalsObfuscated += result.rewrittenCount
                    summary.literalsSkipped += result.skippedInterpolated
                }
            }
        }
        return summary
    }
}
