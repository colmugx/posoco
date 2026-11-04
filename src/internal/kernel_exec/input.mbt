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
#derive(Eq, Debug)
pub(all) struct StartPayload {
  initial_messages : Array[@kernel.Message]
  catalog_version : CatalogVersion
}

///|
pub extend StartPayload with Eq::{not_equal, equal}

///|
pub extend StartPayload with Debug::{to_repr}

///|
/// A successful model step completion. Correlates to pending `CallModel` via `effect_id`.
/// `processed_messages` carries the transcript actually sent to the provider so the pump can write it back at commit boundary.
#derive(Eq, Debug)
pub(all) struct ModelCompletedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  completion : @kernel.Completion
  processed_messages : Array[@kernel.Message]
}

///|
pub extend ModelCompletedPayload with Eq::{not_equal, equal}

///|
pub extend ModelCompletedPayload with Debug::{to_repr}

///|
/// A failed model step. The reducer transitions to `Terminal(Failed)`.
#derive(Eq, Debug)
pub(all) struct ModelFailedPayload {
  effect_id : EffectId
  model_step_id : ModelStepId
  failure : @kernel.ModelFailure
}

///|
pub extend ModelFailedPayload with Eq::{not_equal, equal}

///|
pub extend ModelFailedPayload with Debug::{to_repr}

///|
/// A successful or business-failed tool outcome. Runtime failures arrive as `ToolFailed`.
/// Correlates to pending `ExecuteTool` via `effect_id`; `call_id` must match.
#derive(Eq, Debug)
pub(all) struct ToolCompletedPayload {
  effect_id : EffectId
  call_id : @kernel.CallId
  tool_name : @kernel.ToolName
  arguments : Json
  outcome : @kernel.ToolOutcome
}

///|
pub extend ToolCompletedPayload with Eq::{not_equal, equal}

///|
pub extend ToolCompletedPayload with Debug::{to_repr}

///|
/// Adapter runtime failure or kernel-invariant failure. Runtime → `ToolOutcome::RuntimeFailure`
/// and continues; invariant → `Terminal(Failed)`.
#derive(Eq, Debug)
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
}

///|
pub extend ToolFailedPayload with Eq::{not_equal, equal}

///|
pub extend ToolFailedPayload with Debug::{to_repr}

///|
/// Host or adapter requested cancellation. ADR §2.5 race rules apply.
#derive(Eq, Debug)
pub(all) struct CancelRequestedPayload {
  detail : String?
}

///|
pub extend CancelRequestedPayload with Eq::{not_equal, equal}

///|
pub extend CancelRequestedPayload with Debug::{to_repr}

///|
/// Deadline reached. Wins against queued completions (ADR §2.5 rule 2).
#derive(Eq, Debug)
pub(all) struct DeadlineReachedPayload {
  detail : String
}

///|
pub extend DeadlineReachedPayload with Eq::{not_equal, equal}

///|
pub extend DeadlineReachedPayload with Debug::{to_repr}

///|
/// External observation that a budget dimension was crossed.
#derive(Eq, Debug)
pub(all) struct BudgetExhaustedPayload {
  dimension : BudgetDimension
  consumed : Int32
  limit : Int32
}

///|
pub extend BudgetExhaustedPayload with Eq::{not_equal, equal}

///|
pub extend BudgetExhaustedPayload with Debug::{to_repr}

///|
/// Suspend requested. Only legal from `AwaitingModel` with a single pending `CallModel` (ADR §2.6).
/// Drops the pending effect, emits `CancelOutstanding`, enters `Suspended`.
#derive(Eq, Debug)
pub(all) struct SuspendRequestedPayload {
  requirement : SuspensionRequirement
}

///|
pub extend SuspendRequestedPayload with Eq::{not_equal, equal}

///|
pub extend SuspendRequestedPayload with Debug::{to_repr}

///|
/// Resume. Only legal from `Suspended`. Emits `RunResumed`, transitions to `ReadyForModel`.
#derive(Eq, Debug)
pub(all) struct ResumePayload {
  /// Opaque payload the host injects after resume.
  payload : Json
}

