///|
/// Contract pins for `InvocationScope`: every model-side port call must carry
/// the identity of the session/run that issued it. This is what lets adapters
/// key behaviour on session identity (continuity, telemetry, per-session
/// policy) without smuggling it through messages or config.

///|
/// Two sessions share one agent (the Continuity scenario): each turn's chat
/// call must be scoped to the session the product passed to `run_turn`, and
/// each turn is its own run.
async test "scope/chat_carries_caller_session_per_turn" {
  let model = ScopeRecordingModel([
    Respond(tk_stop_response("a")),
    Respond(tk_stop_response("b")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "session_a"))
  ignore(agent.run_turn(tk_user_msg("hello"), "session_b"))
  let scopes = model.chat_scopes()
  assert_eq(scopes.length(), 2)
  assert_eq(scopes[0].session_id.to_string(), "session_a")
  assert_eq(scopes[1].session_id.to_string(), "session_b")
  assert_true(scopes[0].run_id.to_string() != "")
  assert_true(scopes[1].run_id.to_string() != "")
  assert_true(scopes[0].run_id != scopes[1].run_id)
  // Every chat call executes a reducer-allocated CallModel effect.
  assert_true(scopes[0].effect_id is Some(_))
  assert_true(scopes[1].effect_id is Some(_))
}

///|
/// A tool-loop turn issues several model calls inside ONE run: all of them
/// share the run/session identity, while effect ids are distinct and
/// increasing (reducer allocation order).
async test "scope/tool_loop_shares_run_effect_ids_increase" {
  let model = ScopeRecordingModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools], sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_loop"))
  let scopes = model.chat_scopes()
  assert_eq(scopes.length(), 2)
  assert_eq(scopes[0].session_id, scopes[1].session_id)
  assert_eq(scopes[0].run_id, scopes[1].run_id)
  match (scopes[0].effect_id, scopes[1].effect_id) {
    (Some(first), Some(second)) => assert_true(second.to_int() > first.to_int())
    _ => fail("expected reducer-allocated effect ids on both chat calls")
  }
}

///|
/// Build a tool-call result whose completion reports `total` observed tokens,
/// so the auto-compact pump fires against a small context window.
fn scope_test_tool_call_with_usage(total : Int) -> @kernel.ModelCallResult {
  let base = tk_tool_call_response("echo", "call_1", Json::null())
  let completion : @kernel.Completion = Completion(
    content=[],
    tool_calls=base.completion.tool_calls(),
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some({
      input_tokens: Some(total),
      output_tokens: Some(0),
      total_tokens: Some(total),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [], }
}

///|
/// Compact is host-driven, not a reducer-allocated effect: its scope must
/// still name the run/session, but `effect_id` is `None`. Auto-compact fires
/// after the first model step (usage 95 >= 90% of window 100).
async test "scope/compact_scoped_to_run_without_effect_id" {
  let compacted : @kernel.CompactResult = {
    compacted_messages: [tk_user_msg("summary")],
    mode: Replace,
  }
  let model = ScopeRecordingModel(
    [
      Respond(scope_test_tool_call_with_usage(95)),
      Respond(tk_stop_response("done")),
    ],
    compact_result=compacted,
  )
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools], sessions=[RecordingSessionStore()]),
    ],
    config={ ..tk_config(), model_context_window: Some(100), },
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_compact"))
  let chat_scopes = model.chat_scopes()
  let compact_scopes = model.compact_scopes()
  assert_eq(compact_scopes.length(), 1)
  assert_eq(compact_scopes[0].session_id.to_string(), "session_compact")
  // Same run as the chat calls that triggered it; no effect identity.
  assert_eq(compact_scopes[0].run_id, chat_scopes[0].run_id)
  assert_true(compact_scopes[0].effect_id is None)
}
