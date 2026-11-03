///|
/// Rewind primitive regression tests: `SessionPort::truncate`.
///
/// The Agent reloads persisted history from the store at the start of every
/// turn, so truncating the store changes what the next turn sees. This test
/// pins the Agent-level end-to-end behaviour.

///|
/// The assistant reply persisted by turn 1 in the scripted two-turn history.
fn truncate_first_assistant() -> @kernel.Message {
  AssistantMessage(
    content=[Text("first")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
}

///|
async test "rewind_truncate_changes_history_seen_by_next_agent_turn" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("third"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s1")
  let _ = agent.run_turn(@test_support.tk_user_msg("world"), "s1")
  // External rewind changes only the projection; the existing Agent keeps
  // its confirmed core history.
  store.truncate("s1", 2)
  let fresh_model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("fresh"),
    ),
  ])
  let fresh = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(fresh_model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = fresh.run_turn(@test_support.tk_user_msg("new"), "s1")
  let fresh_prompt = fresh_model.received_messages[0]
  assert_eq(fresh_prompt.length(), 3)
  assert_true(fresh_prompt[0] == @test_support.tk_user_msg("hello"))
  assert_true(fresh_prompt[1] == truncate_first_assistant())
  assert_true(fresh_prompt[2] == @test_support.tk_user_msg("new"))
  // The existing Agent still reads core, not the externally truncated store.
  let _ = agent.run_turn(@test_support.tk_user_msg("more"), "s1")
  assert_eq(model.received_messages.length(), 3)
  let prompt = model.received_messages[2]
  assert_eq(prompt.length(), 5)
  assert_true(prompt[0] == @test_support.tk_user_msg("hello"))
  assert_true(prompt[1] == truncate_first_assistant())
  assert_true(prompt[2] == @test_support.tk_user_msg("world"))
  assert_true(prompt[4] == @test_support.tk_user_msg("more"))
}
