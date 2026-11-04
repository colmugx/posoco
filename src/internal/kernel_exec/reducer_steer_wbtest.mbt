///|
/// White-box tests for the steer branch: a user message appended at the step
/// boundary, legal only in `ReadyForModel`.

///|
fn steer_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
fn steer_input(command_id : String, text : String) -> RunInput {
  SteerAppended(payload={ command_id, message: steer_message(text), })
}

///|
fn usage_with_total(total : Int32) -> @kernel.Usage {
  {
    input_tokens: Some(total - 10),
    output_tokens: Some(10),
    total_tokens: Some(total),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
}

///|
fn tool_call_completion(total : Int32) -> @kernel.Completion {
  Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("call_steer"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/x"))])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some(usage_with_total(total)),
  )
}

///|
/// Reduce up to the model step request, returning the state plus the pending
/// `CallModel` correlation ids.
fn steer_awaiting_model(
  catalog : ToolCatalogSnapshot,
) -> (RunState, EffectId, ModelStepId) raise {
  let out_start = reduce(fresh_state(), catalog, start_input())
  let out_model = run_model_step(out_start.next_state(), catalog, Json::null())
  let st = out_model.next_state()
  match st.pending_effects()[0] {
    CallModel(effect_id~, payload~) => (st, effect_id, payload.model_step_id)
    _ => abort("expected CallModel pending effect")
  }
}

///|
/// Drive the run into `AwaitingTools` with one executable tool call.
fn steer_awaiting_tools(
  catalog : ToolCatalogSnapshot,
) -> (RunState, EffectId) raise {
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let input : RunInput = ModelCompleted(payload={
    effect_id,
    model_step_id: step_id,
    completion: tool_call_completion(120),
    processed_messages: st.transcript().messages_snapshot(),
  })
  let out = reduce(st, catalog, input)
  let effects = out.effects()
  let exec_id = match effects[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => abort("expected ExecuteTool effect")
  }
  (out.next_state(), exec_id)
}

///|
/// Drive the run into `ReadyForModel` after a complete tool batch, with a
/// verified context reading standing on a shorter transcript.
fn steer_ready_after_tool_batch() -> (RunState, ToolCatalogSnapshot) raise {
  let catalog = make_catalog_v1()
  let (st_tools, exec_id) = steer_awaiting_tools(catalog)
  let tool_input : RunInput = ToolCompleted(payload={
    effect_id: exec_id,
    call_id: @kernel.CallId::unchecked("call_steer"),
    tool_name: @kernel.ToolName::unchecked("read"),
    arguments: Json::null(),
    outcome: Success(content="data", structured=None),
  })
  (reduce(st_tools, catalog, tool_input).next_state(), catalog)
}

///|
test "steer/ready_for_model_appends_message" {
  let (st_ready, catalog) = steer_ready_after_tool_batch()
  assert_eq(st_ready.phase(), ReadyForModel)
  assert_eq(st_ready.budget_consumed().last_context_tokens, Some(120))
  let messages_before = st_ready.transcript().length()
  let seq_before = st_ready.next_event_sequence().to_int()
  let step_before = st_ready.current_model_step_id()
  let pending_before = st_ready.pending_effects().length()
  let message = steer_message("target branch is release")
  let out = reduce(
    st_ready,
    catalog,
    steer_input("steer_1", "target branch is release"),
  )
  let st_after = out.next_state()
  // Phase, pending effects and the model step identity are untouched: the
  // steer consumes neither a model step nor a step budget unit.
  assert_eq(st_after.phase(), ReadyForModel)
  assert_eq(st_after.pending_effects().length(), pending_before)
  assert_eq(st_after.current_model_step_id(), step_before)
  assert_eq(
    st_after.budget_consumed().model_steps,
    st_ready.budget_consumed().model_steps,
  )
  // The message is the last transcript entry, appended exactly once.
  assert_eq(st_after.transcript().length(), messages_before + 1)
  let tail = st_after.transcript().messages_snapshot()
  assert_eq(tail[tail.length() - 1], message)
  // One event, one sequence slot, no effects, no body in the summary.
  let events = out.events()
  assert_eq(events.length(), 1)
  assert_eq(st_after.next_event_sequence().to_int(), seq_before + 1)
  assert_eq(out.effects().length(), 0)
  match events[0] {
    UserMessageAppended(command_id~, message=committed) => {
      assert_eq(command_id, "steer_1")
      assert_eq(committed, message)
    }
    other => fail("expected UserMessageAppended, got \{other.to_string()}")
  }
  assert_false(events[0].is_terminal())
  // The old context occupancy described a shorter transcript.
  assert_eq(st_after.budget_consumed().last_context_tokens, None)
}

///|
fn assert_steer_rejected(
  state : RunState,
  phase : Phase,
  catalog : ToolCatalogSnapshot,
) -> Unit raise {
  let out = reduce(state, catalog, steer_input("steer_late", "too late"))
  let st_after = out.next_state()
  assert_eq(st_after.phase(), phase)
  assert_eq(st_after.transcript(), state.transcript())
  assert_eq(st_after.pending_effects(), state.pending_effects())
  assert_eq(st_after.current_model_step_id(), state.current_model_step_id())
  let events = out.events()
  assert_eq(events.length(), 1)
  match events[0] {
    InputRejected(input_kind~, reason~) => {
      assert_eq(input_kind, "SteerAppended")
      assert_true(reason.length() > 0)
    }
    other => fail("expected InputRejected, got \{other.to_string()}")
  }
}

///|
test "steer/awaiting_model_rejected" {
  let catalog = make_catalog_v1()
  let (st, _, _) = steer_awaiting_model(catalog)
  assert_steer_rejected(st, AwaitingModel, catalog)
}

///|
test "steer/awaiting_tools_rejected" {
  let catalog = make_catalog_v1()
  let (st, _) = steer_awaiting_tools(catalog)
  assert_steer_rejected(st, AwaitingTools, catalog)
}

///|
test "steer/terminal_rejected" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let input : RunInput = ModelCompleted(payload={
    effect_id,
    model_step_id: step_id,
    completion: make_completion_no_tools(),
    processed_messages: st.transcript().messages_snapshot(),
  })
  let st_terminal = reduce(st, catalog, input).next_state()
  assert_eq(st_terminal.phase(), Terminal)
  assert_steer_rejected(st_terminal, Terminal, catalog)
}

