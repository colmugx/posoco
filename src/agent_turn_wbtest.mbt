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
) -> Int32 {
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
fn count_user_messages(messages : Array[@kernel.Message]) -> Int32 {
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
  let store = @test_support.RecordingSessionPort()
  store.seed("turn-fixate", {
    messages: [
      @test_support.tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
    ],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("after repair"),
    ),
  ])
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(
    agent.run_turn(@test_support.tk_user_msg("next request"), "turn-fixate"),
  )
  assert_eq(model.call_count(), 1)
  let window = model.received_messages[0]
  assert_eq(window.length(), 4)
  assert_true(window[0] == @test_support.tk_user_msg("do the thing"))
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
  assert_true(window[3] == @test_support.tk_user_msg("next request"))
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
  let store = @test_support.RecordingSessionPort()
  store.seed("turn-resume", {
    messages: [
      @test_support.tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
      @test_support.tk_user_msg("please continue"),
    ],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("resumed work"),
    ),
  ])
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.resume_turn("turn-resume"))
  assert_eq(model.call_count(), 1)
  let window = model.received_messages[0]
  assert_eq(window.length(), 4)
  assert_true(window[0] == @test_support.tk_user_msg("do the thing"))
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
  assert_true(window[3] == @test_support.tk_user_msg("please continue"))
  assert_eq(count_user_messages(window), 2)
  // Append-save math must not re-persist the replayed user message.
  let persisted = store.store["turn-resume"]
  // The initial full alignment persists the fixated window, then the terminal
  // append adds the resumed assistant. The replayed user stays exactly once.
  assert_eq(persisted.messages.length(), 5)
  guard persisted.messages[2]
    is ToolMessage(outcome=RuntimeFailure(error_category="Interrupted", ..), ..) else {
    fail("expected the persisted interrupted output at index 2")
  }
  assert_true(
    persisted.messages[3] == @test_support.tk_user_msg("please continue"),
  )
  assert_eq(count_user_messages(persisted.messages), 2)
  assert_true(
    persisted.messages[4]
    is AssistantMessage(content=[Text("resumed work"), ..], ..),
  )
}

///|
async test "consecutive turns keep exactly one interrupted output per dangling call" {
  let call = turn_fixate_dangling_call("call_stable")
  let store = @test_support.RecordingSessionPort()
  store.seed("turn-stable", {
    messages: [
      @test_support.tk_user_msg("do the thing"),
      turn_fixate_dangling_assistant("working on it", call),
    ],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
  ])
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("second ask"), "turn-stable"))
  ignore(agent.run_turn(@test_support.tk_user_msg("third ask"), "turn-stable"))
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
