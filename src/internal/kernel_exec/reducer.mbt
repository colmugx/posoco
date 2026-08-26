///|
/// Pure reducer for the functional Kernel (ADR §2.1, §2.2, §2.5).
///
/// This file is the SOLE arbiter of phase transitions. Given a RunState and
/// a RunInput, the reducer returns the next RunState, the effects the
/// executor should run next, and the domain events the interpreter should
/// publish. The reducer MUST NOT:
/// - import async, fs, http, time, or random
/// - import any host or provider trait
/// - import non-canonical product data — it works only on canonical domain
///   types
/// - mutate caller-owned arrays/maps
///
/// Purity is enforced by a boundary lint in T03/T09 acceptance.

///|
/// Result of a single `reduce(state, input)` call.
/// `next_state` is the new RunState, `effects` are effects to execute, `events` are domain events to publish.
/// Terminal events appear at most once per Run. Invariant violations become a typed `Terminal(Failed)` transition.
pub(all) struct ReduceOutput {
  next_state : RunState
  effects : Array[Effect]
  events : Array[KernelEvent]
} derive(Eq, Debug)

///|
/// Construct a ReduceOutput. Internal helper used by the reducer branches.
fn reduce_output(
  next_state : RunState,
  effects : Array[Effect],
  events : Array[KernelEvent],
) -> ReduceOutput {
  { next_state, effects, events }
}

///|
pub fn ReduceOutput::next_state(self : ReduceOutput) -> RunState {
  self.next_state
}

///|
pub fn ReduceOutput::effects(self : ReduceOutput) -> Array[Effect] {
  self.effects.copy()
}

///|
pub fn ReduceOutput::events(self : ReduceOutput) -> Array[KernelEvent] {
  self.events.copy()
}

///|
pub impl Show for ReduceOutput with fn to_string(self : ReduceOutput) -> String {
  let effect_summaries = self.effects.map(fn(e) { e.to_string() })
  let event_summaries = self.events.map(fn(e) { e.to_string() })
  "ReduceOutput(state=\{self.next_state.to_string()}, effects=[\{effect_summaries.join(", ")}], events=[\{event_summaries.join(", ")}])"
}

///|
/// The reducer. Pure: same (state, input) → same (next_state, effects, events).
/// The catalog is passed separately because the RunState does not own it.
pub fn reduce(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  // Post-terminal rejection: any input after Terminal is a typed rejection.
  // The state is unchanged; no new terminal event is emitted; the
  // transcript is not mutated. (ADR §2.5 rule 1, §2.6 late-completion rule.)
  match state.phase() {
    Terminal => reduce_post_terminal(state, input)
    Initializing => reduce_initializing(state, catalog, input)
    ReadyForModel => reduce_ready_for_model(state, catalog, input)
    AwaitingModel => reduce_awaiting_model(state, catalog, input)
    AwaitingTools => reduce_awaiting_tools(state, catalog, input)
    Suspended => reduce_suspended(state, catalog, input)
  }
}

///|
/// Allocate the next event sequence number.
fn next_seq(state : RunState) -> EventSequence {
  state.next_event_sequence().next()
}

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
/// Issue a CallModel effect. Allocates a fresh EffectId and ModelStepId, builds the payload
/// from the current transcript + catalog, transitions to AwaitingModel.
/// This is NOT called via `reduce(state, catalog, input)` — the host/driver decides when
/// to advance; the reducer only writes state.
pub fn run_model_step(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  call_options : Json,
) -> ReduceOutput raise KernelError {
  match state.phase() {
    ReadyForModel => {
      let step_id = state.current_model_step_id()
      let effect_id = state.next_effect_id()
      let payload : CallModelPayload = {
        model_step_id: step_id,
        messages: FixedArray::from_array(state.transcript().messages_snapshot()),
        catalog_version: catalog.version(),
        call_options,
      }
      let effect : Effect = CallModel(effect_id~, payload~)
      let started : KernelEvent = ModelStepStarted(
        model_step_id=step_id,
        effect_id~,
      )
      let next_state = state.transition(
        phase=AwaitingModel,
        transcript=state.transcript(),
        pending_effects=[effect],
        next_event_sequence=next_seq(state),
        next_effect_id=effect_id.next(),
        current_model_step_id=step_id,
        catalog_version=None,
        budget_consumed=state.budget_consumed(),
        outcome=None,
        suspension_requirement=None,
      )
      reduce_output(next_state, [effect], [started])
    }
    _ =>
      raise IllegalTransition(
        run_id=state.run_id(),
        phase=state.phase().to_string(),
        input_kind="run_model_step",
        detail="run_model_step only valid in ReadyForModel",
      )
  }
}

