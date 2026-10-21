// Shared model + discovery visitor for the class-scoped string obfuscator.

import Foundation
import SwiftSyntax

public struct Finding: Codable, Sendable {
    public let file: String
    public let enclosingClass: String
    public let line: Int
    public let column: Int
    public let value: String
    public let interpolated: Bool
}

/// Collects string literals nested anywhere inside the target classes, attributing each to its
/// nearest enclosing *target* class. Literals in non-target types are ignored. Interpolated
/// literals are reported but flagged, since they cannot be treated as static secrets.
public final class ClassStringCollector: SyntaxVisitor {
    private let targets: Set<String>
    private let allClasses: Bool
    private let file: String
    private let converter: SourceLocationConverter
    private var classStack: [String] = []
    public private(set) var findings: [Finding] = []

    public init(targets: Set<String>, file: String, tree: SourceFileSyntax, allClasses: Bool = false) {
        self.targets = targets
        self.allClasses = allClasses
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func enclosingTarget() -> String? {
        allClasses ? classStack.last : classStack.last(where: { targets.contains($0) })
    }

    /// The simple name of an extended type: `ApiClient` -> "ApiClient", `Foo.Bar` -> "Bar".
    private func extendedTypeName(_ type: TypeSyntax) -> String {
        if let id = type.as(IdentifierTypeSyntax.self) { return id.name.text }
        if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
        return type.trimmedDescription
    }

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        classStack.append(node.name.text)
        return .visitChildren
    }

    public override func visitPost(_ node: ClassDeclSyntax) {
        classStack.removeLast()
    }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        classStack.append(extendedTypeName(node.extendedType))
        return .visitChildren
    }

    public override func visitPost(_ node: ExtensionDeclSyntax) {
        classStack.removeLast()
    }

    public override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let enclosing = enclosingTarget() else {
            return .visitChildren
        }
        // Enum raw values must remain literals -- the obfuscator leaves them, so scan ignores them.
        if let initClause = node.parent?.as(InitializerClauseSyntax.self),
           initClause.parent?.is(EnumCaseElementSyntax.self) == true {
            return .visitChildren
        }
        let interpolated = node.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        let value = node.segments
            .compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
            .joined()
        let loc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        findings.append(
            Finding(file: file, enclosingClass: enclosing, line: loc.line,
                    column: loc.column, value: value, interpolated: interpolated)
        )
        return .visitChildren
    }
}

/// Expands file/dir paths into a flat list of `.swift` files.
public func swiftFiles(at path: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        FileHandle.standardError.write(Data("warning: path not found: \(path)\n".utf8))
        return []
    }
    guard isDir.boolValue else {
        return path.hasSuffix(".swift") ? [path] : []
    }
    guard let en = fm.enumerator(atPath: path) else { return [] }
    var out: [String] = []
    for case let rel as String in en where rel.hasSuffix(".swift") {
        out.append((path as NSString).appendingPathComponent(rel))
    }
    return out
}
