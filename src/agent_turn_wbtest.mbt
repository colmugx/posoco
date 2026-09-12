// ---------------------------------------------------------------------------
// Turn-path fixate tests: persisted dangling tool calls are repaired into
// every loaded window (fixate_pending_tool_calls in agent_turn.mbt) so the
// replayed transcript stays wire-valid for providers that require each
// function_call to carry a matching function_call_output.
// ---------------------------------------------------------------------------

///|
fn turn_fixate_dangling_call(call_id : String) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(call_id),
    name: @kernel.ToolName::unchecked("echo"),
    arguments: Json::null(),
  }
}

///|
fn turn_fixate_dangling_assistant(
  text : String,
  call : @kernel.ToolCall,
) -> @kernel.Message {
  AssistantMessage(
    content=[Text(text)],
    tool_calls=[call],
    reasoning=None,
    finish_reason=ToolCalls,
  )
}

///|
fn count_tool_outputs(
  messages : Array[@kernel.Message],
  call_id : String,
) -> Int {
  let mut count = 0
  for message in messages {
    match message {
      ToolMessage(call_id=id, ..) =>
        if id.to_string() == call_id {
          count = count + 1
        }
      _ => ()
    }
  }
  count
}

///|
fn count_user_messages(messages : Array[@kernel.Message]) -> Int {
  let mut count = 0
  for message in messages {
    match message {
      UserMessage(..) => count = count + 1
      _ => ()
    }
  }
  count
}

