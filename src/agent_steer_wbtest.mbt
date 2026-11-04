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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
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
      MessageApplied(command_id~, delivery=@types.MessageDeliveryKind::Step) =>
        applied.push(command_id)
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
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
      @test_support.SessionOp::OpCheckpoint(
        id="session_steer_persist",
        checkpoint~,
        ..
      ) if !checkpoint.messages.is_empty() =>
        increments.push(
          (checkpoint.from_index, steer_user_texts(checkpoint.messages)),
        )
      _ => ()
    }
  }
  assert_eq(increments.map(fn(pair) { pair.0 }), [1, 2, 3, 4])
  assert_eq(increments[2].1, ["keep to analysis only"])
}
