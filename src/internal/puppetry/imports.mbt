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
  type RunId,
  type TurnId,
  type SessionId,
  type EffectId,
  type InvocationScope,
  type CancelDisposition,
  type CatalogVersion,
}

///|
using @kernel_exec {
  type Effect,
  type RunInput,
  type RunState,
  type ReduceOutput,
  type RunOutcome,
  type ModelStepId,
  type InvariantCategory,
  type KernelError,
  type ToolCatalogSnapshot,
  type ExecutionPlan,
  type SchedulingError,
  type Budget,
  type KernelEvent,
  reduce,
  run_model_step,
  schedule,
}

///|
using @port {
  trait PipelineHook,
  type HookAbort,
  type HookStage,
  trait SessionStore,
  trait CommandPort,
}
