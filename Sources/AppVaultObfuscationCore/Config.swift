// Minimal configuration for the class-scoped obfuscator -- intentionally a tiny, strict YAML subset.
//
// Two ways to point the obfuscator at your code:
//
//   packages:                # name folders; EVERY class inside them is obfuscated.
//     - App/Secure           # (implies classes: "*" over these folders)
//
//   -- or, for finer control --
//
//   sources:                 # one or more files or directories to read
//     - App/Protected
//   classes:                 # class names to obfuscate; "*" means every class
//     - AppDelegate
//     - ApiClient
//   output: .build/appvault  # directory for transformed copies (mirror mode only)
//
// `packages` and `sources` may be combined; `packages` additionally forces all-classes mode.
// `classes: "*"` (a scalar) obfuscates string literals in all classes found.

import Foundation

public struct AppVaultConfig: Sendable {
    public var sources: [String]
    public var output: String?
    public var classes: Set<String>
    public var allClasses: Bool

    public init(sources: [String], output: String?, classes: Set<String>, allClasses: Bool) {
        self.sources = sources
        self.output = output
        self.classes = classes
        self.allClasses = allClasses
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case missing(String)

    public var description: String {
        switch self {
        case .unreadable(let p): return "could not read config: \(p)"
        case .missing(let k): return "config is missing required key: \(k)"
        }
    }
}

public enum ConfigLoader {
    /// Removes a trailing YAML inline comment: a `#` at line start, or one preceded by whitespace.
    /// A `#` that is not preceded by whitespace (e.g. inside `out#v2` or a URL fragment) is kept.
    static func stripComment(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
                return String(chars[0..<i])
            }
            i += 1
        }
        return line
    }

    /// Parses the tiny YAML subset described above. Tolerant of blank lines, `#` comments,
    /// and both `key: scalar` and `key:` + indented `- item` list forms.
    public static func load(path: String) throws -> AppVaultConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConfigError.unreadable(path)
        }
        return try parse(text)
    }

    public static func parse(_ rawText: String) throws -> AppVaultConfig {
        // Normalize line endings: Swift fuses "\r\n" into one grapheme, so splitting on "\n"
        // would collapse a CRLF file to a single line. Also handles lone-CR (classic Mac) files.
        let text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var sources: [String] = []
        var output: String?
        var classes: Set<String> = []
        var allClasses = false

        enum Key { case sources, packages, classes, none }
        var current: Key = .none

        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.first == "\"" && v.last == "\"") || (v.first == "'" && v.last == "'") {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip a trailing comment only when '#' starts the line or follows whitespace -- the
            // YAML inline-comment rule. This keeps a '#' that is part of a value (paths, URLs).
            let line = stripComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("- ") {
                let item = unquote(String(trimmed.dropFirst(2)))
                switch current {
                case .sources: if !item.isEmpty { sources.append(item) }
                case .packages:
                    // A "package" is a folder; naming it obfuscates every class inside it.
                    if !item.isEmpty { sources.append(item); allClasses = true }
                case .classes:
                    if item == "*" { allClasses = true } else if !item.isEmpty { classes.insert(item) }
                case .none: break
                }
                continue
            }

            // key: [scalar]
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = unquote(String(trimmed[trimmed.index(after: colon)...]))
                switch key {
                case "sources":
                    current = .sources
                    if !rest.isEmpty { sources.append(rest) }
                case "packages":
                    current = .packages
                    if !rest.isEmpty { sources.append(rest); allClasses = true }
                case "classes":
                    current = .classes
                    if rest == "*" { allClasses = true } else if !rest.isEmpty { classes.insert(rest) }
                case "output":
                    current = .none
                    if !rest.isEmpty { output = rest }
                default:
                    current = .none
                }
            }
        }

        guard !sources.isEmpty else { throw ConfigError.missing("sources") }
        guard allClasses || !classes.isEmpty else { throw ConfigError.missing("classes") }
        return AppVaultConfig(sources: sources, output: output, classes: classes, allClasses: allClasses)
    }
}
