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
    Respond(@test_support.tk_stop_response("after repair")),
  ])
  let agent = Agent(
    events=EventSystem(),
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
      outcome=RuntimeFailure(error_category~, message~),
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
    Respond(@test_support.tk_stop_response("resumed work")),
  ])
  let agent = Agent(
    events=EventSystem(),
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
    Respond(@test_support.tk_stop_response("second")),
  ])
  let agent = Agent(
    events=EventSystem(),
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

///|
async test "rate-limit resume replays persisted user without duplicating transcript" {
  let model = @test_support.ScriptedModel([
    Fail(
      RateLimited({
        message: "quota exhausted",
        reset_at_ms: Some(1000L),
        provider_code: Some("429"),
      }),
    ),
    Respond(@test_support.tk_stop_response("resumed")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let first = Ok(
    agent.run_turn(@test_support.tk_user_msg("original task"), "resume-user"),
  ) catch {
    error => Err(error)
  }
  match first {
    Err(Model(msg)) => {
      assert_true(msg.contains("model quota exhausted"))
      assert_true(msg.contains("code=429"))
      assert_true(msg.contains("reset_at_ms=1000"))
      assert_true(msg.contains("message=quota exhausted"))
    }
    _ => fail("expected AgentError::Model carrying the rate-limit verdict")
  }
  ignore(agent.resume_turn("resume-user"))
  assert_eq(model.received_messages.length(), 2)
  let retried = model.received_messages[1]
  assert_eq(retried.length(), 1)
  assert_true(retried[0] == @test_support.tk_user_msg("original task"))
  let persisted = store.store["resume-user"]
  assert_eq(persisted.messages.length(), 2)
  assert_true(
    persisted.messages[0] == @test_support.tk_user_msg("original task"),
  )
  assert_true(
    persisted.messages[1] is AssistantMessage(content=[Text("resumed"), ..], ..),
  )
}

///|
async test "rate-limit resume after tool progress appends continue" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Fail(
      RateLimited({
        message: "quota after tool progress",
        reset_at_ms: Some(2000L),
        provider_code: Some("429"),
      }),
    ),
    Respond(@test_support.tk_stop_response("finished")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("echoed")))]),
  )
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let first = Ok(
    agent.run_turn(@test_support.tk_user_msg("do work"), "resume-progress-real"),
  ) catch {
    error => Err(error)
  }
  match first {
    Err(Model(msg)) => {
      assert_true(msg.contains("model quota exhausted"))
      assert_true(msg.contains("message=quota after tool progress"))
    }
    _ => fail("expected AgentError::Model carrying the rate-limit verdict")
  }
  let failed = store.store["resume-progress-real"]
  assert_eq(failed.messages.length(), 3)
  assert_true(failed.messages[2] is ToolMessage(..))
  ignore(agent.resume_turn("resume-progress-real"))
  let resumed_request = model.received_messages[2]
  assert_eq(resumed_request.length(), 4)
  assert_true(resumed_request[0] == @test_support.tk_user_msg("do work"))
  assert_true(resumed_request[3] == @test_support.tk_user_msg("continue"))
  let persisted = store.store["resume-progress-real"]
  assert_eq(persisted.messages.length(), 5)
  assert_true(
    persisted.messages[4]
    is AssistantMessage(content=[Text("finished"), ..], ..),
  )
}

///|
/// Store whose save fails from the `fail_from`-th call onward, so the
/// failed-turn transcript path can be observed end to end through the public
/// Agent interface.
struct SaveFailingStore {
  mut saves : Int32
  fail_from : Int32
}

///|
impl @port.SessionPort for SaveFailingStore with fn load(_self, _id) -> @types.Session {
  { messages: [], metadata: Map::from_array([]), }
}

///|
impl @port.SessionPort for SaveFailingStore with fn save(self, _id, _session) -> Unit raise @error.SessionError {
  self.saves = self.saves + 1
  if self.saves >= self.fail_from {
    raise Save("store offline")
  }
}

///|
async test "rate-limit failure persists best-effort and reports save failure as secondary" {
  let model = @test_support.ScriptedModel([
    // Usage on the completed step gives the Puppet a context reading, so the
    // failed turn's terminal save carries changed metadata (a real store
    // write) instead of collapsing into the incremental checkpoints.
    Respond(scope_test_tool_call_with_usage(10)),
    Fail(
      RateLimited({
        message: "quota exhausted",
        reset_at_ms: Some(1000L),
        provider_code: Some("429"),
      }),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("echoed")))]),
  )
  let store = SaveFailingStore::{ saves: 0, fail_from: 4, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(
      max_tool_rounds=Some(10),
      model_context_window=Some(1000),
      compact_threshold=Some(0.9),
    ),
  )
  let first = Ok(
    agent.run_turn(@test_support.tk_user_msg("original task"), "failed-save"),
  ) catch {
    error => Err(error)
  }
  guard first is Err(Model(msg)) else {
    let why = match first {
      Err(e) => e.to_string()
      Ok(_) => "turn completed"
    }
    fail("expected Model error, got \{why}; saves=\{store.saves}")
  }
  assert_true(msg.contains("model quota exhausted"))
  // The failed turn attempted exactly one transcript save against the store
  // (after the admission and per-boundary checkpoint saves).
  assert_eq(store.saves, 4)
  // The save failure stays observable without replacing the primary error.
  let failures = secondary_failure_errors(
    observer, "failed_turn_transcript_save",
  )
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("session_id=failed-save"))
  assert_true(failures[0].contains("SessionError::Save"))
}
