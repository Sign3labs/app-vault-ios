import XCTest
import SwiftParser
@testable import AppVaultObfuscationCore

final class SourceObfuscatorTests: XCTestCase {

    private func obfuscate(_ src: String, classes: Set<String>, allClasses: Bool = false,
                           file: String = "F") -> ObfuscationResult {
        SourceObfuscator.obfuscate(source: src, fileBase: file, targets: classes, allClasses: allClasses)
    }

    // MARK: Discovery (collector)

    func testFindsLiteralsOnlyInsideTargetClass() {
        let src = """
        class A { let x = "secret-a" }
        class B { let y = "secret-b" }
        """
        let tree = Parser.parse(source: src)
        let c = ClassStringCollector(targets: ["A"], file: "F", tree: tree)
        c.walk(tree)
        XCTAssertEqual(c.findings.count, 1)
        XCTAssertEqual(c.findings.first?.value, "secret-a")
        XCTAssertEqual(c.findings.first?.enclosingClass, "A")
    }

    func testFlagsInterpolatedLiterals() {
        let src = #"""
        class A { func f(_ id: String) -> String { "u=\(id)" } }
        """#
        let tree = Parser.parse(source: src)
        let c = ClassStringCollector(targets: ["A"], file: "F", tree: tree)
        c.walk(tree)
        XCTAssertEqual(c.findings.count, 1)
        XCTAssertTrue(c.findings[0].interpolated)
    }

    // MARK: Rewrite

    func testRewritesLiteralToProjectedValue() {
        let r = obfuscate(#"class A { let x = "secret" }"#, classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertFalse(r.transformedSource.contains(##"let x = "secret""##),
                       "class body must no longer assign the plaintext literal directly")
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_A_F.$s0"))
        XCTAssertTrue(r.transformedSource.contains("#Obfuscate(algorithm:"))
        XCTAssertTrue(r.transformedSource.contains(#"let s0 = "secret""#),
                      "the literal moves into the generated namespace")
    }

    func testInterpolatedLiteralLeftUntouchedButCounted() {
        let r = obfuscate(#"""
        class A {
            let a = "keep-secret"
            func f(_ id: String) -> String { "u=\(id)" }
        }
        """#, classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertEqual(r.skippedInterpolated, 1)
        XCTAssertTrue(r.transformedSource.contains(#""u=\(id)""#),
                      "interpolated literal must remain verbatim")
    }

    func testNonTargetClassUntouched() {
        let r = obfuscate(#"""
        class A { let a = "hide-me" }
        class B { let b = "leave-me" }
        """#, classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains(#"= "leave-me""#))
    }

    func testStructIgnored() {
        let r = obfuscate(#"struct S { let s = "nope" }"#, classes: ["S"])
        XCTAssertEqual(r.rewrittenCount, 0)
        XCTAssertTrue(r.transformedSource.contains(#"= "nope""#))
    }

    func testNestedClassAttributedToEnclosingTarget() {
        let r = obfuscate(#"""
        class Outer {
            class Inner { let t = "deep" }
        }
        """#, classes: ["Outer"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_Outer_F.$s0"))
    }

    func testAllClassesWildcard() {
        let r = obfuscate(#"""
        class A { let a = "one" }
        class B { let b = "two" }
        """#, classes: [], allClasses: true)
        XCTAssertEqual(r.rewrittenCount, 2)
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_A_F.$s0"))
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_B_F.$s0"))
    }

    func testImportInjectedOnlyWhenAbsent() {
        let without = obfuscate(#"class A { let a = "x" }"#, classes: ["A"])
        XCTAssertEqual(without.transformedSource.components(separatedBy: "import AppVault").count - 1, 1)

        let with = obfuscate("import AppVault\nclass A { let a = \"x\" }", classes: ["A"])
        XCTAssertEqual(with.transformedSource.components(separatedBy: "import AppVault").count - 1, 1,
                       "must not duplicate an existing import")
    }

    func testEscapesAndSpecialCharsPreserved() {
        let r = obfuscate(##"class A { let p = "a\tb\"c\\d" }"##, classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains(##"let s0 = "a\tb\"c\\d""##),
                      "escape sequences must survive verbatim into the namespace")
    }

    func testRawStringLiteralPreserved() {
        let r = obfuscate("class A { let p = #\"raw\\no-escape\"# }", classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains("let s0 = #\"raw\\no-escape\"#"))
    }

    func testIdempotentOnTransformedOutput() {
        let once = obfuscate(#"class A { let a = "s1"; let b = "s2" }"#, classes: ["A"])
        XCTAssertEqual(once.rewrittenCount, 2)
        // Feeding the transformed source back in must find nothing new to rewrite and must NOT
        // emit a second (colliding) namespace.
        let twice = obfuscate(once.transformedSource, classes: ["A"])
        XCTAssertEqual(twice.rewrittenCount, 0)
        let nsCount = twice.transformedSource.components(separatedBy: "private enum __AppVaultSecrets_A_F").count - 1
        XCTAssertEqual(nsCount, 1, "re-running must not duplicate the generated namespace")
    }

    func testMultipleLiteralsGetDistinctIds() {
        let r = obfuscate(#"class A { let a = "one"; let b = "two"; let c = "three" }"#, classes: ["A"])
        XCTAssertEqual(r.rewrittenCount, 3)
        for id in ["$s0", "$s1", "$s2"] {
            XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_A_F.\(id)"))
        }
    }

    func testNoTargetClassReturnsSourceUnchanged() {
        let src = #"class A { let a = "x" }"#
        let r = obfuscate(src, classes: ["DoesNotExist"])
        XCTAssertEqual(r.rewrittenCount, 0)
        XCTAssertEqual(r.transformedSource, src)
    }

    // MARK: Config parsing

    func testConfigParsesListForms() throws {
        let yml = """
        # comment
        sources:
          - App/Protected
          - App/More
        output: .build/avobf
        classes:
          - AppDelegate
          - ApiClient
        """
        let cfg = try ConfigLoader.parse(yml)
        XCTAssertEqual(Set(cfg.sources), ["App/Protected", "App/More"])
        XCTAssertEqual(cfg.output, ".build/avobf")
        XCTAssertEqual(cfg.classes, ["AppDelegate", "ApiClient"])
        XCTAssertFalse(cfg.allClasses)
    }

    func testConfigWildcardScalar() throws {
        let cfg = try ConfigLoader.parse("sources:\n  - X\nclasses: \"*\"\noutput: o")
        XCTAssertTrue(cfg.allClasses)
    }

    func testConfigMissingClassesThrows() {
        XCTAssertThrowsError(try ConfigLoader.parse("sources:\n  - X\noutput: o"))
    }

    func testConfigMissingSourcesThrows() {
        XCTAssertThrowsError(try ConfigLoader.parse("classes:\n  - A\noutput: o"))
    }
}