///|
fn reduce_awaiting_model(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  // Race priority (ADR §2.5):
  // 1. DeadlineReached beats completions for the same tick.
  // 2. CancelRequested beats completion only if cancel was queued earlier;
  //    for M1 we treat the input order at the reducer as already-decided, so
  //    we apply each input as it arrives (no batching). Therefore: at the
  //    reducer, if the input IS DeadlineReached, terminate Failed; if it IS
  //    CancelRequested, terminate Cancelled; if it IS a completion, fold it.
  match input {
    ModelCompleted(payload~) => reduce_model_completed(state, catalog, payload)
    ModelFailed(payload~) => reduce_model_failed(state, payload)
    CancelRequested(payload~) =>
      reduce_cancel_with_pending(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail(state, FailureReason::DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail(state, BudgetExhausted(dimension=payload.dimension))
    SuspendRequested(payload~) => reduce_suspend(state, payload.requirement)
    TranscriptRewrite(payload~) => reduce_transcript_rewrite(state, payload)
    Start(_) | Resume(_) | ToolCompleted(_) | ToolFailed(_) =>
      reject_input(state, input, "AwaitingModel: input not legal here")
  }
}

///|
/// Fold a successful model completion into the state.
fn reduce_model_completed(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  payload : ModelCompletedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation: the effect_id must match the single pending CallModel.
  let pending = state.pending_effects()
  let pending_id = match pending[0] {
    CallModel(effect_id~, ..) => effect_id
    _ =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingModel",
          detail="pending effect is not CallModel",
        ),
      )
  }
  if pending_id != payload.effect_id {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  if payload.model_step_id != state.current_model_step_id() {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let completion = payload.completion
  // Length finish reason → terminal failure (ADR §2.7).
  match completion.finish_reason() {
    @kernel.Length =>
      return reduce_terminal_fail(
        append_completion_to_state(state, completion),
        FailureReason::ModelParseFailure(detail="finish_reason=Length"),
      )
    _ => ()
  }
  let assistant_msg = @kernel.AssistantMessage(
    content=completion.message.content.copy(),
    tool_calls=completion.message.tool_calls.copy(),
    reasoning=completion.message.reasoning,
    finish_reason=completion.message.finish_reason,
  )
  // Replace transcript body with what the modelport actually sent (it may have elided entries),
  // then append the new assistant message. No-op when no preprocessing occurred.
  let base_transcript = @kernel.Transcript::from_array(
    payload.processed_messages,
  )
  let transcript = base_transcript.append(assistant_msg)
  let step_completed : KernelEvent = ModelStepCompleted(
    model_step_id=payload.model_step_id,
    completion~,
  )
  // budget: model_steps + 1, tool_rounds unchanged, usage if any.
  let next_consumed = bump_model_step(state.budget_consumed(), completion.usage)
  let usage_check = next_consumed.exceeded(state.budget())
  match usage_check {
    Exceeded(dim) =>
      return reduce_terminal_fail_with(
        state,
        transcript,
        next_consumed,
        BudgetExhausted(dimension=dim),
        [
          step_completed,
          BudgetExhausted(
            dimension=dim,
            consumed=consumed_for_dim(next_consumed, dim),
            limit=limit_for_dim(state.budget(), dim),
          ),
        ],
      )
    UnknownUsage(_) | WithinBudget => ()
  }
  // No tool calls → terminal Completed (single-step run).
  if !completion.has_tool_calls() {
    let final_msg = @kernel.AssistantMessage(
      content=completion.message.content.copy(),
      tool_calls=[],
      reasoning=completion.message.reasoning,
      finish_reason=completion.message.finish_reason,
    )
    let terminal_state = state.transition(
      phase=Terminal,
      transcript~,
      pending_effects=[],
      next_event_sequence=next_seq(state).next(),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=payload.model_step_id,
      catalog_version=None,
      budget_consumed=next_consumed,
      outcome=Some(
        Completed(
          final_message=final_msg,
          tool_results=tool_outcomes(state.tool_results),
        ),
      ),
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let terminal_event : KernelEvent = RunCompleted(
      final_message_summary=completion_summary(completion),
      model_steps=next_consumed.model_steps,
      tool_calls=0,
    )
    return reduce_output(terminal_state, [], [step_completed, terminal_event])
  }
  // Tool calls: validate each (unknown name → NotExecuted; schema mismatch
  // → NotExecuted). Build a list of (call, NotExecuted outcome OR ExecuteTool
  // effect). For M1, ALL validated calls go into a SINGLE AwaitingTools
  // batch (the scheduler's waves are a driver concern; the reducer just
  // declares effects).
  reduce_model_completed_with_tools(
    state, catalog, payload, completion, transcript, next_consumed, step_completed,
  )
}

///|
/// Continue model-completed handling once we know there are tool calls.
fn reduce_model_completed_with_tools(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  payload : ModelCompletedPayload,
  completion : @kernel.Completion,
  initial_transcript : @kernel.Transcript,
  next_consumed : BudgetConsumed,
  step_completed : KernelEvent,
) -> ReduceOutput raise KernelError {
  let events : Array[KernelEvent] = [step_completed]
  let effects : Array[Effect] = []
  let mut transcript = initial_transcript
  let mut tool_results = state.tool_results_snapshot()
  // Source-position ledger for the current wave: built once here, used for
  // all tool completions in this wave instead of rescanning per result.
  let tool_call_positions = build_tool_call_ledger(transcript)
  let calls = completion.tool_calls()
  // Pre-pass: split into NotExecuted outcomes (written to transcript) and
  // validated calls (become ExecuteTool effects). Duplicate call_id is an
  // invariant failure.
  let seen : Map[String, Unit] = Map::from_array([])
  for call in calls {
    let id_str = call.call_id.to_string()
    if seen.contains(id_str) {
      return reduce_invariant_violation(
        state,
        DuplicateCallId(call_id=call.call_id),
      )
    }
    seen[id_str] = ()
    // Unknown tool → NotExecuted(UnknownTool)
    if !catalog.contains(call.name) {
      let outcome : @kernel.ToolOutcome = @kernel.NotExecuted(
        reason=@kernel.UnknownTool,
        original_call_id=call.call_id,
      )
      transcript = insert_tool_message_in_source_order(
        transcript,
        call.call_id,
        call.name,
        outcome,
      )
      tool_results = insert_tool_result_in_source_order(
        transcript,
        tool_results,
        call.call_id,
        outcome,
      )
      events.push(ToolCompleted(call_id=call.call_id, outcome~))
    } else {
      // Schema validation against the catalog.
      match catalog.validate_arguments(call.name, call.arguments) {
        Err(diag) =>
          if is_unknown_tool_diagnostic(diag) {
            // Should be unreachable (we checked contains above), but be safe.
            let outcome : @kernel.ToolOutcome = @kernel.NotExecuted(
              reason=@kernel.UnknownTool,
              original_call_id=call.call_id,
            )
            transcript = insert_tool_message_in_source_order(
              transcript,
              call.call_id,
              call.name,
              outcome,
            )
            tool_results = insert_tool_result_in_source_order(
              transcript,
              tool_results,
              call.call_id,
              outcome,
            )
            events.push(ToolCompleted(call_id=call.call_id, outcome~))
          } else {
            let outcome : @kernel.ToolOutcome = @kernel.NotExecuted(
              reason=@kernel.SchemaMismatch(
                json_path=diag.json_path,
                expected=diag.expected,
                actual=diag.actual,
              ),
              original_call_id=call.call_id,
            )
            transcript = insert_tool_message_in_source_order(
              transcript,
              call.call_id,
              call.name,
              outcome,
            )
            tool_results = insert_tool_result_in_source_order(
              transcript,
              tool_results,
              call.call_id,
              outcome,
            )
            events.push(ToolCompleted(call_id=call.call_id, outcome~))
          }
        Ok(_) =>
          // Valid call → ExecuteTool effect.
          match catalog.find(call.name) {
            Some(entry) => {
              let effect_id = state.next_effect_id().add(effects.length())
              let exec_payload : ExecuteToolPayload = {
                model_step_id: payload.model_step_id,
                call_id: call.call_id,
                tool_name: call.name,
                arguments: call.arguments,
                owner: entry.definition.owner,
                catalog_version: catalog.version(),
              }
              effects.push(ExecuteTool(effect_id~, payload=exec_payload))
            }
            None =>
              // Unreachable: contains() returned true above. Treat as
              // invariant violation with a synthetic diagnostic owner.
              return reduce_invariant_violation(
                state,
                MissingOwner(owner=@kernel.OwnerId::unchecked("(unknown)")),
              )
          }
      }
    }
  }
  // All calls were NotExecuted? Then no ExecuteTool was declared. Continue
  // back to ReadyForModel so the host/driver can issue the next model step
  // (the model needs to see its own rejected calls).
  if effects.is_empty() {
    let next_state = state.transition(
      phase=ReadyForModel,
      transcript~,
      pending_effects=[],
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=payload.model_step_id.next(),
      catalog_version=None,
      budget_consumed=next_consumed,
      outcome=None,
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let next_state = next_state.with_tool_results(tool_results)
    return reduce_output(next_state, [], events)
  }
  // Account for the entire executable batch before exposing any effect to the
  // host. This makes the tool limits atomic: a batch that reaches a limit
  // cannot partially execute, and parallel waves cannot bypass accounting.
  let next_tool_consumed = bump_tool_batch(next_consumed, effects.length())
  match next_tool_consumed.exceeded(state.budget()) {
    Exceeded(dim) => {
      events.push(
        BudgetExhausted(
          dimension=dim,
          consumed=consumed_for_dim(next_tool_consumed, dim),
          limit=limit_for_dim(state.budget(), dim),
        ),
      )
      return reduce_terminal_fail_with(
        state,
        transcript,
        next_tool_consumed,
        BudgetExhausted(dimension=dim),
        events,
        completed_tool_results=Map::from_array([]),
        tool_call_positions=Map::from_array([]),
      )
    }
    UnknownUsage(_) | WithinBudget => ()
  }
  // Emit ToolBatchStarted covering only the calls that became effects.
  let batch_calls : Array[@kernel.ToolCall] = []
  for e in effects {
    match e {
      ExecuteTool(payload~, ..) =>
        batch_calls.push({
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        })
      _ => ()
    }
  }
  events.push(
    ToolBatchStarted(model_step_id=payload.model_step_id, calls=batch_calls),
  )
  let next_state = state.transition(
    phase=AwaitingTools,
    transcript~,
    pending_effects=effects.copy(),
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id().add(effects.length()),
    current_model_step_id=payload.model_step_id,
    catalog_version=None,
    budget_consumed=next_tool_consumed,
    outcome=None,
    completed_tool_results=Map::from_array([]),
    tool_call_positions~,
    suspension_requirement=None,
  )
  let next_state = next_state.with_tool_results(tool_results)
  reduce_output(next_state, effects.copy(), events)
}

///|
fn reduce_model_failed(
  state : RunState,
  payload : ModelFailedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation check.
  let pending = state.pending_effects()
  let pending_id = match pending[0] {
    CallModel(effect_id~, ..) => effect_id
    _ =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingModel",
          detail="pending effect is not CallModel",
        ),
      )
  }
  if pending_id != payload.effect_id {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let reason : FailureReason = match payload.failure {
    @kernel.RequestBuild(reason~) => ModelParseFailure(detail=reason)
    @kernel.Transport(reason~) => ModelTransport(detail=reason)
    @kernel.Runtime(reason~) => ModelRuntime(detail=reason)
    @kernel.Parse(reason~) => ModelParseFailure(detail=reason)
    @kernel.HostRejected(reason~) => FailureReason::HostRejected(detail=reason)
    @kernel.RateLimited(reason~, ..) => ModelQuotaExhausted(detail=reason)
  }
  reduce_terminal_fail(state, reason)
}

///|
fn reduce_awaiting_tools(
  state : RunState,
  _catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  match input {
    ToolCompleted(payload~) => reduce_tool_completed(state, payload)
    ToolFailed(payload~) => reduce_tool_failed(state, payload)
    CancelRequested(payload~) =>
      reduce_cancel_with_pending(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail(state, FailureReason::DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail(state, BudgetExhausted(dimension=payload.dimension))
    SuspendRequested(_) =>
      reject_input(
        state, input, "AwaitingTools: tools in flight; cannot suspend",
      )
    TranscriptRewrite(payload~) => reduce_transcript_rewrite(state, payload)
    Start(_) | Resume(_) | ModelCompleted(_) | ModelFailed(_) =>
      reject_input(state, input, "AwaitingTools: input not legal here")
  }
}

///|
/// Fold a tool completion into state. When the last pending effect is
/// resolved, transition to ReadyForModel.
fn reduce_tool_completed(
  state : RunState,
  payload : ToolCompletedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation: find the matching ExecuteTool in pending.
  let pending = state.pending_effects()
  let mut found = false
  let mut matched_tool_name : @kernel.ToolName? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_tool_name = Some(ep.tool_name)
        }
      _ => ()
    }
  }
  if !found {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let tool_name = match matched_tool_name {
    Some(n) => n
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, payload.outcome, position)
  let event : KernelEvent = ToolCompleted(
    call_id=payload.call_id,
    outcome=payload.outcome,
  )
  let events = [event]
  if new_pending.is_empty() {
    // Wave boundary: commit all staged outcomes to the transcript and
    // tool-result ledger in one source-ordered rebuild, then return to
    // ReadyForModel. Tool consumption was already recorded atomically when
    // the reducer declared this batch's ExecuteTool effects.
    let (committed_transcript, committed_tool_results) = commit_tool_wave(
      state.transcript(),
      state.tool_call_positions,
      staged,
      state.tool_results_snapshot(),
    )
    let next_state = state.transition(
      phase=ReadyForModel,
      transcript=committed_transcript,
      pending_effects=[],
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=None,
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let next_state = next_state.with_tool_results(committed_tool_results)
    return reduce_output(next_state, [], events)
  }
  let next_state = state.transition(
    phase=AwaitingTools,
    transcript=state.transcript(),
    pending_effects=new_pending,
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=None,
    completed_tool_results=staged,
    tool_call_positions=state.tool_call_positions.copy(),
    suspension_requirement=None,
  )
  reduce_output(next_state, [], events)
}

///|
/// Tool failed (runtime or invariant failure). Runtime failures become a
/// `ToolOutcome::RuntimeFailure` and the Run continues. Invariant failures
/// terminate the Run with Failed.
fn reduce_tool_failed(
  state : RunState,
  payload : ToolFailedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation check.
  let pending = state.pending_effects()
  let mut found = false
  let mut matched_tool_name : @kernel.ToolName? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_tool_name = Some(ep.tool_name)
        }
      _ => ()
    }
  }
  if !found {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  // Invariant failure → terminal Failed.
  match payload.invariant_failure {
    Some(category) =>
      return reduce_terminal_fail(state, InvariantViolation(category~))
    None => ()
  }
  // Runtime failure: build RuntimeFailure outcome and continue.
  let (cat, msg) = match payload.runtime {
    Some(f) =>
      match f {
        @kernel.Transport(reason~) => ("Transport", reason)
        @kernel.Runtime(reason~) => ("Runtime", reason)
        @kernel.Parse(reason~) => ("Parse", reason)
        @kernel.RequestBuild(reason~) => ("RequestBuild", reason)
        @kernel.HostRejected(reason~) => ("HostRejected", reason)
        @kernel.RateLimited(reason~, ..) => ("RateLimited", reason)
      }
    None => ("Unknown", "no runtime detail supplied")
  }
  let outcome : @kernel.ToolOutcome = @kernel.RuntimeFailure(
    error_category=cat,
    message=msg,
  )
  let tool_name = match matched_tool_name {
    Some(n) => n
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, outcome, position)
  let event : KernelEvent = ToolCompleted(call_id=payload.call_id, outcome~)
  let events = [event]
  if new_pending.is_empty() {
    let (committed_transcript, committed_tool_results) = commit_tool_wave(
      state.transcript(),
      state.tool_call_positions,
      staged,
      state.tool_results_snapshot(),
    )
    let next_state = state.transition(
      phase=ReadyForModel,
      transcript=committed_transcript,
      pending_effects=[],
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=None,
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let next_state = next_state.with_tool_results(committed_tool_results)
    return reduce_output(next_state, [], events)
  }
  let next_state = state.transition(
    phase=AwaitingTools,
    transcript=state.transcript(),
    pending_effects=new_pending,
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=None,
    completed_tool_results=staged,
    tool_call_positions=state.tool_call_positions.copy(),
    suspension_requirement=None,
  )
  reduce_output(next_state, [], events)
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
    budget_consumed={ ..state.budget_consumed(), last_context_tokens: None },
    outcome=state.outcome(),
    tool_call_positions=new_positions,
    suspension_requirement=state.suspension_requirement(),
  )
  reduce_output(next_state, [], [event])
}

///|
fn append_completion_to_state(
  state : RunState,
  completion : @kernel.Completion,
) -> RunState raise KernelError {
  let msg = @kernel.AssistantMessage(
    content=completion.message.content.copy(),
    tool_calls=completion.message.tool_calls.copy(),
    reasoning=completion.message.reasoning,
    finish_reason=completion.message.finish_reason,
  )
  state.transition(
    phase=state.phase(),
    transcript=state.transcript().append(msg),
    pending_effects=state.pending_effects(),
    next_event_sequence=state.next_event_sequence(),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=state.outcome(),
    suspension_requirement=state.suspension_requirement(),
  )
}

///|
fn completion_summary(completion : @kernel.Completion) -> String {
  let n_tools = completion.message.tool_calls.length()
  let finish = safe_event_label(completion.finish_reason().to_string())
  let reasoning = match completion.message.reasoning {
    Some(_) => ", reasoning=present"
    None => ""
  }
  "finish=\{finish}, tool_calls=\{n_tools}\{reasoning}"
}

///|
fn advance_seq_by(state : RunState, n : Int) -> EventSequence {
  let mut s = state.next_event_sequence()
  for i = 0; i < n; i = i + 1 {
    s = s.next()
  }
  s
}

///|
fn bump_model_step(
  consumed : BudgetConsumed,
  usage : @kernel.Usage?,
) -> BudgetConsumed {
  let model_steps = consumed.model_steps + 1
  match usage {
    Some(u) => {
      let added = match u.total_tokens {
        Some(n) => n
        None => 0
      }
      {
        model_steps,
        tool_rounds: consumed.tool_rounds,
        tool_calls: consumed.tool_calls,
        observed_total_tokens: consumed.observed_total_tokens + added,
        any_usage_verified: consumed.any_usage_verified ||
        u.total_tokens is Some(_),
        last_context_tokens: usage_context_occupancy(u),
      }
    }
    None =>
      // A step without usage leaves the context size unknown: the transcript
      // has grown since the last reliable reading, so the stale one must go.
      {
        model_steps,
        tool_rounds: consumed.tool_rounds,
        tool_calls: consumed.tool_calls,
        observed_total_tokens: consumed.observed_total_tokens,
        any_usage_verified: consumed.any_usage_verified,
        last_context_tokens: None,
      }
  }
}

///|
/// Context occupancy of one call from its usage: `total_tokens` when
/// reported, else `input_tokens + output_tokens` when both are. Partial
/// readings (only one of input/output) are not a reliable size — stay
/// unknown rather than guessing low.
fn usage_context_occupancy(u : @kernel.Usage) -> Int? {
  match u.total_tokens {
    Some(total) => Some(total)
    None =>
      match (u.input_tokens, u.output_tokens) {
        (Some(input), Some(output)) => Some(input + output)
        _ => None
      }
  }
}

///|
fn bump_tool_batch(
  consumed : BudgetConsumed,
  executable_calls : Int,
) -> BudgetConsumed {
  // This helper is only called after validation established a non-empty
  // ExecuteTool batch. Count when effects are declared, never as individual
  // completions arrive: completion order is nondeterministic under parallel
  // execution and must not alter budget accounting.
  {
    model_steps: consumed.model_steps,
    tool_rounds: consumed.tool_rounds + 1,
    tool_calls: consumed.tool_calls + executable_calls,
    observed_total_tokens: consumed.observed_total_tokens,
    any_usage_verified: consumed.any_usage_verified,
    last_context_tokens: consumed.last_context_tokens,
  }
}

///|
fn consumed_for_dim(consumed : BudgetConsumed, dim : BudgetDimension) -> Int {
  match dim {
    ModelSteps => consumed.model_steps
    ToolRounds => consumed.tool_rounds
    ToolCalls => consumed.tool_calls
    TotalTokens => consumed.observed_total_tokens
  }
}

///|
fn limit_for_dim(budget : Budget, dim : BudgetDimension) -> Int {
  match dim {
    ModelSteps =>
      match budget.max_model_steps {
        Some(n) => n
        None => 0
      }
    ToolRounds =>
      match budget.max_tool_rounds {
        Some(n) => n
        None => 0
      }
    ToolCalls =>
      match budget.max_tool_calls {
        Some(n) => n
        None => 0
      }
    TotalTokens =>
      match budget.max_total_tokens {
        Some(n) => n
        None => 0
      }
  }
}

///|
fn remove_execute_tool_effect(
  effects : Array[Effect],
  effect_id : EffectId,
) -> Array[Effect] {
  let out : Array[Effect] = []
  for e in effects {
    let keep = match e {
      ExecuteTool(effect_id=eid, ..) => eid != effect_id
      _ => true
    }
    if keep {
      out.push(e)
    }
  }
  out
}

///|
/// Return the stable source position of a tool call in the canonical
/// transcript. Positions span all assistant messages in the Run, so results
/// from multiple tool rounds remain deterministic as well as results within a
/// parallel batch.
fn tool_call_position(
  transcript : @kernel.Transcript,
  call_id : @kernel.CallId,
) -> Int? {
  let mut position = 0
  let mut found : Int? = None
  for message in transcript.messages_snapshot() {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.call_id == call_id {
            found = Some(position)
          }
          position = position + 1
        }
      _ => ()
    }
  }
  found
}

