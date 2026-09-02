/// Model-turn branches: `run_model_step` and the `ModelCompleted` / `ModelFailed` folds.

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
  // validated calls (become ExecuteTool effects). Rejected (call, outcome)
  // pairs are collected in source order; their events are emitted together
  // after the loop. Duplicate call_id is an invariant failure.
  let seen : Map[String, Unit] = Map::from_array([])
  let rejected_calls : Array[@kernel.ToolCall] = []
  let rejected_outcomes : Array[@kernel.ToolOutcome] = []
  for call in calls {
    let id_str = call.call_id.to_string()
    if seen.contains(id_str) {
      return reduce_invariant_violation(
        state,
        DuplicateCallId(call_id=call.call_id),
      )
    }
    seen[id_str] = ()
    match classify_rejected_outcome(catalog, call) {
      Some(outcome) => {
        let updated = record_rejected_call(
          transcript, tool_results, call, outcome, rejected_calls, rejected_outcomes,
        )
        transcript = updated.0
        tool_results = updated.1
      }
      None =>
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
            // Unreachable: contains() returned true in the classifier.
            // Treat as invariant violation with a synthetic diagnostic owner.
            return reduce_invariant_violation(
              state,
              MissingOwner(owner=@kernel.OwnerId::unchecked("(unknown)")),
            )
        }
    }
  }
  // Pre-pass-rejected calls are "submitted → resolved NotExecuted": their
  // batch-start MUST precede the completions because the event subscriber
  // registers pending calls on ToolBatchStarted and consumes them on
  // ToolCompleted. A mixed wave therefore gets two batch-starts for this
  // step (rejected calls here, effect calls below); the subscriber
  // registers and drains each batch independently.
  if !rejected_calls.is_empty() {
    events.push(
      ToolBatchStarted(
        model_step_id=payload.model_step_id,
        calls=rejected_calls,
      ),
    )
    for i in 0..<rejected_calls.length() {
      events.push(
        ToolCompleted(
          call_id=rejected_calls[i].call_id,
          outcome=rejected_outcomes[i],
        ),
      )
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
  // Emit ToolBatchStarted covering only the calls that became effects. The
  // pre-pass-rejected calls (if any) already got their own batch-start +
  // completions above.
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
/// Classify one model-proposed call against the catalog. Returns
/// `Some(NotExecuted outcome)` when the call must be rejected (unknown tool
/// or schema mismatch), `None` when it becomes an `ExecuteTool` effect.
fn classify_rejected_outcome(
  catalog : ToolCatalogSnapshot,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome? {
  // Unknown tool → NotExecuted(UnknownTool)
  if !catalog.contains(call.name) {
    return Some(
      @kernel.NotExecuted(
        reason=@kernel.UnknownTool,
        original_call_id=call.call_id,
      ),
    )
  }
  // Schema validation against the catalog.
  match catalog.validate_arguments(call.name, call.arguments) {
    Err(diag) =>
      if is_unknown_tool_diagnostic(diag) {
        // Should be unreachable (we checked contains above), but be safe.
        Some(
          @kernel.NotExecuted(
            reason=@kernel.UnknownTool,
            original_call_id=call.call_id,
          ),
        )
      } else {
        Some(
          @kernel.NotExecuted(
            reason=@kernel.SchemaMismatch(
              json_path=diag.json_path,
              expected=diag.expected,
              actual=diag.actual,
            ),
            original_call_id=call.call_id,
          ),
        )
      }
    Ok(_) => None
  }
}

///|
/// Merge one rejected call's NotExecuted outcome into the transcript, the
/// tool-result ledger and the rejected-batch arrays, preserving source
/// order. Returns the updated transcript and tool-result ledger.
fn record_rejected_call(
  transcript : @kernel.Transcript,
  tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
  call : @kernel.ToolCall,
  outcome : @kernel.ToolOutcome,
  rejected_calls : Array[@kernel.ToolCall],
  rejected_outcomes : Array[@kernel.ToolOutcome],
) -> (@kernel.Transcript, Array[(@kernel.CallId, @kernel.ToolOutcome)]) {
  let transcript = insert_tool_message_in_source_order(
    transcript,
    call.call_id,
    call.name,
    outcome,
  )
  let tool_results = insert_tool_result_in_source_order(
    transcript,
    tool_results,
    call.call_id,
    outcome,
  )
  rejected_calls.push(call)
  rejected_outcomes.push(outcome)
  (transcript, tool_results)
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
    @kernel.RateLimited(reason~, reset_at_ms~, provider_code~) =>
      ModelQuotaExhausted(detail=reason, reset_at_ms~, provider_code~)
  }
  reduce_terminal_fail(state, reason)
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
  let finish = safe_label(completion.finish_reason().to_string())
  let reasoning = match completion.message.reasoning {
    Some(_) => ", reasoning=present"
    None => ""
  }
  "finish=\{finish}, tool_calls=\{n_tools}\{reasoning}"
}
