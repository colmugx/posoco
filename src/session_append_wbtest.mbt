///|
/// M0-T06 regression tests: session append vs full-save boundary.
///
/// These tests document the persisted-cursor optimisation: sequential pure
/// appends are sent to stores as `append_messages`, while rewrites (compact,
/// fork, hook rewrite) fall back to a full save.

///|
fn append_config() -> AgentConfig {
  {
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
  }
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
  let mut append_count = 0
  for op in ops {
    match op {
      OpSave(id="s1", ..) => save_count = save_count + 1
      OpAppend(id="s1", ..) => append_count = append_count + 1
      _ => ()
    }
  }
  assert_eq(save_count, 0)
  assert_eq(append_count, 2)
}

// ---------------------------------------------------------------------------
// Regression 2: a compact turn falls back to full save, not append.
// ---------------------------------------------------------------------------

///|
fn compact_trigger_response(total_tokens : Int) -> @kernel.ModelCallResult {
  // Tool-calls response keeps the pump in ReadyForModel so the auto-compact
  // safe-point is reached; the tool outcome is ignored by the test.
  let base = tk_tool_call_response("echo", "call_1", Json::null())
  let completion : @kernel.Completion = @kernel.Completion(
    content=[],
    tool_calls=base.completion.tool_calls(),
    reasoning=None,
    finish_reason=@kernel.ToolCalls,
    usage=Some(@kernel.Usage::{
      input_tokens: Some(total_tokens),
      output_tokens: Some(0),
      total_tokens: Some(total_tokens),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [] }
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
      mode: @kernel.Replace,
    },
  )
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
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
  let mut append_count = 0
  for op in ops {
    match op {
      OpSave(id="s2", ..) => save_count = save_count + 1
      OpAppend(id="s2", ..) => append_count = append_count + 1
      _ => ()
    }
  }
  assert_eq(append_count, 1)
  assert_eq(save_count, 1)
}
