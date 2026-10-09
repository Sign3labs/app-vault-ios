// appvault-obfuscate -- rewrites string literals inside named classes so plaintext never reaches
// the binary. The encryption is performed by the existing `#Obfuscate` macro at compile time.
//
// Two ways to run:
//
//   Build-hook (recommended):  appvault-obfuscate --config appvault-classes.yml
//       Mirrors every .swift under the config's `sources` into its `output` directory, obfuscating
//       the configured classes. Originals are never touched; the build compiles the mirror.
//
//   Ad-hoc:  appvault-obfuscate --class ApiClient <file-or-dir>... [--in-place | --output <file>]
//       --class / -c   class to obfuscate (repeatable); use '*' for every class
//       (default)      write a preview next to each input as <name>.obf.swift
//       --in-place     overwrite each input file
//       --output FILE  single input file only -> write transformed source to FILE

import Foundation
import AppVaultObfuscationCore

enum WriteMode { case preview, inPlace, output(String) }

var targetClasses: Set<String> = []
var allClasses = false
var paths: [String] = []
var mode: WriteMode = .preview
var suffix = ".obf.swift"
var configPath: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--config":
        i += 1; if i < args.count { configPath = args[i] }
    case "--class", "-c":
        i += 1
        if i < args.count {
            if args[i] == "*" { allClasses = true } else { targetClasses.insert(args[i]) }
        }
    case "--in-place":
        mode = .inPlace
    case "--output", "-o":
        i += 1; if i < args.count { mode = .output(args[i]) }
    case "--suffix":
        i += 1; if i < args.count { suffix = args[i] }
    case "-h", "--help":
        print("""
        appvault-obfuscate -- rewrite string literals inside named classes

        USAGE:
          appvault-obfuscate --config <appvault-classes.yml>
          appvault-obfuscate --class <Name|*> [--class <Name>...] <file-or-dir>...
                             [--in-place | --output <file>] [--suffix .obf.swift]
        """)
        exit(0)
    default:
        paths.append(args[i])
    }
    i += 1
}

// ---- Config / mirror mode ----------------------------------------------------------------------
if let configPath {
    do {
        let config = try ConfigLoader.load(path: configPath)
        let summary = try BatchRunner.run(config: config)
        let scope = config.allClasses ? "all classes" : config.classes.sorted().joined(separator: ", ")
        print("AppVault obfuscate (mirror): \(scope)")
        print("  sources: \(config.sources.joined(separator: ", "))")
        print("  output:  \(config.output ?? "-")")
        print("  \(summary.filesWritten) file(s) mirrored, \(summary.filesObfuscated) obfuscated, "
            + "\(summary.literalsObfuscated) literal(s) hidden, \(summary.literalsSkipped) skipped (interpolated).")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }
}

// ---- Ad-hoc mode -------------------------------------------------------------------------------
guard allClasses || !targetClasses.isEmpty else {
    FileHandle.standardError.write(Data("error: provide --config, or at least one --class <Name>\n".utf8)); exit(2)
}
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("error: provide at least one file or directory\n".utf8)); exit(2)
}

let allFiles = paths.flatMap(swiftFiles(at:))
if case .output = mode, allFiles.count != 1 {
    FileHandle.standardError.write(Data("error: --output requires exactly one input .swift file\n".utf8)); exit(2)
}

var totalRewritten = 0, totalSkipped = 0, filesTouched = 0
for f in allFiles {
    guard let text = try? String(contentsOfFile: f, encoding: .utf8) else {
        FileHandle.standardError.write(Data("warning: could not read \(f)\n".utf8)); continue
    }
    let base = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
    let result = SourceObfuscator.obfuscate(source: text, fileBase: base, targets: targetClasses, allClasses: allClasses)
    guard result.rewrittenCount > 0 else { continue }

    let dest: String
    switch mode {
    case .preview:  dest = (f as NSString).deletingPathExtension + suffix
    case .inPlace:  dest = f
    case .output(let out): dest = out
    }
    do {
        try result.transformedSource.write(toFile: dest, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("error: could not write \(dest): \(error)\n".utf8)); continue
    }
    totalRewritten += result.rewrittenCount
    totalSkipped += result.skippedInterpolated
    filesTouched += 1
    print("  \((f as NSString).lastPathComponent): obfuscated \(result.rewrittenCount), skipped \(result.skippedInterpolated) -> \((dest as NSString).lastPathComponent)")
}
print("\nDone. \(filesTouched) file(s) transformed, \(totalRewritten) literal(s) obfuscated, \(totalSkipped) skipped (interpolated).")
