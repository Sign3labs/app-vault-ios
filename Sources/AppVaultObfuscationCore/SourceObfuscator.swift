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

/// Rewrites literals within target classes to `<namespace>.$sN` and records what it replaced so
/// the caller can emit the matching obfuscated namespaces.
final class ObfuscatingRewriter: SyntaxRewriter {
    let targets: Set<String>
    let allClasses: Bool
    let fileBase: String
    private var classStack: [String] = []
    private var counters: [String: Int] = [:]
    /// enclosingClass -> ordered (id, originalLiteralText)
    private(set) var collected: [String: [(id: String, literal: String)]] = [:]
    private(set) var skippedInterpolated = 0

    init(targets: Set<String>, allClasses: Bool, fileBase: String) {
        self.targets = targets
        self.allClasses = allClasses
        self.fileBase = fileBase
        super.init()
    }

    private func enclosingTargetClass() -> String? {
        allClasses ? classStack.last : classStack.last(where: { targets.contains($0) })
    }

    func namespace(for cls: String) -> String {
        "__AppVaultSecrets_\(sanitize(cls))_\(sanitize(fileBase))"
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        classStack.append(node.name.text)
        defer { classStack.removeLast() }
        return super.visit(node)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        guard let enclosing = enclosingTargetClass() else {
            return super.visit(node)
        }
        // Interpolated literals cannot be static secrets -- leave them untouched.
        if node.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) {
            skippedInterpolated += 1
            return super.visit(node)
        }

        let n = counters[enclosing, default: 0]
        counters[enclosing] = n + 1
        let id = "s\(n)"
        let original = node.trimmedDescription
        collected[enclosing, default: []].append((id, original))

        let ref = "\(namespace(for: enclosing)).$\(id)"
        let replacement: ExprSyntax = "\(raw: ref)"
        return replacement
            .with(\.leadingTrivia, node.leadingTrivia)
            .with(\.trailingTrivia, node.trailingTrivia)
    }
}

public enum SourceObfuscator {
    /// Transforms one file's source. Returns the rewritten source with generated namespaces appended,
    /// or `nil` findings count 0 when nothing in a target class was obfuscatable.
    public static func obfuscate(source: String, fileBase: String, targets: Set<String>, allClasses: Bool = false) -> ObfuscationResult {
        let tree = Parser.parse(source: source)
        let rewriter = ObfuscatingRewriter(targets: targets, allClasses: allClasses, fileBase: fileBase)
        let newTree = rewriter.rewrite(tree)

        let totalRewritten = rewriter.collected.values.reduce(0) { $0 + $1.count }
        if totalRewritten == 0 {
            return ObfuscationResult(transformedSource: source,
                                     rewrittenCount: 0,
                                     skippedInterpolated: rewriter.skippedInterpolated)
        }

        var body = newTree.description

        // Ensure the macro + runtime are in scope.
        if source.range(of: #"(?m)^\s*import\s+AppVault\s*$"#, options: .regularExpression) == nil {
            body = "import AppVault\n" + body
        }

        // Emit one obfuscated namespace per target class, in stable class-name order.
        var generated = "\n\n// MARK: - AppVault generated (do not edit; regenerated at build time)\n"
        for cls in rewriter.collected.keys.sorted() {
            let entries = rewriter.collected[cls]!
            let ns = rewriter.namespace(for: cls)
            generated += "\nprivate enum \(ns) {\n"
            generated += "    static #Obfuscate(algorithm: .custom([.encrypt(algorithm: .aes256GCM), .shuffle])) {\n"
            for e in entries {
                generated += "        let \(e.id) = \(e.literal)\n"
            }
            generated += "    }\n}\n"
        }

        return ObfuscationResult(transformedSource: body + generated,
                                 rewrittenCount: totalRewritten,
                                 skippedInterpolated: rewriter.skippedInterpolated)
    }
}
