/// Run lifecycle branches: Start, phase gates, suspend/resume, cancel and terminal transitions.

///|
fn reduce_post_terminal(
  state : RunState,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  let event : KernelEvent = InputRejected(
    input_kind=input.kind(),
    reason="Run is already Terminal",
  )
  let next_state = state.transition(
    phase=Terminal,
    transcript=state.transcript(),
    pending_effects=[], // already empty
    next_event_sequence=next_seq(state),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=state.outcome(),
    completed_tool_results=Map::from_array([]),
    tool_call_positions=Map::from_array([]),
    suspension_requirement=None,
  )
  reduce_output(next_state, [], [event])
}

///|
fn reduce_initializing(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  match input {
    Start(payload~) => reduce_start(state, catalog, payload)
    _ => reject_input(state, input, "Initializing only accepts Start")
  }
}

///|
/// Handle the Start input: seed the transcript, emit RunStarted, transition to ReadyForModel.
fn reduce_start(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  payload : StartPayload,
) -> ReduceOutput raise KernelError {
  let transcript = @kernel.Transcript::from_array(payload.initial_messages)
  let run_started : KernelEvent = RunStarted(details=StartedDetails::{
    run_id: state.run_id(),
    session_id: state.session_id(),
  })
  let next_state = state.transition(
    phase=ReadyForModel,
    transcript~,
    pending_effects=[],
    next_event_sequence=next_seq(state),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=ModelStepId::first(),
    catalog_version=Some(payload.catalog_version),
    budget_consumed=state.budget_consumed(),
    outcome=None,
    suspension_requirement=None,
  )
  // The catalog passed in must match the catalog_version the host carried.
  // ADR §2.6: stale snapshot is a kernel invariant failure.
  if catalog.version() != payload.catalog_version {
    return reduce_invariant_violation(
      next_state,
      StaleSnapshot(expected=payload.catalog_version, actual=catalog.version()),
    )
  }
  reduce_output(next_state, [], [run_started])
}