///|
pub extend ResumePayload with Eq::{not_equal, equal}

///|
pub extend ResumePayload with Debug::{to_repr}

///|
/// Host-side transcript rewrite (pre-model hook chain, compact Replace).
/// The reducer is the sole transcript writer: pumps never mutate the
/// transcript directly, they submit the rewritten messages as this input and
/// the reducer commits them with a `TranscriptRewritten` event so the journal
/// records the fact. `reason` identifies the producer; current producers are
/// "pre_model_hook", "compact_replace" and "compact_append".
#derive(Eq, Debug)
pub(all) struct TranscriptRewritePayload {
  rewritten_messages : Array[@kernel.Message]
  reason : String
}

///|
pub extend TranscriptRewritePayload with Eq::{not_equal, equal}

///|
pub extend TranscriptRewritePayload with Debug::{to_repr}

///|
/// A steer message accepted at a step boundary: one user message appended to
/// the transcript after a complete tool batch and before the next model step
/// is declared.
#derive(Eq, Debug)
pub(all) struct SteerAppendedPayload {
  message : @kernel.Message
  command_id : String
}

///|
pub extend SteerAppendedPayload with Eq::{not_equal, equal}

///|
pub extend SteerAppendedPayload with Debug::{to_repr}

///|
/// Discriminator for RunInput variants. The reducer pattern-matches on this
/// in `reduce(state, input)`.
#derive(Eq, Debug)
pub(all) enum RunInput {
  Start(payload~ : StartPayload)
  ModelCompleted(payload~ : ModelCompletedPayload)
  /// A model completion that raced an accepted steer message: the same
  /// completion payload, but the run must not end on a no-tool completion —
  /// the steer re-opens the step boundary instead (explicit kind so replay
  /// and rejection labels stay distinct from `ModelCompleted`).
  ModelCompletedWithSteering(payload~ : ModelCompletedPayload)
  ModelFailed(payload~ : ModelFailedPayload)
  ToolCompleted(payload~ : ToolCompletedPayload)
  ToolFailed(payload~ : ToolFailedPayload)
  CancelRequested(payload~ : CancelRequestedPayload)
  DeadlineReached(payload~ : DeadlineReachedPayload)
  BudgetExhausted(payload~ : BudgetExhaustedPayload)
  SuspendRequested(payload~ : SuspendRequestedPayload)
  Resume(payload~ : ResumePayload)
  TranscriptRewrite(payload~ : TranscriptRewritePayload)
  SteerAppended(payload~ : SteerAppendedPayload)
}

///|
pub extend RunInput with Eq::{not_equal, equal}

///|
pub extend RunInput with Debug::{to_repr}

///|
/// Stable string label for the input kind. Used by `InputRejected` events
/// and by debug/conformance output. The string form is part of the contract
/// (replay-equal), so it must not drift.
fn RunInput::kind(self : RunInput) -> String {
  match self {
    Start(..) => "Start"
    ModelCompleted(..) => "ModelCompleted"
    ModelCompletedWithSteering(..) => "ModelCompletedWithSteering"
    ModelFailed(..) => "ModelFailed"
    ToolCompleted(..) => "ToolCompleted"
    ToolFailed(..) => "ToolFailed"
    CancelRequested(..) => "CancelRequested"
    DeadlineReached(..) => "DeadlineReached"
    BudgetExhausted(..) => "BudgetExhausted"
    SuspendRequested(..) => "SuspendRequested"
    Resume(..) => "Resume"
    TranscriptRewrite(..) => "TranscriptRewrite"
    SteerAppended(..) => "SteerAppended"
  }
}

///|
pub extend RunInput with Show::{to_string, output}

///|
pub impl Show for RunInput with fn to_string(self : RunInput) -> String {
  match self {
    Start(..) => "Start"
    ModelCompleted(payload~) =>
      "ModelCompleted(effect=\{payload.effect_id.to_int()})"
    ModelCompletedWithSteering(payload~) =>
      "ModelCompletedWithSteering(effect=\{payload.effect_id.to_int()})"
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
    SteerAppended(payload~) => "SteerAppended(command=\{payload.command_id})"
  }
}
