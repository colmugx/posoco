///|
/// KernelEvent — pure domain events emitted by the reducer (ADR §2.1, §2.3,
/// §2.6, §2.9).
///
/// All events are unstamped: the reducer emits them with a sequence number
/// (allocated by RunState), but the wall-clock timestamp is added outside the
/// reducer by the Harness/Interpreter, which has access to an injected clock.
/// This is what makes Kernel replay byte-equal.
///
/// Convention: terminal events (`RunCompleted`/`RunFailed`/`RunCancelled`)
/// are emitted exactly once per Run. `RunSuspended` and `RunResumed` are
/// non-terminal — they mark quiescent-phase transitions.

// ──────────────────────────────────────────────────────────────────────────
// Run-level events
// ──────────────────────────────────────────────────────────────────────────

///|
/// Emitted when the reducer first transitions out of `Initializing` (the
/// `Start` input). The `RunStarted` event is non-terminal.
///
/// Note: this is the new Kernel name (open question Q6.4 — ADR recommended
/// scheme). The legacy `TurnStarted` continues to be emitted by the
/// compatibility facade alongside this event.
pub(all) struct StartedDetails {
  run_id : RunId
  session_id : SessionId
} derive(Eq, Debug)

///|
/// Suspension requirement — what the host must satisfy before sending
/// `Resume`. M1 only exercises in-process resume; cross-process durability
/// is M5. The Kernel never interprets the payload.
pub(all) struct SuspensionRequirement {
  /// Human/typed label identifying what the suspension is waiting for
  /// (e.g. "approval", "user_input", "checkpoint").
  kind : String
  /// Opaque payload carried across the suspension boundary. The Kernel
  /// does not interpret this; M5 defines the durable encoding.
  payload : Json
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// KernelEvent ADT
// ──────────────────────────────────────────────────────────────────────────

///|
/// A single domain event declared by the reducer. EventEnvelopes are built
/// by the Harness/Interpreter outside the reducer.
pub(all) enum KernelEvent {
  /// Emitted on the Start input. Exactly once per Run.
  RunStarted(details~ : StartedDetails)
  /// Emitted each time the reducer declares a `CallModel` effect.
  ModelStepStarted(model_step_id~ : ModelStepId, effect_id~ : EffectId)
  /// Emitted when a model completion is folded into the transcript.
  ModelStepCompleted(model_step_id~ : ModelStepId, completion_summary~ : String)
  /// Emitted when a tool batch is dispatched (one event per batch, not per
  /// tool). The per-call events are `ToolCompleted`.
  ToolBatchStarted(model_step_id~ : ModelStepId, call_ids~ : Array[CallId])
  /// Emitted per tool outcome (success, error, runtime failure or
  /// NotExecuted). The outcome tag IS the error status — there is no
  /// parallel `is_error` boolean (ADR §2.11).
  ToolCompleted(call_id~ : CallId, outcome~ : ToolOutcome)
  /// Emitted when entering the `Suspended` phase. Non-terminal.
  RunSuspended(
    requirement~ : SuspensionRequirement,
    model_step_id~ : ModelStepId
  )
  /// Emitted when leaving `Suspended` via `Resume`. Non-terminal.
  RunResumed(model_step_id~ : ModelStepId)
  /// Emitted when a `CancelOutstanding` effect is declared.
  CancelRequested(effect_ids~ : Array[EffectId], reason~ : CancelReason)
  /// Emitted when budget consumption crosses a configured limit.
  BudgetExhausted(dimension~ : BudgetDimension, consumed~ : Int, limit~ : Int)
  /// Emitted when an input is rejected (post-terminal, illegal-for-phase).
  /// Always non-terminal: rejections never change state.
  InputRejected(input_kind~ : String, reason~ : String)
  // ── Terminal events (exactly one per Run) ──
  /// Successful termination. Exactly once per Run.
  RunCompleted(
    final_message_summary~ : String,
    model_steps~ : Int,
    tool_calls~ : Int
  )
  /// Failed termination. Exactly once per Run.
  RunFailed(reason~ : FailureReason)
  /// Cancelled termination. Exactly once per Run.
  RunCancelled(reason~ : CancelReason)
} derive(Eq, Debug)

///|
/// Single-line summary, used by `Show` and any debug surface. Excludes raw
/// prompts, tool arguments and unbounded free-form labels.
pub impl Show for KernelEvent with fn to_string(self : KernelEvent) -> String {
  match self {
    RunStarted(details~) =>
      "RunStarted(run=\{details.run_id.to_string()}, session=\{details.session_id.to_string()})"
    ModelStepStarted(model_step_id~, effect_id~) =>
      "ModelStepStarted(step=\{model_step_id.to_int()}, effect=\{effect_id.to_int()})"
    ModelStepCompleted(model_step_id~, completion_summary~) =>
      "ModelStepCompleted(step=\{model_step_id.to_int()}, \{completion_summary})"
    ToolBatchStarted(model_step_id~, call_ids~) =>
      "ToolBatchStarted(step=\{model_step_id.to_int()}, \{call_ids.length()} calls)"
    ToolCompleted(call_id~, outcome~) =>
      "ToolCompleted(call=\{call_id.to_string()}, \{outcome.summary()})"
    RunSuspended(requirement~, model_step_id~) =>
      "RunSuspended(kind=\{requirement.kind}, step=\{model_step_id.to_int()})"
    RunResumed(model_step_id~) => "RunResumed(step=\{model_step_id.to_int()})"
    CancelRequested(effect_ids~, reason~) =>
      "CancelRequested(\{effect_ids.length()} effects, \{reason.to_string()})"
    BudgetExhausted(dimension~, consumed~, limit~) =>
      "BudgetExhausted(\{dimension.to_string()}, \{consumed}/\{limit})"
    InputRejected(input_kind~, reason~) =>
      "InputRejected(input=\{input_kind}, \{safe_event_label(reason)})"
    RunCompleted(final_message_summary~, model_steps~, tool_calls~) =>
      "RunCompleted(steps=\{model_steps}, tool_calls=\{tool_calls}, \{safe_event_label(final_message_summary)})"
    RunFailed(reason~) => "RunFailed(\{reason.to_string()})"
    RunCancelled(reason~) => "RunCancelled(\{reason.to_string()})"
  }
}

///|
/// Whether this event is terminal (one of RunCompleted/RunFailed/RunCancelled).
/// Used by conformance tests to assert exactly-once terminal semantics.
pub fn KernelEvent::is_terminal(self : KernelEvent) -> Bool {
  match self {
    RunCompleted(..) => true
    RunFailed(..) => true
    RunCancelled(..) => true
    _ => false
  }
}

///|
/// Internal bounded single-line label helper. Local copy mirrors
/// `safe_error_label` so this file has no production cross-file dependency.
fn safe_event_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}
