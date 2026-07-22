///|
/// Package-level re-export of Kernel types and functions used across the
/// Puppetry/Harness package.
///
/// MoonBit `using @kernel { type X }` introduces `X` as a package-local
/// alias for `@kernel.X`. Declaring these aliases once in this single file
/// lets every other file in the package reference `RunId`, `Effect`,
/// `reduce`, etc. unqualified, which keeps the orchestration code readable
/// without a per-file import dance (and without the package-cycle that
/// directly importing root compatibility ports would
/// create — REPAIR D3/D4).
///
/// This file MUST stay the single place that re-exports Kernel symbols into
/// the Puppetry package namespace. Do not duplicate these aliases elsewhere
/// in this package (the compiler rejects a second definition).
// Canonical domain types
using @kernel {
  type CanonicalMessage,
  type CanonicalTranscript,
  type CanonicalToolDef,
  // Effect + payloads
  // RunInput + payloads
  type RunInput,
  // Run state machine
  type RunState,
  type ReduceOutput,
  type RunOutcome,
  type EffectId,
  type ModelStepId,
  type InvariantCategory,
  type KernelError,
  // Catalog
  type CatalogVersion,
  type ToolCatalogSnapshot,
  // Identity / context
  type RunId,
  type SessionId,
  type Budget,
  // Kernel events
  type KernelEvent,
  // Reducer entry points
  reduce,
  run_model_step,
}
