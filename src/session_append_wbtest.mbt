///|
/// Session checkpoint regression tests.
///
/// Pure append turns are persisted as coherent checkpoints; committed
/// assistant/tool steps advance the same cursor during the turn. Transcript
/// rewrites (compact, fork, hook rewrite) fall back to a full save.

///|
fn append_config() -> AgentConfig {
  agent_config(max_tool_rounds=Some(10))
}

// ---------------------------------------------------------------------------
// Regression 1: two sequential turns on one session use append, not full save.
// ---------------------------------------------------------------------------

///|
async test "t06_sequential_turns_use_append_not_full_save" {
  let model = ScriptedModel([
    Respond(tk_stop_response("first")),
    Respond(tk_stop_response("second")),
  ])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=append_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  let _ = agent.run_turn(tk_user_msg("world"), "s1")
  let ops = store.ops()
  let mut save_count = 0
  let mut checkpoint_count = 0
  for op in ops {
    match op {
      OpSave(id="s1", ..) => save_count = save_count + 1
      OpCheckpoint(id="s1", ..) => checkpoint_count = checkpoint_count + 1
      _ => ()
    }
  }
  assert_eq(save_count, 0)
  // At minimum: admitted input + committed assistant for each turn.
  assert_true(checkpoint_count >= 4)
}

// ---------------------------------------------------------------------------
// Regression 2: a compact turn falls back to full save, not append.
// ---------------------------------------------------------------------------

///|
fn compact_trigger_response(total_tokens : Int) -> @kernel.ModelCallResult {
  // Tool-calls response keeps the pump in ReadyForModel so the auto-compact
  // safe-point is reached; the tool outcome is ignored by the test.
  let base = tk_tool_call_response("echo", "call_1", Json::null())
  let completion : @kernel.Completion = Completion(
    content=[],
    tool_calls=base.completion.tool_calls(),
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some({
      input_tokens: Some(total_tokens),
      output_tokens: Some(0),
      total_tokens: Some(total_tokens),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [], }
}

///|
async test "t06_compact_turn_uses_full_save_not_append" {
  let model = ScopeRecordingModel(
    [
      Respond(tk_stop_response("first")),
      Respond(compact_trigger_response(95)),
      Respond(tk_stop_response("done")),
    ],
    compact_result={
      compacted_messages: [tk_user_msg("summary")],
      mode: Replace,
    },
  )
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools], sessions=[store]),
    ],
    config={
      ..append_config(),
      model_context_window: Some(100),
      compact_threshold: Some(0.9),
    },
  )
  // First turn: small response, no compact, should append.
  let _ = agent.run_turn(tk_user_msg("hello"), "s2")
  // Second turn: response reports 95 tokens (> 90 threshold), triggers
  // compact Replace, which must fall back to full save.
  let _ = agent.run_turn(tk_user_msg("world"), "s2")
  let ops = store.ops()
  let mut save_count = 0
  let mut checkpoint_count = 0
  for op in ops {
    match op {
      OpSave(id="s2", ..) => save_count = save_count + 1
      OpCheckpoint(id="s2", ..) => checkpoint_count = checkpoint_count + 1
      _ => ()
    }
  }
  assert_true(checkpoint_count >= 2)
  assert_eq(save_count, 1)
}

///|
async test "committed model and tool steps advance the durable cursor" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "checkpoint-call", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("tool-ok")))]),
  )
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store]),
    ],
    config=append_config(),
  )
  ignore(agent.run_turn(tk_user_msg("run it"), "step-checkpoint"))
  let cursors : Array[Int] = []
  for op in store.ops() {
    match op {
      OpCheckpoint(id="step-checkpoint", checkpoint~, ..)
        if !checkpoint.messages.is_empty() =>
        cursors.push(checkpoint.from_index)
      _ => ()
    }
  }
  inspect(cursors, content="[0, 1, 2, 3]")
}
