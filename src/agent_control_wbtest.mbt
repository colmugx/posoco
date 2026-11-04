///|
/// Root-package control contract tests. The constructor, the inbox lifecycle
/// seam and the follow-up drain are intentionally private here; hosts only
/// receive the opaque handle from `Agent::control()` and use its public
/// submission/inspection methods.

///|
/// Bind a bare control handle the way an admitted operation would: one inbox
/// operation, one open turn, and the mailbox run binding the abort path reads.
fn bound_agent_control() -> AgentControl {
  let mailbox = @puppetry.ControlMailbox()
  mailbox.bind_run(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  let control = AgentControl(mailbox as &@puppetry.Mailbox)
  control.bind_operation("op_1", "session_1")
  control.bind_turn(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  control
}

///|
fn control_text_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
/// Command ids accepted for control messages, in submission order.
fn accepted_ids(
  outcomes : Array[@runtime.EnqueueOutcome],
) -> Array[String] raise {
  outcomes.map(outcome => {
    match outcome {
      Accepted(command_id~) => command_id
      other => fail("expected an accepted message, got \{repr(other)}")
    }
  })
}

///|
test "agent control/follow_up and abort require an active run" {
  let mailbox = @puppetry.ControlMailbox()
  let control = AgentControl(mailbox as &@puppetry.Mailbox)
  assert_true(control.active_run_id() is None)
  assert_true(control.active_turn_id() is None)
  assert_true(control.current_message_target() is None)
  assert_true(
    control.enqueue_follow_up(control_text_message("later"))
    is @runtime.RejectedStale(_),
  )
  assert_true(
    control.enqueue_steer(control_text_message("now"))
    is @runtime.RejectedStale(_),
  )
  assert_true(control.abort_active(Some("stop")) is @runtime.RejectedStale(_))
}

///|
test "agent control/targets cannot cross Agents with identical run identities" {
  let first = bound_agent_control()
  let second = bound_agent_control()
  let target = first.current_message_target()
  assert_true(target is Some(_))
  assert_true(first.active_run_id() == second.active_run_id())
  assert_true(
    second.enqueue_steer(control_text_message("foreign step"), target~)
    is RejectedStale(_),
  )
  assert_true(
    second.enqueue_follow_up(control_text_message("foreign turn"), target~)
    is RejectedStale(_),
  )
  assert_eq(second.pending_steers(), 0)
  assert_eq(second.pending_follow_ups(), 0)
}

///|
test "agent control/follow_up accepted and selected FIFO" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_follow_up(control_text_message("first")),
    control.enqueue_follow_up(control_text_message("second")),
  ])
  assert_eq(control.pending_follow_ups(), 2)
  // The open turn is the submission target a host can pin.
  assert_true(control.current_message_target() is Some(_))
  match control.select_follow_up() {
    Some(command) => {
      assert_eq(command.command_id.to_string(), ids[0])
      guard command.message is UserMessage(content=[Text(text)]) else {
        fail("expected the first follow-up message")
      }
      assert_eq(text, "first")
    }
    None => fail("expected the first follow-up to be selectable")
  }
  match control.select_follow_up() {
    Some(command) => assert_eq(command.command_id.to_string(), ids[1])
    None => fail("expected the second follow-up to be selectable")
  }
  assert_true(control.select_follow_up() is None)
  assert_eq(control.pending_follow_ups(), 0)
}

///|
test "agent control/follow_up rejects beyond queue depth" {
  let control = bound_agent_control()
  for i in 0..<64 {
    assert_true(
      control.enqueue_follow_up(control_text_message("msg_\{i}"))
      is @runtime.Accepted(_),
    )
  }
  assert_eq(control.pending_follow_ups(), 64)
  assert_true(
    control.enqueue_follow_up(control_text_message("overflow"))
    is @runtime.RejectedQueueFull(depth=64),
  )
}

///|
/// Lifecycle regression replacing the old internal queue-close test: a
/// selected record is retained until its commit confirms it, and an
/// operation's tail returns every leftover — queued or selected — in FIFO
/// order, closing the inbox for the next admission.
test "agent control/settles queued and selected follow-ups at operation end" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_follow_up(control_text_message("first")),
    control.enqueue_follow_up(control_text_message("second")),
  ])
  match control.select_follow_up() {
    Some(command) => assert_eq(command.command_id.to_string(), ids[0])
    None => fail("expected a selectable follow-up")
  }
  // Selection retires it from the waiting queue but keeps the record until
  // its turn's initial commit confirms it.
  assert_eq(control.pending_follow_ups(), 1)
  let leftovers = control.finish_operation()
  assert_eq(leftovers.length(), 2)
  assert_eq(leftovers.map(fn(c) { c.command_id.to_string() }), ids)
  assert_eq(control.pending_follow_ups(), 0)
  assert_eq(control.pending_steers(), 0)
  assert_true(control.current_message_target() is None)
  // The closed inbox rejects late submissions instead of silently adopting
  // the next operation's turn…
  assert_true(
    control.enqueue_follow_up(control_text_message("late"))
    is @runtime.RejectedStale(_),
  )
  // …and a fresh admission starts from an empty inbox.
  control.bind_operation("op_2", "session_1")
  assert_eq(control.pending_follow_ups(), 0)
}

