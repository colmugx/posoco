///|
/// Package-level re-exports of Kernel types so puppetry files use
/// unqualified names. Single source of truth — do not duplicate aliases
/// elsewhere (the compiler rejects a second definition).
///
/// Canonical protocol types come from the public `kernel` package; internal
/// execution machinery comes from `internal/kernel_exec`.
using @kernel {
  type Message,
  type Transcript,
  type ToolDef,
  type ToolCall,
  type ModelCallResult,
  type CompactResult,
}

///|
using @kernel_exec {
  type Effect,
  type RunInput,
  type RunState,
  type ReduceOutput,
  type RunOutcome,
  type EffectId,
  type ModelStepId,
  type InvariantCategory,
  type KernelError,
  type CatalogVersion,
  type ToolCatalogSnapshot,
  type ExecutionPlan,
  type SchedulingError,
  type RunId,
  type SessionId,
  type Budget,
  type CancelDisposition,
  type KernelEvent,
  reduce,
  run_model_step,
  schedule,
}

///|
using @port {
  trait Hook,
  type HookAbort,
  type HookStage,
  trait SessionStore,
  trait CommandPort,
}
