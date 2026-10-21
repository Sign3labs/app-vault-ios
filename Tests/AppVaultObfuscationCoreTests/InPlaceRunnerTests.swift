import XCTest
@testable import AppVaultObfuscationCore

/// Tests for the in-place build-time obfuscation + restore.
final class InPlaceRunnerTests: XCTestCase {

    private func tmpDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("avinplace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testStageObfuscatesPackageThenRestoreReturnsExactOriginal() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let pkg = (root as NSString).appendingPathComponent("Secure")
        let other = (root as NSString).appendingPathComponent("Other")
        let secret = (pkg as NSString).appendingPathComponent("ApiConfig.swift")
        let plain = (other as NSString).appendingPathComponent("Plain.swift")
        let original = """
        import Foundation
        final class ApiConfig {
            let baseURL = "https://api.secret.example"
            let apiKey = "sk-live-xyz"
        }
        class Pinner { let spki = "sha256/AA==" }
        """
        write(original, to: secret)
        write(#"struct Plain { static let v = "visible" }"#, to: plain)

        // `packages: [Secure]` -> every class under Secure, all-classes mode.
        let cfg = AppVaultConfig(sources: [pkg], output: nil, classes: [], allClasses: true)
        let backup = (root as NSString).appendingPathComponent("backup")

        let staged = try InPlaceRunner.stage(config: cfg, backupDir: backup)
        XCTAssertEqual(staged.filesObfuscated, 1)
        XCTAssertEqual(staged.filesBackedUp, 1)
        XCTAssertEqual(staged.literalsObfuscated, 3)   // baseURL, apiKey, spki (both classes)

        let afterStage = try String(contentsOfFile: secret, encoding: .utf8)
        XCTAssertTrue(afterStage.contains("__AppVaultSecrets_ApiConfig"))
        XCTAssertTrue(afterStage.contains("__AppVaultSecrets_Pinner"))
        XCTAssertFalse(afterStage.contains(#"let baseURL = "https://api.secret.example""#),
                       "plaintext initializer must be gone after staging")
        // A file with no class (only a struct) outside the package is never touched.
        XCTAssertEqual(try String(contentsOfFile: plain, encoding: .utf8),
                       #"struct Plain { static let v = "visible" }"#)

        let restored = try InPlaceRunner.restore(backupDir: backup)
        XCTAssertEqual(restored.filesRestored, 1)
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), original,
                       "restore must return the source byte-for-byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup), "backup dir is cleared after restore")
    }

    func testStageSkipsFilesWithNothingToObfuscate() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let f = (root as NSString).appendingPathComponent("OnlyStruct.swift")
        write(#"struct S { let x = "keep" }"#, to: f)
        let cfg = AppVaultConfig(sources: [root], output: nil, classes: [], allClasses: true)
        let backup = (root as NSString).appendingPathComponent("backup")
        let s = try InPlaceRunner.stage(config: cfg, backupDir: backup)
        XCTAssertEqual(s.filesObfuscated, 0)
        XCTAssertEqual(s.filesBackedUp, 0)
        XCTAssertEqual(try String(contentsOfFile: f, encoding: .utf8), #"struct S { let x = "keep" }"#)
    }

    func testRestoreWithNoManifestIsANoOp() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let s = try InPlaceRunner.restore(backupDir: (root as NSString).appendingPathComponent("nope"))
        XCTAssertEqual(s.filesRestored, 0)   // self-heal safe: nothing staged, nothing to do
    }

    func testStageIsIdempotentAfterRestore() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let f = (root as NSString).appendingPathComponent("A.swift")
        let original = #"class A { let a = "one"; let b = "two" }"#
        write(original, to: f)
        let cfg = AppVaultConfig(sources: [root], output: nil, classes: [], allClasses: true)
        let backup = (root as NSString).appendingPathComponent("backup")

        _ = try InPlaceRunner.stage(config: cfg, backupDir: backup)
        _ = try InPlaceRunner.restore(backupDir: backup)
        // Second cycle must produce the identical restored file.
        _ = try InPlaceRunner.stage(config: cfg, backupDir: backup)
        _ = try InPlaceRunner.restore(backupDir: backup)
        XCTAssertEqual(try String(contentsOfFile: f, encoding: .utf8), original)
    }
}
