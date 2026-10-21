// In-place source obfuscator: rewrites string literals inside named classes so the plaintext
// never reaches the binary. Each literal is replaced by a reference to a generated, per-(file,class)
// obfuscated namespace that uses the existing `#Obfuscate` macro -- so the AES-256-GCM + shuffle
// encryption is performed by the same engine AppVault already ships, at compile time.

import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

public struct ObfuscationResult {
    public let transformedSource: String
    public let rewrittenCount: Int
    public let skippedInterpolated: Int
}

private func sanitize(_ s: String) -> String {
    let mapped = s.map { $0.isLetter || $0.isNumber ? $0 : "_" }
    return String(mapped)
}

/// True if the source already imports the AppVault module in any form
/// (`import AppVault`, `@_exported import AppVault`, `import class AppVault.X`, submodules).
/// Linear scan — deliberately NOT a regex, to avoid catastrophic backtracking on large files.
private func sourceImportsAppVault(_ source: String) -> Bool {
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let idx = toks.firstIndex(of: "import"), idx + 1 < toks.count else { continue }
        let declKinds: Set<String> = ["class", "struct", "enum", "protocol", "typealias", "func", "var", "let"]
        for j in (idx + 1)..<toks.count {
            let tok = toks[j]
            if tok == "AppVault" || tok.hasPrefix("AppVault.") { return true }
            if declKinds.contains(tok) { continue }
            break
        }
    }
    return false
}

func namespaceName(cls: String, fileBase: String) -> String {
    "__AppVaultSecrets_\(sanitize(cls))_\(sanitize(fileBase))"
}

/// Rewrites exactly the string literals the collector marked (by source position) into
/// `<namespace>.$sN`, and records the original literal text so the caller can emit the matching
/// obfuscated namespaces.
///
/// The set of literals to rewrite comes from `ClassStringCollector` (a SyntaxVisitor, which walks
/// the real tree with reliable parent/scope info), NOT from the rewriter's own traversal. A
/// SyntaxRewriter rebuilds the tree bottom-up and does not expose dependable `parent` pointers or a
/// stable scope stack, so driving the decision from the visitor keeps `appvault-scan` and
/// `appvault-obfuscate` in lockstep and inherits the visitor's handling of extensions, nested types,
/// interpolation, and enum-raw-value skipping.
final class ObfuscatingRewriter: SyntaxRewriter {
    let fileBase: String
    let converter: SourceLocationConverter
    /// "line:column" -> (enclosingClass, id). Built from the collector's findings.
    let plan: [String: (cls: String, id: String)]
    /// enclosingClass -> ordered (id, originalLiteralText)
    private(set) var collected: [String: [(id: String, literal: String)]] = [:]
    private(set) var rewrittenCount = 0

    init(fileBase: String, converter: SourceLocationConverter, plan: [String: (cls: String, id: String)]) {
        self.fileBase = fileBase
        self.converter = converter
        self.plan = plan
        super.init()
    }

    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        guard let entry = plan["\(loc.line):\(loc.column)"] else {
            return super.visit(node)
        }
        collected[entry.cls, default: []].append((entry.id, node.trimmedDescription))
        rewrittenCount += 1

        let ref = "\(namespaceName(cls: entry.cls, fileBase: fileBase)).$\(entry.id)"
        let replacement: ExprSyntax = "\(raw: ref)"
        return replacement
            .with(\.leadingTrivia, node.leadingTrivia)
            .with(\.trailingTrivia, node.trailingTrivia)
    }
}

public enum SourceObfuscator {
    /// Transforms one file's source: moves every obfuscatable string literal inside a target class
    /// into a generated `#Obfuscate` namespace and leaves a projected reference behind. Source with
    /// nothing to obfuscate is returned unchanged.
    public static func obfuscate(source: String, fileBase: String, targets: Set<String>, allClasses: Bool = false) -> ObfuscationResult {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileBase, tree: tree)

        // Single source of truth: the visitor decides WHAT to obfuscate (handles extensions, nested
        // types, interpolation + enum-raw-value skipping). The rewriter only applies those decisions.
        let collector = ClassStringCollector(targets: targets, file: fileBase, tree: tree, allClasses: allClasses)
        collector.walk(tree)
        let obfuscatable = collector.findings.filter { !$0.interpolated }
        let skippedInterpolated = collector.findings.filter { $0.interpolated }.count

        if obfuscatable.isEmpty {
            return ObfuscationResult(transformedSource: source,
                                     rewrittenCount: 0,
                                     skippedInterpolated: skippedInterpolated)
        }

        // Assign stable per-class ids in source order, keyed by each literal's position.
        var counters: [String: Int] = [:]
        var plan: [String: (cls: String, id: String)] = [:]
        for f in obfuscatable {
            let n = counters[f.enclosingClass, default: 0]
            counters[f.enclosingClass] = n + 1
            plan["\(f.line):\(f.column)"] = (f.enclosingClass, "s\(n)")
        }

        let rewriter = ObfuscatingRewriter(fileBase: fileBase, converter: converter, plan: plan)
        let newTree = rewriter.rewrite(tree)

        var body = newTree.description

        // Ensure the macro + runtime are in scope (linear scan; no regex backtracking).
        if !sourceImportsAppVault(source) {
            body = "import AppVault\n" + body
        }

        // Emit one obfuscated namespace per target class, in stable class-name order; within a
        // class, entries are ordered by id (s0, s1, ...).
        var generated = "\n\n// MARK: - AppVault generated (do not edit; regenerated at build time)\n"
        for cls in rewriter.collected.keys.sorted() {
            let entries = rewriter.collected[cls]!
                .sorted { (Int($0.id.dropFirst()) ?? 0) < (Int($1.id.dropFirst()) ?? 0) }
            let ns = namespaceName(cls: cls, fileBase: fileBase)
            generated += "\nprivate enum \(ns) {\n"
            generated += "    static #Obfuscate(algorithm: .custom([.encrypt(algorithm: .aes256GCM), .shuffle])) {\n"
            for e in entries {
                generated += "        let \(e.id) = \(e.literal)\n"
            }
            generated += "    }\n}\n"
        }

        return ObfuscationResult(transformedSource: body + generated,
                                 rewrittenCount: rewriter.rewrittenCount,
                                 skippedInterpolated: skippedInterpolated)
    }
}
