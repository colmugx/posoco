///|
/// KernelEvent — pure domain events emitted by the reducer.
/// Events are unstamped (wall-clock added externally) for replay equality.
/// Terminal events appear at most once per Run.

// Run-level events

///|
/// Emitted when the reducer first transitions out of `Initializing` (the
/// `Start` input). The `RunStarted` event is non-terminal.
///
/// `RunStarted` is the product's sole start event.
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

// KernelEvent ADT

///|
/// A single domain event declared by the reducer. EventEnvelopes are built
/// by the Puppet/Interpreter outside the reducer.
pub(all) enum KernelEvent {
  /// Emitted on the Start input. Exactly once per Run.
  RunStarted(details~ : StartedDetails)
  /// Emitted each time the reducer declares a `CallModel` effect.
  ModelStepStarted(model_step_id~ : ModelStepId, effect_id~ : EffectId)
  /// Emitted when a model completion is folded into the transcript. Carries
  /// the same canonical completion committed by the reducer so ordered
  /// subscribers do not need to reconstruct it from the transcript.
  ModelStepCompleted(
    model_step_id~ : ModelStepId,
    completion~ : @kernel.Completion
  )
  /// Emitted when a tool batch is dispatched (one event per batch, not per
  /// tool). The calls retain their names and parsed arguments so a committed
  /// product subscriber can render the exact pending work without querying a
  /// second routing cache. The journal payload deliberately stores only a
  /// count; arguments never enter durable diagnostic summaries.
  ToolBatchStarted(
    model_step_id~ : ModelStepId,
    calls~ : Array[@kernel.ToolCall]
  )
  /// Emitted per tool outcome (success, error, runtime failure or
  /// NotExecuted). The outcome tag IS the error status — there is no
  /// parallel `is_error` boolean (ADR §2.11).
  ToolCompleted(call_id~ : @kernel.CallId, outcome~ : @kernel.ToolOutcome)
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
  /// Emitted when a host-side transcript rewrite (pre-model hook chain,
  /// compact Replace/Append) is folded into state. Carries only counts and
  /// the producer reason — message bodies never enter durable diagnostic
  /// summaries, same rule as `ToolBatchStarted`.
  TranscriptRewritten(
    messages_before~ : Int,
    messages_after~ : Int,
    reason~ : String
  )
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
    ModelStepCompleted(model_step_id~, completion~) =>
      "ModelStepCompleted(step=\{model_step_id.to_int()}, \{completion_summary(completion)})"
    ToolBatchStarted(model_step_id~, calls~) =>
      "ToolBatchStarted(step=\{model_step_id.to_int()}, \{calls.length()} calls)"
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
    TranscriptRewritten(messages_before~, messages_after~, reason~) =>
      "TranscriptRewritten(\{messages_before}->\{messages_after} messages, \{safe_event_label(reason)})"
    RunCompleted(final_message_summary~, model_steps~, tool_calls~) =>
      "RunCompleted(steps=\{model_steps}, tool_calls=\{tool_calls}, \{safe_event_label(final_message_summary)})"
    RunFailed(reason~) => "RunFailed(\{reason.to_string()})"
    RunCancelled(reason~) => "RunCancelled(\{reason.to_string()})"
  }
}

///|
/// Whether this event is terminal (one of RunCompleted/RunFailed/RunCancelled).
/// Used by conformance tests to assert exactly-once terminal semantics.
///
/// Contract: the classifier agrees with the structural spec predicate
/// `is_terminal_event` (event_proof.mbtp) on every event — the anchor for
/// the "exactly one terminal event per Run" theorem. `RunSuspended`
/// (quiescent, non-terminal) and `InputRejected` (never terminal, never
/// state-changing) are deliberately excluded.
/// (Body patterns use explicit `label = _` wildcards — the proof frontend
/// rejects `..` rest patterns inside contracted function bodies.)
pub fn KernelEvent::is_terminal(
  self : KernelEvent,
) -> Bool where {
  proof_ensure: result => result == is_terminal_event(self),
} {
  match self {
    RunCompleted(final_message_summary=_, model_steps=_, tool_calls=_) => true
    RunFailed(reason=_) => true
    RunCancelled(reason=_) => true
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
