///|
fn control_text_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
/// Tool provider whose `execute` submits follow-ups through the Agent's
/// public control handle, mirroring a host that queues work while a tool is
/// in flight.
struct FollowUpToolProvider {
  defs : Array[@kernel.ToolDef]
  texts : Array[String]
  /// `true`: submit every text on one execution (a host queuing a burst);
  /// `false`: submit one text per execution (a chain that grows reentrantly).
  batch : Bool
  /// Request cancellation of the run after submitting, mirroring a host that
  /// aborts while its message is still queued.
  abort_after : Bool
  mut control : AgentControl?
  mut calls : Int32
  accepted_ids : Array[String]
}

///|
fn FollowUpToolProvider::FollowUpToolProvider(
  defs : Array[@kernel.ToolDef],
  texts : Array[String],
  batch~ : Bool = false,
  abort_after~ : Bool = false,
) -> FollowUpToolProvider {
  {
    defs,
    texts,
    batch,
    abort_after,
    control: None,
    calls: 0,
    accepted_ids: [],
  }
}

///|
pub extend FollowUpToolProvider with @port.ToolProvider::{list_tools, execute}

///|
pub impl @port.ToolProvider for FollowUpToolProvider with fn list_tools(self) {
  self.defs.copy()
}

///|
pub impl @port.ToolProvider for FollowUpToolProvider with fn execute(
  self,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let control = match self.control {
    Some(control) => control
    None => raise InvocationFailed("follow-up tool has no control handle")
  }
  let call = self.calls
  self.calls = call + 1
  if self.batch {
    for text in self.texts {
      match control.enqueue_follow_up(control_text_message(text)) {
        Accepted(command_id~) => self.accepted_ids.push(command_id)
        _ => ()
      }
    }
  } else if call < self.texts.length() {
    match control.enqueue_follow_up(control_text_message(self.texts[call])) {
      Accepted(command_id~) => self.accepted_ids.push(command_id)
      _ => ()
    }
  }
  if self.abort_after {
    ignore(control.abort_active(Some("cancel while queued")))
  }
  Success(content="echoed", structured=None)
}

///|
/// User-authored text in a model request, in transcript order.
fn request_user_texts(messages : Array[@kernel.Message]) -> Array[String] {
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
/// Public FIFO regression: follow-ups submitted while the initial turn ran
/// become consecutive full turns in submission order, and `run_turn` returns
/// the last drained turn's result.
async test "agent control/follow-ups drain FIFO across turns and return the last result" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("turn one")),
    Respond(@test_support.tk_stop_response("first done")),
    Respond(@test_support.tk_stop_response("second done")),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["first", "second"],
    batch=true,
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
    "session_followup_fifo",
  )
  assert_eq(model.call_count(), 4)
  // Turn 1 ran with its own input only; each follow-up opened the next turn
  // as fresh input on the accumulated transcript, in submission order.
  assert_eq(request_user_texts(model.received_messages[0]), ["hello"])
  assert_eq(request_user_texts(model.received_messages[1]), ["hello"])
  assert_eq(request_user_texts(model.received_messages[2]), ["hello", "first"])
  assert_eq(request_user_texts(model.received_messages[3]), [
    "hello", "first", "second",
  ])
  guard result.message is AssistantMessage(content=[Text(last)], ..) else {
    fail("expected the last follow-up turn's assistant reply")
  }
  assert_eq(last, "second done")
  assert_eq(tools.accepted_ids.length(), 2)
  assert_eq(agent.control().pending_follow_ups(), 0)
}

///|
/// Reentrant submission: a tool executing inside a drained follow-up turn can
/// queue the next follow-up, and the same `run_turn` call keeps draining the
/// chain in order.
async test "agent control/reentrant follow-up enqueued during a drained turn extends the chain" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("turn one")),
    Respond(@test_support.tk_tool_call_response("echo", "call_2", Json::null())),
    Respond(@test_support.tk_stop_response("first done")),
    Respond(@test_support.tk_stop_response("second done")),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["first", "second"],
  )
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  tools.control = Some(agent.control())
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "session_followup_reentrant",
  )
  assert_eq(model.call_count(), 5)
  assert_eq(request_user_texts(model.received_messages[2]), ["hello", "first"])
  assert_eq(request_user_texts(model.received_messages[4]), [
    "hello", "first", "second",
  ])
  guard result.message is AssistantMessage(content=[Text(last)], ..) else {
    fail("expected the final follow-up turn's assistant reply")
  }
  assert_eq(last, "second done")
  assert_eq(agent.control().pending_follow_ups(), 0)
}

