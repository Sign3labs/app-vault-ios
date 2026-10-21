// appvault-scan -- discovery / dry run. Reports every string literal inside named classes so you
// can review what the obfuscator would touch before rewriting anything.
//
// Usage:
//   appvault-scan --class LoginManager [--class ApiClient] <file-or-dir> [more paths...] [--json]

import Foundation
import SwiftParser
import AppVaultObfuscationCore

var targetClasses: Set<String> = []
var allClasses = false
var paths: [String] = []
var jsonOutput = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0

@MainActor func requireValue(_ flag: String) -> String {
    guard i + 1 < args.count else {
        FileHandle.standardError.write(Data("error: \(flag) requires a value\n".utf8)); exit(2)
    }
    let v = args[i + 1]
    if v.hasPrefix("-") && v != "-" {
        FileHandle.standardError.write(Data("error: \(flag) requires a value (got flag '\(v)')\n".utf8)); exit(2)
    }
    i += 1
    return v
}
while i < args.count {
    switch args[i] {
    case "--class", "-c":
        let v = requireValue("--class")
        if v == "*" { allClasses = true } else { targetClasses.insert(v) }
    case "--json":
        jsonOutput = true
    case "-h", "--help":
        print("""
        appvault-scan -- find string literals inside named classes

        USAGE:
          appvault-scan --class <Name> [--class <Name>...] <file-or-dir>... [--json]
        """)
        exit(0)
    default:
        paths.append(args[i])
    }
    i += 1
}

guard allClasses || !targetClasses.isEmpty else {
    FileHandle.standardError.write(Data("error: provide at least one --class <Name> (or --class '*')\n".utf8)); exit(2)
}
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("error: provide at least one file or directory\n".utf8)); exit(2)
}

let allFiles = paths.flatMap(swiftFiles(at:))
var all: [Finding] = []
for f in allFiles {
    guard let text = try? String(contentsOfFile: f, encoding: .utf8) else {
        FileHandle.standardError.write(Data("warning: could not read \(f)\n".utf8)); continue
    }
    let tree = Parser.parse(source: text)
    let collector = ClassStringCollector(targets: targetClasses, file: f, tree: tree, allClasses: allClasses)
    collector.walk(tree)
    all.append(contentsOf: collector.findings)
}

if jsonOutput {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? enc.encode(all)) ?? Data("[]".utf8), as: UTF8.self))
} else {
    let obfuscatable = all.filter { !$0.interpolated }
    let skipped = all.filter { $0.interpolated }
    let scope = allClasses ? "all classes" : targetClasses.sorted().joined(separator: ", ")
    print("Scanned \(allFiles.count) file(s) for class(es): \(scope)")
    print("Found \(all.count) string literal(s): \(obfuscatable.count) obfuscatable, \(skipped.count) skipped (interpolated).\n")
    for f in all {
        let tag = f.interpolated ? "  [skip: interpolated]" : ""
        let shortFile = (f.file as NSString).lastPathComponent
        print("  \(f.enclosingClass)  \(shortFile):\(f.line):\(f.column)  \"\(f.value)\"\(tag)")
    }
}
