///|
async test "agent step delivery/normal stop continues same turn with FIFO snapshots" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first")),
    Respond(@test_support.tk_stop_response("revised")),
  ])
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", observers=[observer]),
    ],
    config=agent_config(),
  )
  let control = agent.control()
  let posted = Ref(false)
  let outcomes : Array[@runtime.EnqueueOutcome] = []
  let late : Array[@runtime.EnqueueOutcome] = []
  let turns : Array[String] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      match envelope.event {
        @events.Core(ModelRequestStarted) => {
          if envelope.scope is Some(scope) {
            turns.push(scope.turn_id.to_string())
          }
          if !posted.val {
            posted.val = true
            let content : Array[@kernel.Content] = [Text("original")]
            outcomes.push(control.enqueue_steer(UserMessage(content~)))
            content[0] = Text("mutated after acceptance")
            outcomes.push(
              control.enqueue_steer(@test_support.tk_user_msg("second")),
            )
          }
        }
        @events.Core(ModelResponseReceived(..)) if model.call_count() == 2 =>
          late.push(
            control.enqueue_steer(@test_support.tk_user_msg("too late")),
          )
        _ => ()
      }
    })
    .unwrap()
  defer subscription.cancel()
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "step-normal"))
  assert_eq(model.call_count(), 2)
  assert_eq(steer_user_texts(model.received_messages[0]), ["hello"])
  assert_eq(steer_user_texts(model.received_messages[1]), [
    "hello", "original", "second",
  ])
  assert_eq(turns.length(), 2)
  assert_eq(turns[0], turns[1])
  assert_true(outcomes is [Accepted(_), Accepted(_)])
  assert_true(late is [RejectedStale(_)])
  let events = observer.events()
  assert_eq(events.filter(fn(event) { event is TurnStarted }).length(), 1)
  assert_eq(events.filter(fn(event) { event is TurnCompleted }).length(), 1)
  assert_eq(
    events
    .filter(fn(event) { event is MessageApplied(delivery=Step, ..) })
    .length(),
    2,
  )
  assert_false(events.any(fn(event) { event is MessageUndelivered(..) }))
}

///|
async test "agent step delivery/model response cannot launch superseded tools" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "old-call", {})),
    Respond(@test_support.tk_stop_response("replanned")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo")],
    Map::from_array([]),
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", observers=[observer]),
    ],
    config=agent_config(),
  )
  let control = agent.control()
  let submitted = Ref(false)
  let outcomes : Array[@runtime.EnqueueOutcome] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is @events.Core(ModelRequestStarted) && !submitted.val {
        submitted.val = true
        outcomes.push(
          control.enqueue_steer(@test_support.tk_user_msg("do not execute")),
        )
      }
    })
    .unwrap()
  defer subscription.cancel()
  ignore(
    agent.run_turn(@test_support.tk_user_msg("hello"), "step-before-tools"),
  )
  assert_true(outcomes is [Accepted(_)])
  assert_eq(tools.exec_records().length(), 0)
  assert_eq(model.call_count(), 2)
  let messages = model.received_messages[1]
  assert_true(
    messages[1] is AssistantMessage(tool_calls=[{ call_id, .. }], ..) &&
    call_id.to_string() == "old-call",
  )
  assert_true(
    messages[2]
    is ToolMessage(
      call_id~,
      outcome=NotExecuted(reason=SupersededByMessage, ..),
      ..
    ) &&
    call_id.to_string() == "old-call",
  )
  assert_eq(steer_user_texts(messages), ["hello", "do not execute"])
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is ToolCallAbandoned(..) })
    .length(),
    1,
  )
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is MessageApplied(delivery=Step, ..) })
    .length(),
    1,
  )
}

///|
struct StepWaveTools {
  mut control : AgentControl?
  calls : Array[String]
  parallel : Bool
}

///|
pub extend StepWaveTools with @port.ToolProvider::{list_tools, execute}

///|
pub impl @port.ToolProvider for StepWaveTools with fn list_tools(self) {
  ["first", "second", "third"].map(fn(name) {
    @kernel.ToolDef(
      name=@kernel.ToolName::unchecked(name),
      description=name,
      input_schema={},
      owner=@kernel.OwnerId::unchecked("placeholder"),
      policy=if self.parallel && name != "third" {
        Parallel
      } else {
        Sequential
      },
      provenance=None,
    )
  })
}

///|
pub impl @port.ToolProvider for StepWaveTools with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  self.calls.push(ctx.name.to_string())
  if ctx.name.to_string() == "first" {
    let control = self.control.unwrap()
    guard control.enqueue_steer(@test_support.tk_user_msg("change course"))
      is Accepted(_) else {
      raise InvocationFailed("steer was not accepted")
    }
  }
  Success(content="real first result", structured=None)
}

