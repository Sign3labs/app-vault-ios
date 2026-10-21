import XCTest
import SwiftParser
@testable import AppVaultObfuscationCore

/// Stress / hang / crash resistance for the obfuscation engine. Every case must terminate quickly
/// and never trap.
final class RobustnessTests: XCTestCase {

    private func obf(_ s: String, _ classes: Set<String>, all: Bool = false) -> ObfuscationResult {
        SourceObfuscator.obfuscate(source: s, fileBase: "F", targets: classes, allClasses: all)
    }

    func testManyLiteralsDoesNotHang() {
        // 5,000 literals in one class -- must complete well under the test timeout.
        var body = "class Big {\n"
        for i in 0..<5000 { body += "  let v\(i) = \"secret-\(i)\"\n" }
        body += "}\n"
        let r = obf(body, ["Big"])
        XCTAssertEqual(r.rewrittenCount, 5000)
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_Big_F.$s4999"))
    }

    func testNestedClassesAtRealisticDepth() {
        // 12 levels is already far beyond any real code; the innermost literal must be found.
        let depth = 12
        var src = ""
        for i in 0..<depth { src += "class C\(i) {\n" }
        src += "let deep = \"bottom\"\n"
        src += String(repeating: "}\n", count: depth)
        let r = obf(src, ["C0"])          // C0 is an enclosing target
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains(#"let s0 = "bottom""#))
    }

    func testPathologicalNestingDegradesGracefully() {
        // SwiftParser enforces a maximum nesting level; beyond it, deep content is not parsed as
        // structured declarations. The guarantee here is only that we never crash or hang -- the
        // call must return cleanly (reaching this line's assertions proves it did).
        let depth = 400
        var src = ""
        for i in 0..<depth { src += "class C\(i) {\n" }
        src += "let deep = \"bottom\"\n"
        src += String(repeating: "}\n", count: depth)
        let r = obf(src, ["C0"])
        XCTAssertGreaterThanOrEqual(r.rewrittenCount, 0)   // no trap; count may be 0 past the limit
        XCTAssertFalse(r.transformedSource.isEmpty)
    }

    func testMalformedSourceDoesNotCrash() {
        // Incomplete / invalid Swift -- SwiftSyntax recovers; we must not trap.
        let broken = "class A { let x = \"ok\" ; func f( {{{ let y = \"also\""
        let r = obf(broken, ["A"])
        XCTAssertGreaterThanOrEqual(r.rewrittenCount, 1)   // at least the well-formed literal
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(obf("", ["A"]).rewrittenCount, 0)
        XCTAssertEqual(obf("   \n\t\n", ["A"]).rewrittenCount, 0)
    }

    func testOnlyInterpolationsProducesNoRewrite() {
        let src = #"""
        class A {
            func f(_ a: String, _ b: String) -> [String] {
                [ "\(a)", "x=\(a)-\(b)", "\(a)\(b)" ]
            }
        }
        """#
        let r = obf(src, ["A"])
        XCTAssertEqual(r.rewrittenCount, 0)
        XCTAssertEqual(r.skippedInterpolated, 3)
        XCTAssertEqual(r.transformedSource, src, "nothing to rewrite -> source returned unchanged")
    }

    func testUnicodeAndEmojiPreserved() {
        let r = obf("class A { let s = \"नमस्ते 🔐 café\" }", ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains("let s0 = \"नमस्ते 🔐 café\""))
    }

    func testMultilineStringLiteralPreserved() {
        let ml = "\"\"\"\n  line one\n  line two\n  \"\"\""
        let r = obf("class A {\n  let banner = \(ml)\n}", ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains("line one"))
        XCTAssertTrue(r.transformedSource.contains("\"\"\""), "triple-quote delimiters preserved")
    }

    func testVeryLongStringDoesNotHang() {
        let big = String(repeating: "A", count: 200_000)
        let r = obf("class A { let s = \"\(big)\" }", ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.contains("__AppVaultSecrets_A_F.$s0"))
    }

    func testWildcardOnManyClasses() {
        var src = ""
        for i in 0..<300 { src += "class K\(i) { let v = \"k\(i)\" }\n" }
        let r = obf(src, [], all: true)
        XCTAssertEqual(r.rewrittenCount, 300)
    }

    func testBlankLineHeavyFileDoesNotHang() {
        // Regression guard for the import-detection step. A regex using \s* over the whole source
        // was O(N^2) on long blank-line runs (each line-start retried the match across every
        // following newline), so this input hung for seconds. The linear scan must stay fast.
        let src = "class A { let x = \"s\" }\n" + String(repeating: "\n", count: 100_000)
        let start = Date()
        let r = obf(src, ["A"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertLessThan(elapsed, 5.0, "import check must be linear; \(elapsed)s suggests the O(N^2) regex is back")
    }

    func testManyImportCandidatesAndBlankLinesStayFast() {
        // Lots of non-matching import-like lines plus blank lines: still must be linear.
        var src = "class A { let x = \"s\" }\n"
        for i in 0..<20_000 { src += "import Foo\(i)\n\n" }
        let start = Date()
        let r = obf(src, ["A"])
        XCTAssertEqual(r.rewrittenCount, 1)
        XCTAssertTrue(r.transformedSource.hasPrefix("import AppVault\n"),
                      "AppVault import injected since none of the Foo imports match")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }
}