///|
/// Insert a completed tool message next to the assistant message that
/// requested it, ordered by the model's source call order rather than host
/// completion order.
fn insert_tool_message_in_source_order(
  transcript : @kernel.Transcript,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  outcome : @kernel.ToolOutcome,
) -> @kernel.Transcript {
  let messages = transcript.messages_snapshot()
  let target_position = match tool_call_position(transcript, call_id) {
    Some(position) => position
    None =>
      return transcript.append(
        @kernel.ToolMessage(call_id~, tool_name~, outcome~),
      )
  }
  let mut assistant_index : Int? = None
  for i, message in messages {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.call_id == call_id {
            assistant_index = Some(i)
          }
        }
      _ => ()
    }
  }
  let insert_at = match assistant_index {
    None => messages.length()
    Some(index) => {
      let mut position = index + 1
      for i in (index + 1)..<messages.length() {
        match messages[i] {
          @kernel.ToolMessage(call_id=existing_call_id, ..) =>
            match tool_call_position(transcript, existing_call_id) {
              Some(existing_position) if existing_position < target_position =>
                position = i + 1
              _ => ()
            }
          _ => ()
        }
      }
      position
    }
  }
  let next_message = @kernel.ToolMessage(call_id~, tool_name~, outcome~)
  let out : Array[@kernel.Message] = []
  for i, message in messages {
    if i == insert_at {
      out.push(next_message)
    }
    out.push(message)
  }
  if insert_at == messages.length() {
    out.push(next_message)
  }
  @kernel.Transcript::from_array(out)
}

