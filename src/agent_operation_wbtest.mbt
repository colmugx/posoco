///|
/// Operation-lifecycle seam tests (plan step 2): the Agent projects
/// `posoco.operation` started/settled exactly once per admission, brackets
/// the whole follow-up drain, rejects concurrent admission with the
/// structured `AgentError::Busy`, and releases the guard on the normal,
/// failure, and hard-cancel paths.

///|
/// Records every projected core event so tests can assert on the full
/// event list and its custom data.
pub(all) struct SignalObserver {
  events : Array[@types.TurnEvent]
}

///|
pub fn SignalObserver::SignalObserver() -> SignalObserver {
  { events: [], }
}

///|
impl @port.Observer for SignalObserver with fn on_event(
  self,
  event : @types.TurnEvent,
) -> Unit {
  self.events.push(event)
}

///|
fn operation_events(
  observer : SignalObserver,
  wanted : String,
) -> Array[@types.TurnEvent] {
  observer.events.filter(fn(event) {
    match event {
      Custom(source~, label~, ..) =>
        source == "posoco.operation" && label == wanted
      _ => false
    }
  })
}

///|
fn custom_data_text(event : @types.TurnEvent, key : String) -> String? {
  match event {
    Custom(data~, ..) =>
      match data {
        Object(fields) =>
          match fields.get(key) {
            Some(String(value)) => Some(value)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
fn fail_unless_custom(
  event : @types.TurnEvent,
  key : String,
  expected : String,
) -> Unit raise {
  match custom_data_text(event, key) {
    Some(value) => assert_eq(value, expected)
    None => fail("event data missing \{key}")
  }
}

///|
/// Model gate: each chat call parks until a token arrives, so tests hold an
/// admitted operation open and race other callers against the guard.
priv struct GatedModel {
  entered : @aqueue.Queue[Int]
  gate : @aqueue.Queue[Int]
  responses : Array[String]
  mut calls : Int
}

///|
fn GatedModel::GatedModel(responses~ : Array[String]) -> GatedModel {
  {
    entered: Queue(kind=Unbounded),
    gate: Queue(kind=Unbounded),
    responses: responses.copy(),
    calls: 0,
  }
}

///|
impl @port.ModelPort for GatedModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  self.entered.put(1) catch {
    _ => ()
  }
  let _ = self.gate.get() catch { _ => 0 }
  let text = if self.responses.is_empty() {
    "gated"
  } else {
    self.responses[(self.calls - 1) % self.responses.length()]
  }
  tk_stop_response(text)
}

///|
impl @port.ModelPort for GatedModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  {
    compacted_messages: messages.to_owned(),
    mode: @kernel.CompactMode::Replace,
  }
}

///|
impl @port.ModelPort for GatedModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// Enqueue one follow-up while the turn is live, from the observer channel.
priv struct FollowUpInjector {
  control : Ref[AgentControl?]
  injected : Ref[Bool]
}

///|
fn FollowUpInjector::FollowUpInjector(
  control : Ref[AgentControl?],
) -> FollowUpInjector {
  { control, injected: Ref(false), }
}

///|
impl @port.Observer for FollowUpInjector with fn on_event(
  self,
  event : @types.TurnEvent,
) -> Unit {
  if event is ModelResponseReceived(..) && !self.injected.val {
    self.injected.val = true
    match self.control.val {
      Some(handle) => ignore(handle.enqueue_follow_up(tk_user_msg("follow up")))
      None => ()
    }
  }
}

///|
async test "operation/started_settled fire exactly once across the follow-up drain" {
  let model = ScriptedModel([
    Respond(tk_stop_response("one")),
    Respond(tk_stop_response("two")),
    Respond(tk_stop_response("again")),
  ])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let control_ref : Ref[AgentControl?] = Ref(None)
  let injector = FollowUpInjector::FollowUpInjector(control_ref)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[
        observer,
        injector as &@port.Observer,
      ]),
    ],
    config=tk_config(),
  )
  control_ref.val = Some(agent.control())
  let result = agent.run_turn(tk_user_msg("hello"), "op-drain")
  guard result.message
    is @kernel.Message::AssistantMessage(
      content=[@kernel.Content::Text("two")],
      ..
    ) else {
    fail("the drained follow-up should own the final word")
  }
  assert_eq(model.call_count(), 2)
  // One admission covers the initial turn plus the drained follow-up.
  let started = operation_events(observer, "operation_started")
  let settled = operation_events(observer, "operation_settled")
  assert_eq(started.length(), 1)
  assert_eq(settled.length(), 1)
  fail_unless_custom(started[0], "operation_id", "agent_run_turn_1")
  fail_unless_custom(started[0], "session", "op-drain")
  fail_unless_custom(started[0], "origin", "turn")
  fail_unless_custom(settled[0], "operation_id", "agent_run_turn_1")
  fail_unless_custom(settled[0], "outcome", "completed")
  // Each drained follow-up is still a full turn of its own.
  let mut turn_started = 0
  let mut turn_completed = 0
  for event in observer.events {
    match event {
      TurnStarted => turn_started = turn_started + 1
      TurnCompleted => turn_completed = turn_completed + 1
      _ => ()
    }
  }
  assert_eq(turn_started, 2)
  assert_eq(turn_completed, 2)
  // Settled implies the guard is gone: the next admission is immediate.
  let next = agent.run_turn(tk_user_msg("again"), "op-drain")
  guard next.message is @kernel.Message::AssistantMessage(..) else {
    fail("the Agent must admit the next operation after settled")
  }
}

