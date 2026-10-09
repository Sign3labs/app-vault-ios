// Minimal configuration for the class-scoped obfuscator's batch ("mirror") mode.
//
// Schema (appvault-classes.yml) -- intentionally a tiny, strict YAML subset:
//
//   sources:                 # one or more files or directories to read (required)
//     - App/Protected
//   output: .build/appvault  # directory for transformed copies (required in mirror mode)
//   classes:                 # class names to obfuscate; "*" means every class (required)
//     - AppDelegate
//     - ApiClient
//
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
    /// Parses the tiny YAML subset described above. Tolerant of blank lines, `#` comments,
    /// and both `key: scalar` and `key:` + indented `- item` list forms.
    public static func load(path: String) throws -> AppVaultConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ConfigError.unreadable(path)
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> AppVaultConfig {
        var sources: [String] = []
        var output: String?
        var classes: Set<String> = []
        var allClasses = false

        enum Key { case sources, classes, none }
        var current: Key = .none

        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.first == "\"" && v.last == "\"") || (v.first == "'" && v.last == "'") {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // strip comments (naive: no '#' inside our values)
            let line = String(rawLine).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("- ") {
                let item = unquote(String(trimmed.dropFirst(2)))
                switch current {
                case .sources: if !item.isEmpty { sources.append(item) }
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