///|
/// Keep the terminal `RunOutcome` ordered by the same source positions as the
/// canonical transcript. The call id is internal bookkeeping; only outcomes
/// cross the public terminal boundary.
fn insert_tool_result_in_source_order(
  transcript : @kernel.Transcript,
  existing : Array[(@kernel.CallId, @kernel.ToolOutcome)],
  call_id : @kernel.CallId,
  outcome : @kernel.ToolOutcome,
) -> Array[(@kernel.CallId, @kernel.ToolOutcome)] {
  let target_position = match tool_call_position(transcript, call_id) {
    Some(position) => position
    None => existing.length()
  }
  let out : Array[(@kernel.CallId, @kernel.ToolOutcome)] = []
  let mut inserted = false
  for record in existing {
    let (existing_call_id, _) = record
    let existing_position = match
      tool_call_position(transcript, existing_call_id) {
      Some(position) => position
      None => target_position + existing.length() + 1
    }
    if !inserted && existing_position > target_position {
      out.push((call_id, outcome))
      inserted = true
    }
    out.push(record)
  }
  if !inserted {
    out.push((call_id, outcome))
  }
  out
}

///|
/// Fallback source position for call ids no longer present in the transcript
/// (e.g. after a rewrite that removed the owning assistant message). Sorts
/// to the end, matching the previous append-at-end behavior.
let missing_tool_position : Int = 2147483647

