import XCTest
@testable import AppVaultObfuscationCore

/// Tests for the mirror ("batch") runner that a build hook calls.
final class BatchRunnerTests: XCTestCase {

    private func tmpDir() -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("avbatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMirrorsObfuscatedAndPassthroughFilesPreservingLayout() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let src = (root as NSString).appendingPathComponent("src")
        let out = (root as NSString).appendingPathComponent("out")
        let nested = (src as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try #"class A { let s = "hide" }"#.write(toFile: (src as NSString).appendingPathComponent("A.swift"),
                                                  atomically: true, encoding: .utf8)
        try "enum FeatureFlag { static let c = \"plain\" }".write(
            toFile: (nested as NSString).appendingPathComponent("Flags.swift"), atomically: true, encoding: .utf8)

        let cfg = AppVaultConfig(sources: [src], output: out, classes: ["A"], allClasses: false)
        let summary = try BatchRunner.run(config: cfg)

        XCTAssertEqual(summary.filesWritten, 2)
        XCTAssertEqual(summary.filesObfuscated, 1)
        XCTAssertEqual(summary.literalsObfuscated, 1)
        XCTAssertEqual(summary.filesFailed, 0)
        // Nested layout preserved; passthrough file mirrored verbatim; obfuscated file rewritten.
        let outA = try String(contentsOfFile: (out as NSString).appendingPathComponent("A.swift"), encoding: .utf8)
        let outFlags = try String(contentsOfFile: (out as NSString).appendingPathComponent("sub/Flags.swift"), encoding: .utf8)
        XCTAssertTrue(outA.contains("__AppVaultSecrets_A_A"))
        XCTAssertFalse(outA.contains(#"let s = "hide""#))
        XCTAssertTrue(outFlags.contains(#"static let c = "plain""#))
    }

    func testWriteFailureIsSkippedNotFatal() throws {
        // Pre-create the destination path for one file AS A DIRECTORY so its atomic write fails.
        // The batch must skip it (filesFailed++) and still write the other file, not abort.
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let src = (root as NSString).appendingPathComponent("src")
        let out = (root as NSString).appendingPathComponent("out")
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try #"class A { let x = "one" }"#.write(toFile: (src as NSString).appendingPathComponent("a.swift"),
                                                 atomically: true, encoding: .utf8)
        try #"class A { let y = "two" }"#.write(toFile: (src as NSString).appendingPathComponent("b.swift"),
                                                 atomically: true, encoding: .utf8)
        // Make out/b.swift a directory -> writing the file there must fail.
        try FileManager.default.createDirectory(atPath: (out as NSString).appendingPathComponent("b.swift"),
                                                withIntermediateDirectories: true)

        let cfg = AppVaultConfig(sources: [src], output: out, classes: ["A"], allClasses: false)
        let summary = try BatchRunner.run(config: cfg)   // must NOT throw
        XCTAssertEqual(summary.filesFailed, 1, "the blocked file is counted as failed")
        XCTAssertEqual(summary.filesWritten, 1, "the other file still gets written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("a.swift")))
    }

    func testMissingOutputThrows() {
        let cfg = AppVaultConfig(sources: ["/nonexistent"], output: nil, classes: ["A"], allClasses: false)
        XCTAssertThrowsError(try BatchRunner.run(config: cfg))
    }
}
