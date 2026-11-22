/// Model-turn branches: `run_model_step` and the `ModelCompleted` / `ModelFailed` folds.

///|
/// Declare the CallModel effect for the current model step. Unlike the folds,
/// this is NOT reached through `reduce(state, catalog, input)`: the driver
/// decides when to advance.
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
  match input {
    ModelCompleted(payload~) => reduce_model_completed(state, catalog, payload)
    ModelCompletedContinue(payload~) =>
      reduce_model_completed(state, catalog, payload, continue_turn=true)
    ModelFailed(payload~) => reduce_model_failed(state, payload)
    CancelRequested(payload~) =>
      reduce_cancel_with_pending(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail_with_pending(state, DeadlineReached, DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail_with_pending(
        state,
        BudgetExhausted(dimension=payload.dimension),
        HostRequested(detail=Some("budget exhausted")),
      )
    SuspendRequested(payload~) => reduce_suspend(state, payload.requirement)
    TranscriptRewrite(_) =>
      reject_input(
        state, input, "AwaitingModel: model step in flight; cannot rewrite transcript",
      )
    Start(_) | Resume(_) | ToolCompleted(_) | ToolFailed(_) =>
      reject_input(state, input, "AwaitingModel: input not legal here")
    SteerAppended(_) =>
      reject_input(
        state, input, "AwaitingModel: model step in flight; steer lands at the next step boundary",
      )
  }
}

///|
fn reduce_model_completed(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  payload : ModelCompletedPayload,
  continue_turn~ : Bool = false,
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
  if pending_id != payload.effect_id ||
    payload.model_step_id != state.current_model_step_id() {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let completion = payload.completion
  match completion.usage {
    Some(usage) =>
      match usage.validate() {
        Err(reason) =>
          return reduce_model_failed(state, {
            effect_id: payload.effect_id,
            model_step_id: payload.model_step_id,
            failure: Parse(reason="model usage validation failed: " + reason),
          })
        Ok(_) => ()
      }
    None => ()
  }
  let assistant_msg = @kernel.AssistantMessage(
    content=completion.message.content.copy(),
    tool_calls=completion.message.tool_calls.copy(),
    reasoning=completion.message.reasoning,
    finish_reason=completion.message.finish_reason,
  )
  let base_transcript = @kernel.Transcript::from_array(
    payload.processed_messages,
  )
  let transcript = base_transcript.append(assistant_msg)
  let next_consumed = bump_model_step(state.budget_consumed(), completion.usage)
  match completion.finish_reason() {
    Length =>
      return reduce_terminal_fail_with(
        state,
        transcript,
        next_consumed,
        ModelParseFailure(detail="finish_reason=Length"),
        [],
      )
    _ => ()
  }
  let step_completed : KernelEvent = ModelStepCompleted(
    model_step_id=payload.model_step_id,
    completion~,
  )
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
  if !completion.has_tool_calls() {
    if continue_turn {
      let next_state = state.transition(
        phase=ReadyForModel,
        transcript~,
        pending_effects=[],
        next_event_sequence=advance_seq_by(state, 1),
        next_effect_id=state.next_effect_id(),
        current_model_step_id=payload.model_step_id.next(),
        catalog_version=None,
        budget_consumed=next_consumed,
        outcome=None,
        completed_tool_results=Map::from_array([]),
        tool_call_positions=Map::from_array([]),
        suspension_requirement=None,
      )
      return reduce_output(next_state, [], [step_completed])
    }
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
      tool_calls=next_consumed.tool_calls,
    )
    return reduce_output(terminal_state, [], [step_completed, terminal_event])
  }
  // Every validated call goes into a SINGLE AwaitingTools batch: splitting it
  // into waves is the scheduler's concern, not the reducer's.
  reduce_model_completed_with_tools(
    state, catalog, payload, completion, transcript, next_consumed, step_completed,
  )
}

///|
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
          transcript, tool_call_positions, tool_results, call, outcome, rejected_calls,
          rejected_outcomes,
        )
        transcript = updated.0
        tool_results = updated.1
      }
      None =>
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
              parent: None,
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
  if !rejected_calls.is_empty() {
    events.push(
      ToolCallsPreRejected(
        model_step_id=payload.model_step_id,
        calls=rejected_calls,
        outcomes=rejected_outcomes,
      ),
    )
  }
  // No ExecuteTool was declared: go back to ReadyForModel so the model can see
  // its own rejected calls on the next step.
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
  let batch_calls : Array[@kernel.ToolCall] = []
  for e in effects {
    match e {
      ExecuteTool(payload~, ..) => batch_calls.push(payload.tool_call())
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
/// Returns `Some(NotExecuted outcome)` when the call must be rejected (unknown
/// tool, not offered, or schema mismatch), `None` when it may execute.
pub fn classify_rejected_outcome(
  catalog : ToolCatalogSnapshot,
  call : @kernel.ToolCall,
  direct~ : Bool = true,
) -> @kernel.ToolOutcome? {
  let entry = match catalog.find(call.name) {
    Some(entry) => entry
    None =>
      return Some(
        NotExecuted(reason=UnknownTool, original_call_id=call.call_id),
      )
  }
  if entry.definition.exposure is Disabled ||
    (direct && entry.definition.exposure is Deferred) {
    return Some(NotExecuted(reason=NotOffered, original_call_id=call.call_id))
  }
  match catalog.validate_known_arguments(call.name, call.arguments) {
    None => Some(NotExecuted(reason=UnknownTool, original_call_id=call.call_id))
    Some(Err(diag)) =>
      Some(
        NotExecuted(
          reason=SchemaMismatch(
            json_path=diag.json_path,
            expected=diag.expected,
            actual=diag.actual,
          ),
          original_call_id=call.call_id,
        ),
      )
    Some(Ok(_)) => None
  }
}

///|
fn record_rejected_call(
  transcript : @kernel.Transcript,
  tool_call_positions : Map[String, Int32],
  tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
  call : @kernel.ToolCall,
  outcome : @kernel.ToolOutcome,
  rejected_calls : Array[@kernel.ToolCall],
  rejected_outcomes : Array[@kernel.ToolOutcome],
) -> (@kernel.Transcript, Array[(@kernel.CallId, @kernel.ToolOutcome)]) {
  let transcript = insert_tool_message_in_source_order(
    transcript,
    tool_call_positions,
    call.call_id,
    call.name,
    outcome,
  )
  let tool_results = insert_tool_result_in_source_order(
    tool_call_positions,
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
  if pending_id != payload.effect_id ||
    payload.model_step_id != state.current_model_step_id() {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let reason : FailureReason = match payload.failure {
    RequestBuild(reason~) => ModelParseFailure(detail=reason)
    Transport(reason~) => ModelTransport(detail=reason)
    Runtime(reason~) => ModelRuntime(detail=reason)
    Parse(reason~) => ModelParseFailure(detail=reason)
    HostRejected(reason~) => HostRejected(detail=reason)
    RateLimited(reason~, reset_at_ms~, provider_code~) =>
      ModelQuotaExhausted(detail=reason, reset_at_ms~, provider_code~)
  }
  reduce_terminal_fail(state, reason)
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