///|
async test "agent step delivery/launched wave finishes but later wave never starts" {
  let calls : Array[@kernel.ToolCall] = ["first", "second"].map(fn(name) {
    {
      call_id: @kernel.CallId::unchecked(name),
      name: @kernel.ToolName::unchecked(name),
      arguments: {},
    }
  })
  let response : @kernel.ModelCallResult = {
    completion: @kernel.Completion(
      content=[],
      tool_calls=calls,
      reasoning=None,
      finish_reason=ToolCalls,
      usage=None,
    ),
    processed_messages: [],
  }
  let model = @test_support.ScriptedModel([
    Respond(response),
    Respond(@test_support.tk_stop_response("replanned")),
  ])
  let tools = StepWaveTools::{ control: None, calls: [], parallel: false, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", observers=[observer]),
    ],
    config=agent_config(),
  )
  tools.control = Some(agent.control())
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "step-waves"))
  assert_eq(tools.calls, ["first"])
  assert_eq(model.call_count(), 2)
  let messages = model.received_messages[1]
  assert_true(
    messages[2]
    is ToolMessage(
      call_id~,
      outcome=Success(content="real first result", ..),
      ..
    ) &&
    call_id.to_string() == "first",
  )
  assert_true(
    messages[3]
    is ToolMessage(
      call_id~,
      outcome=NotExecuted(reason=SupersededByMessage, ..),
      ..
    ) &&
    call_id.to_string() == "second",
  )
  assert_eq(steer_user_texts(messages), ["hello", "change course"])
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is ToolCallSucceeded(..) })
    .length(),
    1,
  )
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is ToolCallAbandoned(..) })
    .length(),
    1,
  )
  assert_eq(
    observer.events().filter(fn(event) { event is TurnStarted }).length(),
    1,
  )
}

///|
async test "agent step delivery/all roots in a launched parallel wave keep real outcomes" {
  let calls : Array[@kernel.ToolCall] = ["first", "second", "third"].map(fn(
    name,
  ) {
    {
      call_id: @kernel.CallId::unchecked(name),
      name: @kernel.ToolName::unchecked(name),
      arguments: {},
    }
  })
  let model = @test_support.ScriptedModel([
    Respond({
      completion: @kernel.Completion(
        content=[],
        tool_calls=calls,
        reasoning=None,
        finish_reason=ToolCalls,
        usage=None,
      ),
      processed_messages: [],
    }),
    Respond(@test_support.tk_stop_response("replanned")),
  ])
  let tools = StepWaveTools::{ control: None, calls: [], parallel: true, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", observers=[observer]),
    ],
    config=agent_config(),
  )
  tools.control = Some(agent.control())
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "step-parallel"))
  assert_eq(tools.calls.length(), 2)
  assert_true(tools.calls.contains("first"))
  assert_true(tools.calls.contains("second"))
  assert_eq(model.call_count(), 2)
  let results = model.received_messages[1].filter(fn(message) {
    message is ToolMessage(..)
  })
  assert_true(
    results
    is [
      ToolMessage(call_id=first, outcome=Success(..), ..),
      ToolMessage(call_id=second, outcome=Success(..), ..),
      ToolMessage(
        call_id=third,
        outcome=NotExecuted(reason=SupersededByMessage, ..),
        ..
      ),
    ] &&
    first.to_string() == "first" &&
    second.to_string() == "second" &&
    third.to_string() == "third",
  )
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is ToolCallSucceeded(..) })
    .length(),
    2,
  )
  assert_eq(
    observer
    .events()
    .filter(fn(event) { event is ToolCallAbandoned(..) })
    .length(),
    1,
  )
}

///|
async test "agent step delivery/committed receipt survives checkpoint failure before projection" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first")),
    Respond(@test_support.tk_stop_response("next operation")),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(),
  )
  let command_id : Ref[String?] = Ref(None)
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is @events.Core(ModelRequestStarted) &&
        command_id.val is None {
        match
          agent
          .control()
          .enqueue_steer(@test_support.tk_user_msg("committed change")) {
          Accepted(command_id=id) => command_id.val = Some(id)
          _ => ()
        }
        store.fail_save("step-checkpoint-failure")
      }
    })
    .unwrap()
  defer subscription.cancel()
  try
    agent.run_turn(
      @test_support.tk_user_msg("hello"),
      "step-checkpoint-failure",
    )
  catch {
    error => assert_true(error.to_string().contains("checkpoint"))
  } noraise {
    _ => fail("expected checkpoint failure")
  }
  let id = command_id.val.unwrap()
  let deliveries = observer
    .events()
    .filter(fn(event) {
      match event {
        MessageApplied(command_id~, ..) | MessageUndelivered(command_id~, ..) =>
          command_id == id
        _ => false
      }
    })
  assert_true(deliveries is [MessageApplied(delivery=Step, ..)])
  assert_eq(agent.control().pending_steers(), 0)
  store.heal_save("step-checkpoint-failure")
  ignore(
    agent.run_turn(
      @test_support.tk_user_msg("after failure"),
      "step-checkpoint-failure",
    ),
  )
  assert_eq(
    observer
    .events()
    .filter(fn(event) {
      event is MessageApplied(command_id~, ..) && command_id == id
    })
    .length(),
    1,
  )
}