///|
/// A no-tool completion that also carries usage, for the continue-turn tests.
fn steering_no_tool_completion(total : Int32) -> @kernel.Completion {
  Completion(
    content=[Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=Some(usage_with_total(total)),
  )
}

///|
fn steering_completed_input(
  effect_id : EffectId,
  step_id : ModelStepId,
  processed : Array[@kernel.Message],
  completion : @kernel.Completion,
) -> RunInput {
  ModelCompletedWithSteering(payload={
    effect_id,
    model_step_id: step_id,
    completion,
    processed_messages: processed,
  })
}

///|
test "steering/completed_with_steering_continues_turn" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  // Explicit kind, distinct from ModelCompleted in replay and rejections.
  assert_eq(
    steering_completed_input(effect_id, step_id, [], make_completion_no_tools()).kind(),
    "ModelCompletedWithSteering",
  )
  // The pump folds the steer accepted during the step into the processed
  // transcript it submits with the completion.
  let processed = st.transcript().messages_snapshot()
  processed.push(steer_message("target branch is release"))
  let out = reduce(
    st,
    catalog,
    steering_completed_input(
      effect_id,
      step_id,
      processed,
      steering_no_tool_completion(120),
    ),
  )
  let st_after = out.next_state()
  // The run continues instead of completing: no outcome, no pending work, and
  // the step id advances exactly like the other next-step paths.
  assert_eq(st_after.phase(), ReadyForModel)
  assert_eq(st_after.outcome(), None)
  assert_eq(st_after.pending_effects().length(), 0)
  assert_eq(st_after.current_model_step_id(), step_id.next())
  // Transcript: processed messages (steer included) + one assistant
  // completion, committed exactly once.
  assert_eq(st_after.transcript().length(), processed.length() + 1)
  let tail = st_after.transcript().messages_snapshot()
  assert_eq(tail[tail.length() - 2], steer_message("target branch is release"))
  match tail[tail.length() - 1] {
    AssistantMessage(content~, tool_calls~, ..) => {
      assert_eq(content, [Text("hello")])
      assert_eq(tool_calls.length(), 0)
    }
    _ => fail("expected assistant completion last")
  }
  // Budget: the step is consumed and the usage reading stays fresh, so
  // auto-compact still sees a truthful occupancy.
  let consumed = st_after.budget_consumed()
  assert_eq(consumed.model_steps, 1)
  assert_eq(consumed.observed_total_tokens, 120)
  assert_eq(consumed.last_context_tokens, Some(120))
  // One non-terminal event, no effects.
  let events = out.events()
  assert_eq(events.length(), 1)
  assert_false(events[0].is_terminal())
  match events[0] {
    ModelStepCompleted(model_step_id~, ..) => assert_eq(model_step_id, step_id)
    other => fail("expected ModelStepCompleted, got \{other.to_string()}")
  }
  assert_eq(out.effects().length(), 0)
  // The reopened boundary declares the next model step normally.
  assert_eq(
    run_model_step(st_after, catalog, Json::null()).next_state().phase(),
    AwaitingModel,
  )
}

