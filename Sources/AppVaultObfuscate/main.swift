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
var inPlaceRequested = false
var outputPath: String?
var stageConfigPath: String?
var restoreDir: String?
var backupDir: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0

@MainActor func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); exit(2)
}
// Consume the value after a value-taking flag. Error if it is missing or is itself a flag --
// so `--class --in-place` no longer swallows `--in-place` as the class name, and a value left
// off the end of the command no longer silently no-ops.
@MainActor func requireValue(_ flag: String) -> String {
    guard i + 1 < args.count else { die("\(flag) requires a value") }
    let v = args[i + 1]
    if v.hasPrefix("-") && v != "-" { die("\(flag) requires a value (got flag '\(v)')") }
    i += 1
    return v
}
while i < args.count {
    switch args[i] {
    case "--config":
        configPath = requireValue("--config")
    case "--stage-config":
        stageConfigPath = requireValue("--stage-config")
    case "--backup":
        backupDir = requireValue("--backup")
    case "--restore":
        restoreDir = requireValue("--restore")
    case "--class", "-c":
        let v = requireValue("--class")
        if v == "*" { allClasses = true } else { targetClasses.insert(v) }
    case "--in-place":
        inPlaceRequested = true
    case "--output", "-o":
        outputPath = requireValue("--output")
    case "--suffix":
        suffix = requireValue("--suffix")
    case "-h", "--help":
        print("""
        appvault-obfuscate -- rewrite string literals inside named classes

        USAGE:
          # Build-time, in-place (source restored after compile):
          appvault-obfuscate --stage-config <appvault-classes.yml> --backup <dir>
          appvault-obfuscate --restore <dir>

          # Mirror (compile a transformed copy; originals kept out of the target):
          appvault-obfuscate --config <appvault-classes.yml>

          # Ad-hoc:
          appvault-obfuscate --class <Name|*> [--class <Name>...] <file-or-dir>...
                             [--in-place | --output <file>] [--suffix .obf.swift]
        """)
        exit(0)
    default:
        paths.append(args[i])
    }
    i += 1
}

// --in-place and --output both write the transformed source; together they are ambiguous and one
// ordering would silently overwrite the user's original. Reject rather than guess.
if inPlaceRequested && outputPath != nil {
    die("--in-place and --output are mutually exclusive")
}
if let outputPath {
    mode = .output(outputPath)
} else if inPlaceRequested {
    mode = .inPlace
}

// ---- Restore (post-compile build phase, or self-heal) ------------------------------------------
if let restoreDir {
    do {
        let s = try InPlaceRunner.restore(backupDir: restoreDir)
        print("AppVault restore: \(s.filesRestored) file(s) restored to pristine source.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }
}

// ---- Stage: in-place build-time obfuscation (pre-compile build phase) ---------------------------
if let stageConfigPath {
    guard let backupDir else { die("--stage-config requires --backup <dir>") }
    do {
        let config = try ConfigLoader.load(path: stageConfigPath)
        let s = try InPlaceRunner.stage(config: config, backupDir: backupDir)
        let scope = config.allClasses ? "all classes" : config.classes.sorted().joined(separator: ", ")
        print("AppVault stage (in place): \(scope)")
        print("  \(s.filesObfuscated) file(s) obfuscated, \(s.literalsObfuscated) literal(s) hidden, "
            + "\(s.literalsSkipped) skipped (interpolated), \(s.filesBackedUp) backed up.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }
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

    let dest: String
    switch mode {
    case .preview:  dest = (f as NSString).deletingPathExtension + suffix
    case .inPlace:  dest = f
    case .output(let out): dest = out
    }
    // Preview/in-place emit only when something was obfuscated; explicit --output always writes
    // (verbatim if nothing matched) so a build step compiling the output never hits "no such file".
    if result.rewrittenCount == 0 {
        if case .output = mode {} else { continue }
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
