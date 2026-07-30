///|
/// Package-level re-exports of Kernel types so puppetry files use
/// unqualified names. Single source of truth — do not duplicate aliases
/// elsewhere (the compiler rejects a second definition).
using @kernel {
  type Message,
  type Transcript,
  type ToolDef,
  type ToolCall,
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
  type ModelCallResult,
  type CompactResult,
  reduce,
  run_model_step,
  schedule,
}

///|
using @port {
  trait PreModelHook,
  trait PreToolHook,
  trait PostEventHook,
  type HookAbort,
  type PostStage,
  trait SessionStore,
  trait CommandPort,
}