///|
async test "turn path fixates dangling trailing tool calls into the next model window" {
  let call = turn_fixate_dangling_call("call_turn_fix")
  let store = RecordingSessionStore()
  store.seed("turn-fixate", {
    messages: [
      tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
    ],
    metadata: Map::from_array([]),
  })
  let model = ScriptedModel([Respond(tk_stop_response("after repair"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("next request"), "turn-fixate"))
  assert_eq(model.call_count(), 1)
  let window = model.received_messages[0]
  assert_eq(window.length(), 4)
  assert_true(window[0] == tk_user_msg("do the thing"))
  guard window[1] is AssistantMessage(tool_calls=[owner, ..], ..) else {
    fail("expected the dangling assistant message at index 1")
  }
  assert_true(owner == call)
  guard window[2]
    is ToolMessage(
      call_id=synthesized_id,
      tool_name=synthesized_tool,
      outcome=RuntimeFailure(error_category~, message~)
    ) else {
    fail("expected the synthesized interrupted output directly after the owner")
  }
  assert_true(synthesized_id == owner.call_id)
  assert_true(synthesized_tool == owner.name)
  assert_eq(error_category, "Interrupted")
  assert_eq(
    message, "tool call was pending when the previous operation ended; recorded as interrupted",
  )
  assert_true(window[3] == tk_user_msg("next request"))
  // The trailing synthesis rides the appended tail, so the persisted session
  // is healed: the call is answered on disk and later loads synthesize
  // nothing.
  let persisted = store.store["turn-fixate"]
  assert_eq(persisted.messages.length(), 5)
  assert_eq(count_tool_outputs(persisted.messages, "call_turn_fix"), 1)
}

///|
async test "resume over dangling calls replays the persisted trailing user once" {
  let call = turn_fixate_dangling_call("call_resume_fix")
  let store = RecordingSessionStore()
  store.seed("turn-resume", {
    messages: [
      tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
      tk_user_msg("please continue"),
    ],
    metadata: Map::from_array([]),
  })
  let model = ScriptedModel([Respond(tk_stop_response("resumed work"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.resume_turn("turn-resume"))
  assert_eq(model.call_count(), 1)
  let window = model.received_messages[0]
  assert_eq(window.length(), 4)
  assert_true(window[0] == tk_user_msg("do the thing"))
  guard window[1] is AssistantMessage(tool_calls=[owner, ..], ..) else {
    fail("expected the dangling assistant message at index 1")
  }
  guard window[2]
    is ToolMessage(
      call_id=synthesized_id,
      outcome=RuntimeFailure(error_category~, ..),
      ..
    ) else {
    fail("expected the synthesized interrupted output between owner and user")
  }
  assert_true(synthesized_id == owner.call_id)
  assert_eq(error_category, "Interrupted")
  // The persisted user message is replayed exactly once, still last.
  assert_true(window[3] == tk_user_msg("please continue"))
  assert_eq(count_user_messages(window), 2)
  // Append-save math must not re-persist the replayed user message.
  let persisted = store.store["turn-resume"]
  assert_eq(persisted.messages.length(), 4)
  assert_true(persisted.messages[2] == tk_user_msg("please continue"))
  assert_eq(count_user_messages(persisted.messages), 2)
  assert_true(
    persisted.messages[3]
    is AssistantMessage(content=[Text("resumed work"), ..], ..),
  )
}

///|
test "fixate inserts synthesized outputs immediately after the owning assistant" {
  let c1a = turn_fixate_dangling_call("call_1a")
  let c1b = turn_fixate_dangling_call("call_1b")
  let c2a = turn_fixate_dangling_call("call_2a")
  let c2b = turn_fixate_dangling_call("call_2b")
  let interrupted : @kernel.ToolOutcome = RuntimeFailure(
    error_category="Interrupted",
    message="tool call was pending when the previous operation ended; recorded as interrupted",
  )
  let raw : Array[@kernel.Message] = [
    tk_user_msg("u1"),
    AssistantMessage(
      content=[Text("a1")],
      tool_calls=[c1a, c1b],
      reasoning=None,
      finish_reason=ToolCalls,
    ),
    tk_user_msg("u2"),
    ToolMessage(
      call_id=c1a.call_id,
      tool_name=c1a.name,
      outcome=tk_ok_result("late real answer"),
    ),
    AssistantMessage(
      content=[Text("a2")],
      tool_calls=[c2a, c2b],
      reasoning=None,
      finish_reason=ToolCalls,
    ),
    tk_user_msg("u3"),
  ]
  let fixated = fixate_pending_tool_calls(raw)
  let expected : Array[@kernel.Message] = [
    tk_user_msg("u1"),
    AssistantMessage(
      content=[Text("a1")],
      tool_calls=[c1a, c1b],
      reasoning=None,
      finish_reason=ToolCalls,
    ),
    ToolMessage(call_id=c1b.call_id, tool_name=c1b.name, outcome=interrupted),
    tk_user_msg("u2"),
    ToolMessage(
      call_id=c1a.call_id,
      tool_name=c1a.name,
      outcome=tk_ok_result("late real answer"),
    ),
    AssistantMessage(
      content=[Text("a2")],
      tool_calls=[c2a, c2b],
      reasoning=None,
      finish_reason=ToolCalls,
    ),
    ToolMessage(call_id=c2a.call_id, tool_name=c2a.name, outcome=interrupted),
    ToolMessage(call_id=c2b.call_id, tool_name=c2b.name, outcome=interrupted),
    tk_user_msg("u3"),
  ]
  assert_eq(fixated.length(), expected.length())
  for i in 0..<expected.length() {
    assert_true(fixated[i] == expected[i])
  }
  // The input is untouched and fixating a fixated window is identity.
  assert_eq(raw.length(), 6)
  assert_true(fixate_pending_tool_calls(fixated) == fixated)
}

///|
async test "consecutive turns keep exactly one interrupted output per dangling call" {
  let call = turn_fixate_dangling_call("call_stable")
  let store = RecordingSessionStore()
  store.seed("turn-stable", {
    messages: [
      tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
    ],
    metadata: Map::from_array([]),
  })
  let model = ScriptedModel([
    Respond(tk_stop_response("first")),
    Respond(tk_stop_response("second")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("second ask"), "turn-stable"))
  ignore(agent.run_turn(tk_user_msg("third ask"), "turn-stable"))
  assert_eq(model.call_count(), 2)
  let first_window = model.received_messages[0]
  let second_window = model.received_messages[1]
  assert_eq(first_window.length(), 4)
  assert_eq(count_tool_outputs(first_window, "call_stable"), 1)
  // The first save persisted the synthesized output, so the second window
  // replays it verbatim without synthesizing a duplicate.
  assert_eq(second_window.length(), 6)
  assert_eq(count_tool_outputs(second_window, "call_stable"), 1)
  guard second_window[2]
    is ToolMessage(outcome=RuntimeFailure(error_category~, ..), ..) else {
    fail("expected the persisted interrupted output at index 2")
  }
  assert_eq(error_category, "Interrupted")
  let persisted = store.store["turn-stable"]
  assert_eq(persisted.messages.length(), 7)
  assert_eq(count_tool_outputs(persisted.messages, "call_stable"), 1)
}
