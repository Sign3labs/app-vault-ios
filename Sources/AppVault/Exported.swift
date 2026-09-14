// AppVault runtime. Re-exports the underlying obfuscation runtime so consumers only ever
// `import AppVault` -- they never name the engine directly.
@_exported import ConfidentialKit

// Sign3-branded aliases for the algorithm/technique model (macro spelling itself cannot be aliased,
// but these let call sites and docs read in AppVault terms).
public typealias AppVaultAlgorithm = Obfuscation.AlgorithmSpecifier
public typealias AppVaultStep = Obfuscation.Step