///|
/// Insertion-sort an array of staged tool records by source position. Used
/// instead of `Array::sort` because the tuple contains `CallId`, which does
/// not implement `Compare`.
fn sort_tool_records_by_position(
  records : Array[(@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int)],
) -> Unit {
  for i = 1; i < records.length(); i = i + 1 {
    let key = records[i]
    let mut j = i - 1
    while j >= 0 && records[j].3 > key.3 {
      records[j + 1] = records[j]
      j = j - 1
    }
    records[j + 1] = key
  }
}

///|
/// Insertion-sort an array of tool-result records by source position.
fn sort_result_records_by_position(
  records : Array[(@kernel.CallId, @kernel.ToolOutcome, Int)],
) -> Unit {
  for i = 1; i < records.length(); i = i + 1 {
    let key = records[i]
    let mut j = i - 1
    while j >= 0 && records[j].2 > key.2 {
      records[j + 1] = records[j]
      j = j - 1
    }
    records[j + 1] = key
  }
}

///|
/// Build an incremental ledger mapping each call id in the transcript to its
/// stable source position among all assistant messages. Scans the transcript
/// once per wave declaration / rewrite, not once per result.
fn build_tool_call_ledger(transcript : @kernel.Transcript) -> Map[String, Int] {
  let ledger = Map::from_array([])
  let mut position = 0
  for message in transcript.messages_snapshot() {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          ledger[call.call_id.to_string()] = position
          position = position + 1
        }
      _ => ()
    }
  }
  ledger
}