///|
/// Agent-level acceptance for step-boundary steering
/// (docs/message-delivery-boundaries.md §5.6.4): a host submits through the
/// public control handle while a tool is running, and the next model request
/// must contain the message.

///|
/// Tool provider whose `execute` submits one steer through the Agent's control
/// handle, mirroring a host that steers while a tool is in flight.
struct SteeringToolProvider {
  defs : Array[@kernel.ToolDef]
  steer_text : String
  mut control : AgentControl?
  mut accepted_command_id : String
  mut pending_at_submit : Int32
}

///|
fn SteeringToolProvider::SteeringToolProvider(
  defs : Array[@kernel.ToolDef],
  steer_text : String,
) -> SteeringToolProvider {
  {
    defs,
    steer_text,
    control: None,
    accepted_command_id: "",
    pending_at_submit: -1,
  }
}

///|
pub extend SteeringToolProvider with @port.ToolProvider::{list_tools, execute}

///|
pub impl @port.ToolProvider for SteeringToolProvider with fn list_tools(self) {
  self.defs.copy()
}

///|
pub impl @port.ToolProvider for SteeringToolProvider with fn execute(
  self,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let control = match self.control {
    Some(control) => control
    None => raise InvocationFailed("steering tool has no control handle")
  }
  match control.enqueue_steer(UserMessage(content=[Text(self.steer_text)])) {
    Accepted(command_id~) => self.accepted_command_id = command_id
    _ => ()
  }
  self.pending_at_submit = control.pending_steers()
  Success(content="steered", structured=None)
}

///|
/// User-authored text in a model request, in transcript order.
fn steer_user_texts(messages : Array[@kernel.Message]) -> Array[String] {
  let out : Array[String] = []
  for message in messages {
    guard message is UserMessage(content~) else { continue }
    for block in content {
      guard block is Text(text) else { continue }
      out.push(text)
    }
  }
  out
}

///|
async test "agent steer/mid-tool steer reaches the next model request" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = SteeringToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    "keep to analysis only",
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  tools.control = Some(agent.control())
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "session_steer",
  )
  assert_eq(result.final_session_id, "session_steer")
  assert_eq(model.call_count(), 2)
  // The steer was accepted mid-tool and still queued when the tool returned.
  assert_true(tools.accepted_command_id != "")
  assert_eq(tools.pending_at_submit, 1)
  // Step 1 was dispatched before the steer existed; step 2 carries it after
  // the committed tool result.
  assert_eq(steer_user_texts(model.received_messages[0]), ["hello"])
  assert_eq(steer_user_texts(model.received_messages[1]), [
    "hello", "keep to analysis only",
  ])
  // The tool-batch boundary drained the queue.
  assert_eq(agent.control().pending_steers(), 0)
  // Public observer surface: the applied steer is projected as
  // `MessageApplied` (step-bound, with the acceptance receipt) between the
  // committed tool outcome and the next model request it re-arms.
  let mut succeeded_at = -1
  let model_starts : Array[Int32] = []
  let applied : Array[String] = []
  for i, event in observer.events() {
    match event {
      ToolCallSucceeded(..) => succeeded_at = i
      ModelRequestStarted => model_starts.push(i)
      MessageApplied(command_id~, delivery=Step) => applied.push(command_id)
      _ => ()
    }
  }
  assert_eq(model_starts.length(), 2)
  assert_eq(applied, [tools.accepted_command_id])
  let mut applied_at = -1
  for i, event in observer.events() {
    guard event is MessageApplied(command_id~, ..) else { continue }
    if command_id == tools.accepted_command_id {
      applied_at = i
    }
  }
  assert_true(succeeded_at < applied_at && applied_at < model_starts[1])
}

///|
/// §5.6.4 remainder: the steer is a persisted session fact, not just an
/// in-memory transcript entry. The host must be able to read it back from the
/// session store after the run, at the transcript index it really occupies.
async test "agent steer/steer message is persisted at its transcript index" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = SteeringToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    "keep to analysis only",
  )
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  tools.control = Some(agent.control())
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "session_steer_persist",
  )
  assert_true(result.final_session_id == "session_steer_persist")
  // The durable session holds the steer after the run, in transcript order.
  let saved = store.store["session_steer_persist"]
  assert_eq(steer_user_texts(saved.messages), ["hello", "keep to analysis only"])
  // Each committed message is projected incrementally, so the steer appears as
  // its own append at index 3 (after the tool result) instead of waiting for
  // the terminal full save.
  let increments : Array[(Int32, Array[String])] = []
  for op in store.ops() {
    match op {
      OpCheckpoint(id="session_steer_persist", checkpoint~, ..) if !checkpoint.messages.is_empty() =>
        increments.push(
          (checkpoint.from_index, steer_user_texts(checkpoint.messages)),
        )
      _ => ()
    }
  }
  assert_eq(increments.map(fn(pair) { pair.0 }), [1, 2, 3, 4])
  assert_eq(increments[2].1, ["keep to analysis only"])
}