///|
async test "operation/busy names the incumbent and the loser leaves no trace" {
  let model = GatedModel::GatedModel(responses=["held"])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(async fn(group) {
    let holder = group.spawn(async fn() {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(tk_user_msg("hold"), "op-busy"),
      ) catch {
        e => Err(e)
      }
      r
    })
    ignore(model.entered.get())
    let loser : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(tk_user_msg("race"), "op-busy"),
    ) catch {
      e => Err(e)
    }
    guard loser is Err(Busy(operation_id~, session~)) else {
      fail("expected the structured busy error, got \{repr(loser)}")
    }
    assert_eq(session, "op-busy")
    assert_eq(operation_id, "agent_run_turn_1")
    // Exactly one admission: the loser projected nothing.
    assert_eq(operation_events(observer, "operation_started").length(), 1)
    assert_eq(operation_events(observer, "operation_settled").length(), 0)
    model.gate.put(1)
    guard holder.wait() is Ok(_) else { fail("holder turn must complete") }
    assert_eq(operation_events(observer, "operation_settled").length(), 1)
  })
  // The Agent accepts new work immediately after settled.
  model.gate.put(1)
  let next = agent.run_turn(tk_user_msg("after"), "op-busy")
  guard next.message is @kernel.Message::AssistantMessage(..) else {
    fail("post-settled admission failed")
  }
}

///|
async test "operation/compact settles with the compact origin and outcome" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: Replace,
    }),
    Respond(tk_stop_response("unused")),
  ])
  let store = RecordingSessionStore()
  store.seed("op-compact", {
    messages: [tk_user_msg("seeded")],
    metadata: Map::from_array([]),
  })
  let observer = SignalObserver::SignalObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("op-compact")
  assert_eq(outcome.final_session_id, "op-compact")
  let started = operation_events(observer, "operation_started")
  let settled = operation_events(observer, "operation_settled")
  assert_eq(started.length(), 1)
  assert_eq(settled.length(), 1)
  fail_unless_custom(started[0], "origin", "compact")
  fail_unless_custom(started[0], "session", "op-compact")
  let operation_id = match custom_data_text(started[0], "operation_id") {
    Some(value) => value
    None => fail("started event missing operation_id")
  }
  assert_true(operation_id.has_prefix("agent_compact_session_"))
  fail_unless_custom(settled[0], "outcome", "completed")
  // The same session admits an ordinary turn afterwards.
  let turn = agent.run_turn(tk_user_msg("after compact"), "op-compact")
  guard turn.message is @kernel.Message::AssistantMessage(..) else {
    fail("post-compact admission failed")
  }
}

///|
async test "operation/resume carries the resume origin" {
  let model = ScriptedModel([
    Respond(tk_stop_response("resumed")),
    Respond(tk_stop_response("woken")),
  ])
  let store = RecordingSessionStore()
  store.seed("op-resume", {
    messages: [tk_user_msg("persisted")],
    metadata: Map::from_array([]),
  })
  let observer = SignalObserver::SignalObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  ignore(agent.resume_turn("op-resume"))
  let started = operation_events(observer, "operation_started")
  assert_eq(started.length(), 1)
  fail_unless_custom(started[0], "origin", "resume")
  ignore(agent.run_turn(tk_user_msg("next"), "op-resume"))
  assert_eq(operation_events(observer, "operation_settled").length(), 2)
}

///|
async test "operation/model failure settles failed and stays reusable" {
  let model = ScriptedModel([
    Fail(@error.ModelError::Transport("down")),
    Respond(tk_stop_response("recovered")),
  ])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("boom"), "op-fail"),
  ) catch {
    e => Err(e)
  }
  guard first is Err(@error.AgentError::Model(_)) else {
    fail("expected the scripted model failure")
  }
  let settled = operation_events(observer, "operation_settled")
  assert_eq(settled.length(), 1)
  fail_unless_custom(settled[0], "outcome", "failed")
  let second = agent.run_turn(tk_user_msg("retry"), "op-fail")
  guard second.message
    is @kernel.Message::AssistantMessage(
      content=[@kernel.Content::Text("recovered")],
      ..
    ) else {
    fail("the Agent must stay reusable after a failed operation")
  }
}