///|
/// Tool provider that records the control handle's stale-target verdict: the
/// first execution pins the target it observed, the second tries to submit
/// against that pin from a later turn.
struct TargetPinToolProvider {
  defs : Array[@kernel.ToolDef]
  mut control : AgentControl?
  mut pinned : MessageTarget?
  mut stale_rejected : Bool
  accepted_ids : Array[String]
}

///|
fn TargetPinToolProvider::TargetPinToolProvider(
  defs : Array[@kernel.ToolDef],
) -> TargetPinToolProvider {
  {
    defs,
    control: None,
    pinned: None,
    stale_rejected: false,
    accepted_ids: [],
  }
}

///|
pub extend TargetPinToolProvider with @port.ToolProvider::{list_tools, execute}

///|
pub impl @port.ToolProvider for TargetPinToolProvider with fn list_tools(self) {
  self.defs.copy()
}

///|
pub impl @port.ToolProvider for TargetPinToolProvider with fn execute(
  self,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let control = match self.control {
    Some(control) => control
    None => raise InvocationFailed("target-pin tool has no control handle")
  }
  if self.pinned is None {
    self.pinned = control.current_message_target()
    match control.enqueue_follow_up(control_text_message("follow me")) {
      Accepted(command_id~) => self.accepted_ids.push(command_id)
      _ => ()
    }
  } else {
    // The pinned turn is over; only an untargeted submit may attach to the
    // turn that is open now.
    let pinned = match self.pinned {
      Some(target) => target
      None => raise InvocationFailed("target-pin tool lost its pin")
    }
    self.stale_rejected = control.enqueue_follow_up(
        control_text_message("too late"),
        target=Some(pinned),
      )
      is RejectedStale(_)
    match control.enqueue_follow_up(control_text_message("follow me too")) {
      Accepted(command_id~) => self.accepted_ids.push(command_id)
      _ => ()
    }
  }
  Success(content="echoed", structured=None)
}

///|
/// Public target regression: a target captured on an earlier turn of the same
/// session is stale once that turn rolled over, while the untargeted submit
/// attaches to the turn that is open now.
async test "agent control/follow-up pinned to an older turn is rejected stale" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("turn one")),
    Respond(@test_support.tk_tool_call_response("echo", "call_2", Json::null())),
    Respond(@test_support.tk_stop_response("first done")),
    Respond(@test_support.tk_stop_response("third done")),
  ])
  let tools = TargetPinToolProvider([
    @test_support.tk_tool_def("echo", "echo tool"),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  tools.control = Some(agent.control())
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "session_target_stale",
  )
  assert_true(tools.stale_rejected)
  assert_eq(tools.accepted_ids.length(), 2)
  assert_eq(model.call_count(), 5)
  // The stale message never reached any model request; the untargeted one
  // opened the next turn after the turn that owned the pin.
  assert_eq(request_user_texts(model.received_messages[2]), [
    "hello", "follow me",
  ])
  assert_eq(request_user_texts(model.received_messages[3]), [
    "hello", "follow me",
  ])
  assert_eq(request_user_texts(model.received_messages[4]), [
    "hello", "follow me", "follow me too",
  ])
  for messages in model.received_messages {
    assert_false(request_user_texts(messages).contains("too late"))
  }
  guard result.message is AssistantMessage(content=[Text(last)], ..) else {
    fail("expected the final follow-up turn's assistant reply")
  }
  assert_eq(last, "third done")
}

///|
/// Cross-session cancellation: a follow-up queued while a tool ran survives
/// only as a public `MessageUndelivered` when the operation is cancelled, and
/// the settled inbox rejects every late submission afterwards.
async test "agent control/cancelled operation reports its queued follow-up undelivered" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("unused")),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["queued work"],
    abort_after=true,
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
  let outcome : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(
      @test_support.tk_user_msg("hello"),
      "session_followup_cancel",
    ),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(Cancelled(_)) else {
    fail("expected the aborted run to settle cancelled, got \{repr(outcome)}")
  }
  assert_eq(tools.accepted_ids.length(), 1)
  // The queued follow-up is never converted into a turn of this or a later
  // operation; the host resends it instead.
  assert_eq(agent.control().pending_follow_ups(), 0)
  let undelivered : Array[String] = []
  for event in observer.events() {
    guard event is MessageUndelivered(command_id~, delivery~, reason~) else {
      continue
    }
    assert_true(delivery is Turn)
    assert_true(reason.contains("operation ended"))
    undelivered.push(command_id)
  }
  assert_eq(undelivered, tools.accepted_ids)
  assert_true(
    agent.control().enqueue_follow_up(control_text_message("late"))
    is RejectedStale(_),
  )
  assert_true(agent.control().current_message_target() is None)
}
