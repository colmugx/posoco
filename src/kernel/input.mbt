///|
/// RunInput — facts the outside world has observed (ADR §2.1, §2.5, §2.6,
/// §2.9).
///
/// The reducer is the single arbiter: given a RunState and a RunInput, the
/// next state, declared effects and emitted events are deterministic. The
/// reducer never reads a clock; deadlines and budgets arrive as inputs.

// ──────────────────────────────────────────────────────────────────────────
// Start — the only legal input against `Initializing`
// ──────────────────────────────────────────────────────────────────────────

///|
/// The initial input that drives a Run out of `Initializing`. Carries the
/// initial transcript seed (system prompt, user message, etc.) and the
/// catalog version to use.
pub(all) struct StartPayload {
  initial_messages : Array[CanonicalMessage]
  catalog_version : CatalogVersion
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// ModelCompleted payload — the canonical assistant completion
// ──────────────────────────────────────────────────────────────────────────

///|
/// A successful model step completion. The reducer correlates this to the
/// pending `CallModel` effect via `effect_id` and to the model step via
/// `model_step_id`. Both must match.
pub(all) struct ModelCompletedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  completion : AssistantCompletion
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// ModelFailed payload
// ──────────────────────────────────────────────────────────────────────────

///|
/// A failed model step. The reducer transitions to `Terminal(Failed)` with
/// the matching `FailureReason` variant.
pub(all) struct ModelFailedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  failure : ModelFailure
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// ToolCompleted payload
// ──────────────────────────────────────────────────────────────────────────

///|
/// A successful or business-failed tool outcome. Runtime failures arrive as
/// `ToolFailed` instead. The reducer correlates this to the pending
/// `ExecuteTool` effect via `effect_id`; the `call_id` must also match the
/// effect's payload.
pub(all) struct ToolCompletedPayload {
  effect_id : EffectId
  call_id : CallId
  outcome : ToolOutcome
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// ToolFailed payload — adapter runtime failure
// ──────────────────────────────────────────────────────────────────────────

///|
/// The adapter could not produce a `ToolOutcome` (e.g. provider raised a
/// `RuntimeError`). The reducer converts this into a canonical
/// `ToolOutcome::RuntimeFailure` and continues the Run — non-terminal.
///
/// Kernel-invariant failures (MissingOwner, StaleSnapshot) also arrive
/// through this variant, carrying the matching `InvariantCategory`; the
/// reducer then transitions to `Terminal(Failed)` (ADR §2.4). This is the
/// single channel by which executor-side invariants reach the reducer.
pub(all) struct ToolFailedPayload {
  effect_id : EffectId
  call_id : CallId
  /// Non-invariant runtime failure → reducer builds `RuntimeFailure` outcome.
  runtime : ModelFailure?
  /// Invariant failure → reducer transitions to `Terminal(Failed)` with
  /// `InvariantViolation(category)`.
  invariant_failure : InvariantCategory?
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Cancel / Deadline / Budget inputs
// ──────────────────────────────────────────────────────────────────────────

///|
/// Host or adapter requested cancellation. The reducer applies ADR §2.5 race
/// rules: if the cancel arrives strictly before a queued completion, the
/// cancel wins; otherwise the completion wins and the cancel becomes a
/// post-terminal rejection.
pub(all) struct CancelRequestedPayload {
  detail : String?
} derive(Eq, Debug)

///|
/// Deadline reached. Always wins against queued completions for the same
/// reducer tick (ADR §2.5 rule 2).
pub(all) struct DeadlineReachedPayload {
  /// Opaque reason for diagnostics.
  detail : String
} derive(Eq, Debug)

///|
/// External observation that a budget dimension was crossed. M1 fakes use
/// this for token tracking; rounds/steps/calls are tracked internally by
/// the reducer.
pub(all) struct BudgetExhaustedPayload {
  dimension : BudgetDimension
  consumed : Int
  limit : Int
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Suspension / Resume inputs
// ──────────────────────────────────────────────────────────────────────────

///|
/// Suspend requested. Only legal from `AwaitingModel` with the single
/// `CallModel` effect pending (ADR §2.6). The reducer drops the pending
/// effect (emitting a `CancelOutstanding` for it), emits `RunSuspended`, and
/// enters `Suspended` with zero pending effects.
pub(all) struct SuspendRequestedPayload {
  requirement : SuspensionRequirement
} derive(Eq, Debug)

///|
/// Resume. Only legal from `Suspended`. The reducer emits `RunResumed` and
/// transitions back to `ReadyForModel` to re-issue the model step.
pub(all) struct ResumePayload {
  /// Opaque payload the host wants to inject into the run after resume. The
  /// Kernel stores it but does not interpret it in M1.
  payload : Json
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// RunInput ADT
// ──────────────────────────────────────────────────────────────────────────

///|
/// Discriminator for RunInput variants. The reducer pattern-matches on this
/// in `reduce(state, input)`.
pub(all) enum RunInput {
  Start(payload~ : StartPayload)
  ModelCompleted(payload~ : ModelCompletedPayload)
  ModelFailed(payload~ : ModelFailedPayload)
  ToolCompleted(payload~ : ToolCompletedPayload)
  ToolFailed(payload~ : ToolFailedPayload)
  CancelRequested(payload~ : CancelRequestedPayload)
  DeadlineReached(payload~ : DeadlineReachedPayload)
  BudgetExhausted(payload~ : BudgetExhaustedPayload)
  SuspendRequested(payload~ : SuspendRequestedPayload)
  Resume(payload~ : ResumePayload)
} derive(Eq, Debug)

///|
/// Stable string label for the input kind. Used by `InputRejected` events
/// and by debug/conformance output. The string form is part of the contract
/// (replay-equal), so it must not drift.
pub fn RunInput::kind(self : RunInput) -> String {
  match self {
    Start(..) => "Start"
    ModelCompleted(..) => "ModelCompleted"
    ModelFailed(..) => "ModelFailed"
    ToolCompleted(..) => "ToolCompleted"
    ToolFailed(..) => "ToolFailed"
    CancelRequested(..) => "CancelRequested"
    DeadlineReached(..) => "DeadlineReached"
    BudgetExhausted(..) => "BudgetExhausted"
    SuspendRequested(..) => "SuspendRequested"
    Resume(..) => "Resume"
  }
}

///|
pub impl Show for RunInput with fn to_string(self : RunInput) -> String {
  match self {
    Start(..) => "Start"
    ModelCompleted(payload~) =>
      "ModelCompleted(effect=\{payload.effect_id.to_int()})"
    ModelFailed(payload~) => "ModelFailed(effect=\{payload.effect_id.to_int()})"
    ToolCompleted(payload~) =>
      "ToolCompleted(effect=\{payload.effect_id.to_int()}, call=\{payload.call_id.to_string()})"
    ToolFailed(payload~) =>
      "ToolFailed(effect=\{payload.effect_id.to_int()}, call=\{payload.call_id.to_string()})"
    CancelRequested(..) => "CancelRequested"
    DeadlineReached(..) => "DeadlineReached"
    BudgetExhausted(payload~) =>
      "BudgetExhausted(\{payload.dimension.to_string()})"
    SuspendRequested(..) => "SuspendRequested"
    Resume(..) => "Resume"
  }
}