///|
/// Find the index of the assistant message that owns any of the staged call
/// ids. All staged results in one wave belong to the same assistant message.
fn find_owning_assistant_index(
  messages : Array[@kernel.Message],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int)],
) -> Int? {
  for i, message in messages {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) => {
        let mut matched = false
        for call in tool_calls {
          if staged.contains(call.call_id.to_string()) {
            matched = true
            break
          }
        }
        if matched {
          return Some(i)
        }
      }
      _ => ()
    }
  }
  None
}

///|
/// Commit all staged tool outcomes to the transcript and tool-result ledger
/// in a single wave-boundary rebuild. Returns the new transcript and the new
/// tool-result array. This is O(N) once per wave instead of O(K·N) per result.
fn commit_tool_wave(
  transcript : @kernel.Transcript,
  ledger : Map[String, Int],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int)],
  existing_tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
) -> (@kernel.Transcript, Array[(@kernel.CallId, @kernel.ToolOutcome)]) {
  // Sort staged results by source position; missing positions sort to the end.
  let staged_records : Array[
    (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int),
  ] = []
  for id_str, entry in staged {
    let (tool_name, outcome, position) = entry
    staged_records.push(
      (@kernel.CallId::unchecked(id_str), tool_name, outcome, position),
    )
  }
  sort_tool_records_by_position(staged_records)

  // Build new transcript.
  let messages = transcript.messages_snapshot()
  let new_messages : Array[@kernel.Message] = []
  match find_owning_assistant_index(messages, staged) {
    Some(idx) => {
      // Messages up to and including the owning assistant.
      for i in 0..<=idx {
        new_messages.push(messages[i])
      }
      // Collect existing ToolMessages immediately after the assistant.
      let existing_tool_records : Array[
        (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int),
      ] = []
      let mut remaining_start = idx + 1
      for i in (idx + 1)..<messages.length() {
        match messages[i] {
          @kernel.ToolMessage(call_id~, tool_name~, outcome~) => {
            let pos = match ledger.get(call_id.to_string()) {
              Some(p) => p
              None => missing_tool_position
            }
            existing_tool_records.push((call_id, tool_name, outcome, pos))
          }
          _ => {
            remaining_start = i
            break
          }
        }
      }
      // Combine and sort all tool records for this wave by source position.
      let combined = existing_tool_records.copy()
      for record in staged_records {
        combined.push(record)
      }
      sort_tool_records_by_position(combined)
      for record in combined {
        let (call_id, tool_name, outcome, _) = record
        new_messages.push(@kernel.ToolMessage(call_id~, tool_name~, outcome~))
      }
      // Append remaining messages (e.g. rewrites after the assistant).
      for i in remaining_start..<messages.length() {
        new_messages.push(messages[i])
      }
    }
    None => {
      // Owning assistant not found: append staged results at the end.
      for msg in messages {
        new_messages.push(msg)
      }
      for record in staged_records {
        let (call_id, tool_name, outcome, _) = record
        new_messages.push(@kernel.ToolMessage(call_id~, tool_name~, outcome~))
      }
    }
  }

  // Build new tool-result ledger by merging existing results with staged ones
  // in global source order.
  let combined_results : Array[(@kernel.CallId, @kernel.ToolOutcome, Int)] = []
  for record in existing_tool_results {
    let (call_id, outcome) = record
    let pos = match ledger.get(call_id.to_string()) {
      Some(p) => p
      None => missing_tool_position
    }
    combined_results.push((call_id, outcome, pos))
  }
  for record in staged_records {
    let (call_id, tool_name, outcome, pos) = record
    ignore(tool_name)
    combined_results.push((call_id, outcome, pos))
  }
  sort_result_records_by_position(combined_results)
  let new_tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)] = []
  for record in combined_results {
    let (call_id, outcome, _) = record
    new_tool_results.push((call_id, outcome))
  }
  (@kernel.Transcript::from_array(new_messages), new_tool_results)
}

///|
/// Project the run-local ledger into the public terminal result shape.
fn tool_outcomes(
  records : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)],
) -> FixedArray[@kernel.ToolOutcome] {
  let out : Array[@kernel.ToolOutcome] = []
  for i in 0..<records.length() {
    let (_, outcome) = records[i]
    out.push(outcome)
  }
  FixedArray::from_array(out)
}

///|
fn is_unknown_tool_diagnostic(diag : @kernel.SchemaDiagnostic) -> Bool {
  diag.actual.contains("unknown tool")
}

///|
fn EffectId::add(self : EffectId, n : Int) -> EffectId {
  let mut id = self
  for i = 0; i < n; i = i + 1 {
    id = id.next()
  }
  id
}