///|
test "steering/plain_model_completed_still_terminates" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let input : RunInput = ModelCompleted(payload={
    effect_id,
    model_step_id: step_id,
    completion: steering_no_tool_completion(120),
    processed_messages: st.transcript().messages_snapshot(),
  })
  let out = reduce(st, catalog, input)
  let final_state = out.next_state()
  // The default input keeps its meaning: no steer in flight, so the run ends.
  assert_eq(final_state.phase(), Terminal)
  match final_state.outcome() {
    Some(Completed(..)) => ()
    _ => fail("expected Completed outcome")
  }
  assert_eq(final_state.current_model_step_id(), step_id)
  let terminal_events = out.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminal_events.length(), 1)
}

///|
test "steering/completed_with_steering_respects_budget" {
  let catalog = make_catalog_v1()
  let initial = fresh_state_with_budget(
    Budget::bounded(
      max_model_steps=10,
      max_tool_rounds=10,
      max_tool_calls=10,
      max_total_tokens=100,
    ),
  )
  let started = reduce(initial, catalog, start_input())
  let waiting = run_model_step(started.next_state(), catalog, Json::null())
  let (st, effect_id, step_id) = match
    waiting.next_state().pending_effects()[0] {
    CallModel(effect_id~, payload~) =>
      (waiting.next_state(), effect_id, payload.model_step_id)
    _ => fail("expected CallModel pending effect")
  }
  let out = reduce(
    st,
    catalog,
    steering_completed_input(
      effect_id,
      step_id,
      st.transcript().messages_snapshot(),
      steering_no_tool_completion(120),
    ),
  )
  // The token limit wins over the continuation: no reopen, a Failed run.
  let final_state = out.next_state()
  assert_eq(final_state.phase(), Terminal)
  match final_state.outcome() {
    Some(Failed(reason=BudgetExhausted(dimension=TotalTokens))) => ()
    _ => fail("expected budget-exhausted failure")
  }
  assert_true(
    out
    .events()
    .iter()
    .any(fn(e) { e is BudgetExhausted(dimension=TotalTokens, ..) }),
  )
  assert_eq(out.events().filter(fn(e) { e.is_terminal() }).length(), 1)
}

///|
test "steering/completed_with_steering_preserves_usage_failure" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let bad_usage : @kernel.Usage = {
    input_tokens: Some(-1),
    output_tokens: None,
    total_tokens: None,
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
  let completion : @kernel.Completion = Completion(
    content=[Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=Some(bad_usage),
  )
  let out = reduce(
    st,
    catalog,
    steering_completed_input(
      effect_id,
      step_id,
      st.transcript().messages_snapshot(),
      completion,
    ),
  )
  // Invalid usage fails the run exactly as it would without steering.
  let final_state = out.next_state()
  assert_eq(final_state.phase(), Terminal)
  match final_state.outcome() {
    Some(Failed(reason=ModelParseFailure(_))) => ()
    _ => fail("expected parse failure")
  }
}

///|
test "steering/completed_with_steering_rejected_after_terminal" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let finish : RunInput = ModelCompleted(payload={
    effect_id,
    model_step_id: step_id,
    completion: make_completion_no_tools(),
    processed_messages: st.transcript().messages_snapshot(),
  })
  let st_terminal = reduce(st, catalog, finish).next_state()
  assert_eq(st_terminal.phase(), Terminal)
  let transcript_before = st_terminal.transcript()
  let outcome_before = st_terminal.outcome()
  let late = steering_completed_input(
    effect_id,
    step_id,
    st_terminal.transcript().messages_snapshot(),
    make_completion_no_tools(),
  )
  let out = reduce(st_terminal, catalog, late)
  let st_after = out.next_state()
  // The terminal state is never reopened.
  assert_eq(st_after.phase(), Terminal)
  assert_eq(st_after.outcome(), outcome_before)
  assert_eq(st_after.transcript(), transcript_before)
  assert_eq(
    st_after.current_model_step_id(),
    st_terminal.current_model_step_id(),
  )
  // Exactly one typed rejection; no second terminal event.
  let events = out.events()
  assert_eq(events.length(), 1)
  assert_false(events[0].is_terminal())
  match events[0] {
    InputRejected(input_kind~, reason~) => {
      assert_eq(input_kind, "ModelCompletedWithSteering")
      assert_true(reason.length() > 0)
    }
    other => fail("expected InputRejected, got \{other.to_string()}")
  }
}