///|
/// Confirmation regression: the initial-command id armed for a follow-up turn
/// projects exactly one public `MessageApplied` — through the Agent's event
/// runtime, scoped to the turn that actually committed the message — and a
/// repeated initial commit is a no-op.
test "agent control/initial confirmation projects Applied once, scoped to the committing turn" {
  let observer = @test_support.RecordingObserver()
  let events = @event_runtime.EventRuntime([observer])
  let control = bound_agent_control()
  control.install_message_events(events)
  let scoped : Array[(String, String)] = []
  let _ = events.subscribe(fn(envelope) {
    guard envelope.event is @events.Core(MessageApplied(command_id~, ..)) else {
      return
    }
    match envelope.scope {
      Some(scope) => scoped.push((command_id, scope.run_id.to_string()))
      None => scoped.push((command_id, ""))
    }
  })
  match control.enqueue_follow_up(control_text_message("follow me")) {
    Accepted(command_id~) =>
      match control.select_follow_up() {
        Some(command) => {
          // Arming binds the committing turn and associates the receipt with
          // its initial boundary in one step.
          control.arm_follow_up(
            command.command_id,
            @kernel.RunId::unchecked("run_2"),
            @kernel.TurnId::unchecked("turn_2"),
          )
          control.inbox.confirm_initial()
          let applied = observer.events()
          assert_eq(applied.length(), 1)
          match applied[0] {
            MessageApplied(
              command_id=applied_id,
              delivery=@types.MessageDeliveryKind::Turn
            ) => assert_eq(applied_id, command_id)
            other => fail("expected MessageApplied(Turn), got \{repr(other)}")
          }
          assert_eq(scoped, [(command_id, "run_2")])
          // The armed id is consumed: committing again projects nothing.
          control.inbox.confirm_initial()
          assert_eq(observer.events().length(), 1)
        }
        None => fail("expected the follow-up to be selectable")
      }
    other => fail("expected an accepted follow-up, got \{repr(other)}")
  }
}

///|
/// Target regression: a `MessageTarget` pins the exact turn the host
/// observed. After the turn rolled over, submitting against the captured
/// target is stale even though a turn is still open.
test "agent control/rejects a stale message target" {
  let control = bound_agent_control()
  let fresh = match control.current_message_target() {
    Some(target) => target
    None => fail("expected an open turn target")
  }
  assert_true(
    control.enqueue_steer(control_text_message("pinned"), target=Some(fresh))
    is @runtime.Accepted(_),
  )
  assert_eq(control.pending_steers(), 1)
  control.bind_turn(
    @kernel.RunId::unchecked("run_2"),
    @kernel.TurnId::unchecked("turn_2"),
  )
  let rolled = control.current_message_target()
  assert_true(
    match rolled {
      Some(target) => target != fresh
      None => false
    },
  )
  assert_true(
    control.enqueue_steer(control_text_message("stale"), target=Some(fresh))
    is @runtime.RejectedStale(_),
  )
  assert_true(
    control.enqueue_steer(control_text_message("current"))
    is @runtime.Accepted(_),
  )
  // The waiting count is scoped to the open turn: the steer pinned to the
  // previous turn stays there, and only its own turn can settle it.
  assert_eq(control.pending_steers(), 1)
  assert_eq(
    control
    .finish_turn(
      @kernel.RunId::unchecked("run_1"),
      @kernel.TurnId::unchecked("turn_1"),
    )
    .length(),
    1,
  )
}

///|
test "agent control/steer requires an active run" {
  let mailbox = @puppetry.ControlMailbox()
  let control = AgentControl(mailbox as &@puppetry.Mailbox)
  assert_true(
    control.enqueue_steer(control_text_message("now"))
    is @runtime.RejectedStale(_),
  )
  assert_eq(control.pending_steers(), 0)
}

///|
/// Step records the turn boundary never confirmed are settled at that turn's
/// exit in FIFO order; the inbox closes for the next turn afterwards.
test "agent control/steer settles at the turn boundary" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_steer(control_text_message("first steer")),
    control.enqueue_steer(control_text_message("second steer")),
  ])
  assert_eq(control.pending_steers(), 2)
  let leftovers = control.finish_turn(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  assert_eq(leftovers.map(fn(c) { c.command_id.to_string() }), ids)
  assert_eq(control.pending_steers(), 0)
  // Another turn's step window never inherits the settled records.
  let other = control.finish_turn(
    @kernel.RunId::unchecked("run_2"),
    @kernel.TurnId::unchecked("turn_2"),
  )
  assert_eq(other.length(), 0)
}

///|
test "agent control/steer rejects beyond queue depth" {
  let control = bound_agent_control()
  for i in 0..<64 {
    assert_true(
      control.enqueue_steer(control_text_message("steer_\{i}"))
      is @runtime.Accepted(_),
    )
  }
  assert_eq(control.pending_steers(), 64)
  assert_true(
    control.enqueue_steer(control_text_message("overflow"))
    is @runtime.RejectedQueueFull(depth=64),
  )
}

///|
test "agent control/abort is idempotent per active run" {
  let control = bound_agent_control()
  assert_true(control.abort_active(Some("stop")) is @runtime.Accepted(_))
  assert_true(control.abort_active(None) is @runtime.AbortAlreadyRequested)
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("turn one"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second done"),
    ),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["first", "second"],
    batch=true,
  )
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("turn one"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_2", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second done"),
    ),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["first", "second"],
  )
  let agent = Agent(
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("turn one"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_2", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("third done"),
    ),
  ])
  let tools = TargetPinToolProvider([
    @test_support.tk_tool_def("echo", "echo tool"),
  ])
  let agent = Agent(
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("unused"),
    ),
  ])
  let tools = FollowUpToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    ["queued work"],
    abort_after=true,
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
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
  guard outcome is Err(@error.AgentError::Cancelled(_)) else {
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
    assert_true(delivery is @types.MessageDeliveryKind::Turn)
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