///|
fn reduce_ready_for_model(
  state : RunState,
  _catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  match input {
    CancelRequested(payload~) => reduce_cancel_ready(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail(state, FailureReason::DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail(state, BudgetExhausted(dimension=payload.dimension))
    SuspendRequested(_) =>
      // No model in flight; nothing to suspend. Reject.
      reject_input(state, input, "ReadyForModel: nothing to suspend")
    ModelCompleted(_) | ModelFailed(_) | ToolCompleted(_) | ToolFailed(_) =>
      reject_input(state, input, "ReadyForModel: no pending effect to complete")
    Resume(_) => reject_input(state, input, "ReadyForModel: not suspended")
    Start(_) => reject_input(state, input, "ReadyForModel: already started")
    TranscriptRewrite(payload~) => reduce_transcript_rewrite(state, payload)
  }
}

///|
fn reduce_suspended(
  state : RunState,
  _catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  match input {
    Resume(_) => {
      let resumed : KernelEvent = RunResumed(
        model_step_id=state.current_model_step_id(),
      )
      let next_state = state.transition(
        phase=ReadyForModel,
        transcript=state.transcript(),
        pending_effects=[],
        next_event_sequence=next_seq(state),
        next_effect_id=state.next_effect_id(),
        current_model_step_id=state.current_model_step_id(),
        catalog_version=None,
        budget_consumed=state.budget_consumed(),
        outcome=None,
        suspension_requirement=None,
      )
      reduce_output(next_state, [], [resumed])
    }
    CancelRequested(payload~) => reduce_cancel_ready(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail(state, FailureReason::DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail(state, BudgetExhausted(dimension=payload.dimension))
    Start(_)
    | SuspendRequested(_)
    | ModelCompleted(_)
    | ModelFailed(_)
    | ToolCompleted(_)
    | ToolFailed(_)
    | TranscriptRewrite(_) =>
      // Suspended rejects ordinary completions explicitly (ADR §2.6).
      reject_input(
        state, input, "Suspended: only Resume/Cancel/Deadline/Budget legal",
      )
  }
}

///|
/// Enter Suspended from AwaitingModel. Drop the pending CallModel, emit CancelOutstanding, emit RunSuspended.
fn reduce_suspend(
  state : RunState,
  requirement : SuspensionRequirement,
) -> ReduceOutput raise KernelError {
  let pending = state.pending_effects()
  let effects : Array[Effect] = []
  let events : Array[KernelEvent] = []
  // Build a CancelOutstanding effect for the in-flight model effect.
  if !pending.is_empty() {
    let cancel_effect_id = state.next_effect_id()
    let cancel_payload : CancelOutstandingPayload = {
      effect_ids: FixedArray::from_array(pending.map(fn(e) { e.effect_id() })),
      reason: HostRequested(detail=None),
    }
    effects.push(
      CancelOutstanding(effect_id=cancel_effect_id, payload=cancel_payload),
    )
    events.push(
      CancelRequested(
        effect_ids=Array::from_iter(cancel_payload.effect_ids.iter()),
        reason=HostRequested(detail=None),
      ),
    )
  }
  events.push(
    RunSuspended(requirement~, model_step_id=state.current_model_step_id()),
  )
  let next_state = state.transition(
    phase=Suspended,
    transcript=state.transcript(),
    pending_effects=[],
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id().add(effects.length()),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=None,
    completed_tool_results=Map::from_array([]),
    tool_call_positions=Map::from_array([]),
    suspension_requirement=Some(requirement),
  )
  reduce_output(next_state, effects.copy(), events)
}

///|
/// Cancel when no pending effects (ReadyForModel, Suspended). Just terminate.
fn reduce_cancel_ready(
  state : RunState,
  detail : String?,
) -> ReduceOutput raise KernelError {
  let reason : CancelReason = HostRequested(detail~)
  reduce_terminal_cancel(state, reason)
}

///|
/// Cancel when there are pending effects (AwaitingModel, AwaitingTools).
/// Emit CancelOutstanding for them, then terminate.
fn reduce_cancel_with_pending(
  state : RunState,
  detail : String?,
) -> ReduceOutput raise KernelError {
  let pending = state.pending_effects()
  let reason : CancelReason = HostRequested(detail~)
  let effects : Array[Effect] = []
  let events : Array[KernelEvent] = []
  if !pending.is_empty() {
    let cancel_effect_id = state.next_effect_id()
    let cancel_payload : CancelOutstandingPayload = {
      effect_ids: FixedArray::from_array(pending.map(fn(e) { e.effect_id() })),
      reason,
    }
    effects.push(
      CancelOutstanding(effect_id=cancel_effect_id, payload=cancel_payload),
    )
    events.push(
      CancelRequested(
        effect_ids=Array::from_iter(cancel_payload.effect_ids.iter()),
        reason~,
      ),
    )
  }
  let terminal_state = state.transition(
    phase=Terminal,
    transcript=state.transcript(),
    pending_effects=[],
    next_event_sequence=advance_seq_by(state, events.length() + 1),
    next_effect_id=state.next_effect_id().add(effects.length()),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=Some(Cancelled(reason~)),
    completed_tool_results=Map::from_array([]),
    tool_call_positions=Map::from_array([]),
    suspension_requirement=None,
  )
  events.push(RunCancelled(reason~))
  reduce_output(terminal_state, effects.copy(), events)
}

///|
/// Terminate the Run with Failed. Clears pending effects, emits RunFailed.
fn reduce_terminal_fail(
  state : RunState,
  reason : FailureReason,
) -> ReduceOutput raise KernelError {
  reduce_terminal_fail_with(
    state,
    state.transcript(),
    state.budget_consumed(),
    reason,
    [],
  )
}

///|
/// Terminate the Run with Failed, optionally with extra events to emit
/// before the terminal event and a custom transcript/budget.
fn reduce_terminal_fail_with(
  state : RunState,
  transcript : @kernel.Transcript,
  budget_consumed : BudgetConsumed,
  reason : FailureReason,
  pre_events : Array[KernelEvent],
  completed_tool_results? : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int),
  ] = Map::from_array([]),
  tool_call_positions? : Map[String, Int] = Map::from_array([]),
) -> ReduceOutput raise KernelError {
  let events : Array[KernelEvent] = []
  for e in pre_events {
    events.push(e)
  }
  let terminal_state = state.transition(
    phase=Terminal,
    transcript~,
    pending_effects=[],
    next_event_sequence=advance_seq_by(state, events.length() + 1),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed~,
    outcome=Some(Failed(reason~)),
    completed_tool_results~,
    tool_call_positions~,
    suspension_requirement=None,
  )
  events.push(RunFailed(reason~))
  reduce_output(terminal_state, [], events)
}

///|
/// Terminate the Run with Cancelled.
fn reduce_terminal_cancel(
  state : RunState,
  reason : CancelReason,
) -> ReduceOutput raise KernelError {
  let terminal_state = state.transition(
    phase=Terminal,
    transcript=state.transcript(),
    pending_effects=[],
    next_event_sequence=next_seq(state),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=Some(Cancelled(reason~)),
    completed_tool_results=Map::from_array([]),
    tool_call_positions=Map::from_array([]),
    suspension_requirement=None,
  )
  reduce_output(terminal_state, [], [RunCancelled(reason~)])
}

///|
/// Convert a kernel-invariant violation to terminal Failed. Never silently downgraded (ADR §2.4).
fn reduce_invariant_violation(
  state : RunState,
  category : InvariantCategory,
) -> ReduceOutput raise KernelError {
  reduce_terminal_fail(state, InvariantViolation(category~))
}

///|
fn reject_input(
  state : RunState,
  input : RunInput,
  reason : String,
) -> ReduceOutput raise KernelError {
  let event : KernelEvent = InputRejected(input_kind=input.kind(), reason~)
  let next_state = state.transition(
    phase=state.phase(),
    transcript=state.transcript(),
    pending_effects=state.pending_effects(),
    next_event_sequence=next_seq(state),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=state.outcome(),
    suspension_requirement=state.suspension_requirement(),
  )
  reduce_output(next_state, [], [event])
}

///|
/// Fold a host-side transcript rewrite (pre-model hook chain, compact
/// Replace/Append) into state. The reducer is the sole transcript writer:
/// the pump submits the rewritten messages as an input and this branch
/// commits them with a `TranscriptRewritten` event so the journal records
/// the fact. Phase, pending effects and budget are untouched; the event
/// sequence advances by one.
fn reduce_transcript_rewrite(
  state : RunState,
  payload : TranscriptRewritePayload,
) -> ReduceOutput raise KernelError {
  let transcript = @kernel.Transcript::from_array(payload.rewritten_messages)
  let event : KernelEvent = TranscriptRewritten(
    messages_before=state.transcript().length(),
    messages_after=transcript.length(),
    reason=payload.reason,
  )
  // A rewrite while tools are in flight may have moved or removed the
  // assistant message that owns the pending calls. Rebuild the source-position
  // ledger from the new transcript so the wave commit can still order results
  // by source position.
  let new_positions = match state.phase() {
    AwaitingTools => build_tool_call_ledger(transcript)
    _ => Map::from_array([])
  }
  let next_state = state.transition(
    phase=state.phase(),
    transcript~,
    pending_effects=state.pending_effects(),
    next_event_sequence=next_seq(state),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    // The rewrite changed the transcript the last usage reading described:
    // occupancy is unknown until the next reliable observation. Cumulative
    // counters stay — the run-wide token budget is unaffected by compaction.
    budget_consumed={ ..state.budget_consumed(), last_context_tokens: None, },
    outcome=state.outcome(),
    tool_call_positions=new_positions,
    suspension_requirement=state.suspension_requirement(),
  )
  reduce_output(next_state, [], [event])
}
