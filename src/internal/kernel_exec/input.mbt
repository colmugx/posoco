///|
/// RunInput — facts the outside world has observed (ADR §2.1, §2.5, §2.6,
/// §2.9).
///
/// The reducer is the single arbiter: given a RunState and a RunInput, the
/// next state, declared effects and emitted events are deterministic. The
/// reducer never reads a clock; deadlines and budgets arrive as inputs.

///|
/// The initial input that drives a Run out of `Initializing`. Carries the
/// initial transcript seed (system prompt, user message, etc.) and the
/// catalog version to use.
pub(all) struct StartPayload {
  initial_messages : Array[@kernel.Message]
  catalog_version : CatalogVersion
} derive(Eq, Debug)

///|
/// A successful model step completion. Correlates to pending `CallModel` via `effect_id`.
/// `processed_messages` carries the transcript actually sent to the provider so the pump can write it back at commit boundary.
pub(all) struct ModelCompletedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  completion : @kernel.Completion
  processed_messages : Array[@kernel.Message]
} derive(Eq, Debug)

///|
/// A failed model step. The reducer transitions to `Terminal(Failed)`.
pub(all) struct ModelFailedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  failure : @kernel.ModelFailure
} derive(Eq, Debug)

///|
/// A successful or business-failed tool outcome. Runtime failures arrive as `ToolFailed`.
/// Correlates to pending `ExecuteTool` via `effect_id`; `call_id` must match.
pub(all) struct ToolCompletedPayload {
  effect_id : EffectId
  call_id : @kernel.CallId
  tool_name : @kernel.ToolName
  arguments : Json
  outcome : @kernel.ToolOutcome
} derive(Eq, Debug)

///|
/// Adapter runtime failure or kernel-invariant failure. Runtime → `ToolOutcome::RuntimeFailure`
/// and continues; invariant → `Terminal(Failed)`.
pub(all) struct ToolFailedPayload {
  effect_id : EffectId
  call_id : @kernel.CallId
  tool_name : @kernel.ToolName
  arguments : Json
  reason : String
  /// Non-invariant → builds `RuntimeFailure` outcome.
  runtime : @kernel.ModelFailure?
  /// Invariant → transitions to `Terminal(Failed)`.
  invariant_failure : InvariantCategory?
} derive(Eq, Debug)

///|
/// Host or adapter requested cancellation. ADR §2.5 race rules apply.
pub(all) struct CancelRequestedPayload {
  detail : String?
} derive(Eq, Debug)

///|
/// Deadline reached. Wins against queued completions (ADR §2.5 rule 2).
pub(all) struct DeadlineReachedPayload {
  detail : String
} derive(Eq, Debug)

///|
/// External observation that a budget dimension was crossed.
pub(all) struct BudgetExhaustedPayload {
  dimension : BudgetDimension
  consumed : Int
  limit : Int
} derive(Eq, Debug)

///|
/// Suspend requested. Only legal from `AwaitingModel` with a single pending `CallModel` (ADR §2.6).
/// Drops the pending effect, emits `CancelOutstanding`, enters `Suspended`.
pub(all) struct SuspendRequestedPayload {
  requirement : SuspensionRequirement
} derive(Eq, Debug)

///|
/// Resume. Only legal from `Suspended`. Emits `RunResumed`, transitions to `ReadyForModel`.
pub(all) struct ResumePayload {
  /// Opaque payload the host injects after resume.
  payload : Json
} derive(Eq, Debug)

///|
/// Host-side transcript rewrite (pre-model hook chain, compact Replace/Append).
/// The reducer is the sole transcript writer: pumps never mutate the
/// transcript directly, they submit the rewritten messages as this input and
/// the reducer commits them with a `TranscriptRewritten` event so the journal
/// records the fact. `reason` identifies the producer; current producers are
/// "pre_model_hook", "compact_replace" and "compact_append".
pub(all) struct TranscriptRewritePayload {
  rewritten_messages : Array[@kernel.Message]
  reason : String
} derive(Eq, Debug)

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
  TranscriptRewrite(payload~ : TranscriptRewritePayload)
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
    TranscriptRewrite(..) => "TranscriptRewrite"
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
    TranscriptRewrite(payload~) =>
      "TranscriptRewrite(\{payload.rewritten_messages.length()} messages, \{payload.reason})"
  }
}