///|
test "steering/completed_with_steering_rejected_outside_awaiting_model" {
  let catalog = make_catalog_v1()
  let ready = reduce(fresh_state(), catalog, start_input()).next_state()
  let out_ready = reduce(
    ready,
    catalog,
    steering_completed_input(
      ready.next_effect_id(),
      ready.current_model_step_id(),
      ready.transcript().messages_snapshot(),
      make_completion_no_tools(),
    ),
  )
  assert_eq(out_ready.next_state().phase(), ReadyForModel)
  match out_ready.events()[0] {
    InputRejected(input_kind~, ..) =>
      assert_eq(input_kind, "ModelCompletedWithSteering")
    other => fail("expected InputRejected, got \{other.to_string()}")
  }
  let (st_tools, _) = steer_awaiting_tools(catalog)
  let out_tools = reduce(
    st_tools,
    catalog,
    steering_completed_input(
      st_tools.next_effect_id(),
      st_tools.current_model_step_id(),
      st_tools.transcript().messages_snapshot(),
      make_completion_no_tools(),
    ),
  )
  assert_eq(out_tools.next_state().phase(), AwaitingTools)
  match out_tools.events()[0] {
    InputRejected(input_kind~, ..) =>
      assert_eq(input_kind, "ModelCompletedWithSteering")
    other => fail("expected InputRejected, got \{other.to_string()}")
  }
}

///|
test "steering/reopened_boundary_still_accepts_steer" {
  let catalog = make_catalog_v1()
  let (st, effect_id, step_id) = steer_awaiting_model(catalog)
  let processed = st.transcript().messages_snapshot()
  processed.push(steer_message("freeze the schema"))
  let st_ready = reduce(
    st,
    catalog,
    steering_completed_input(
      effect_id,
      step_id,
      processed,
      steering_no_tool_completion(120),
    ),
  ).next_state()
  assert_eq(st_ready.phase(), ReadyForModel)
  // Existing SteerAppended behavior is unchanged at the reopened boundary:
  // the message appends, the phase/step id/counters stay untouched.
  let steps_before = st_ready.budget_consumed().model_steps
  let seq_before = st_ready.next_event_sequence().to_int()
  let out = reduce(
    st_ready,
    catalog,
    steer_input("steer_2", "release, not main"),
  )
  let st_after = out.next_state()
  assert_eq(st_after.phase(), ReadyForModel)
  assert_eq(st_after.current_model_step_id(), step_id.next())
  assert_eq(st_after.budget_consumed().model_steps, steps_before)
  let tail = st_after.transcript().messages_snapshot()
  assert_eq(tail[tail.length() - 1], steer_message("release, not main"))
  match out.events()[0] {
    UserMessageAppended(command_id~, ..) => assert_eq(command_id, "steer_2")
    other => fail("expected UserMessageAppended, got \{other.to_string()}")
  }
  assert_eq(st_after.next_event_sequence().to_int(), seq_before + 1)
}

///|
test "steering/superseded_reason_formats_stably" {
  assert_eq(
    @kernel.NotExecutedReason::SupersededByMessage.to_string(),
    "SupersededByMessage",
  )
  // The outcome summary keeps the tag-only discipline for payload-free tags.
  let outcome : @kernel.ToolOutcome = NotExecuted(
    reason=SupersededByMessage,
    original_call_id=@kernel.CallId::unchecked("call_x"),
  )
  assert_eq(
    outcome.summary(),
    "NotExecuted(SupersededByMessage, call_id=call_x)",
  )
}
