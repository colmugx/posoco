///|
/// Wakeup seam tests (plan step 3/4): scope gating, (session, tag)
/// coalescing with late-generation updates, the input-snapshot cutoff
/// (ordinary user turns cover; compact and replay resumes do not), the
/// pump's ordinary-turn execution with the envelope, cross-session
/// isolation, failure/cancel terminals, shutdown cleanup, and the
/// background-outcome ready → request → delivery vertical.

///|
/// Capture the composed wakeup/tasks capabilities at on_compose, exactly the
/// way a product extension would.
priv struct WakeupCapture {
  mut wakeup : @port.WakeupPort?
  mut tasks : @port.Tasks?
}

///|
fn WakeupCapture::WakeupCapture() -> WakeupCapture {
  { wakeup: None, tasks: None, }
}

///|
impl @port.Lifecycle for WakeupCapture with fn on_compose(
  self : WakeupCapture,
  view : @port.CompositionView,
) {
  self.wakeup = view.wakeup()
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for WakeupCapture with fn on_shutdown(
  _self : WakeupCapture,
) {
  ()
}

///|
fn wakeup_capture_agent(
  capture : WakeupCapture,
  model : &@port.ModelPort,
  store : RecordingSessionStore,
  observer : SignalObserver,
) -> Agent raise @error.CompositionError {
  Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
      tk_ext(id="waker", lifecycle=[capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
        @port.Capability::Wakeup,
      ]),
    ],
    config=tk_config(),
  )
}

///|
fn wakeup_capture_port(capture : WakeupCapture) -> @port.WakeupPort raise {
  match capture.wakeup {
    Some(port) => port
    None => fail("wakeup capability was not composed")
  }
}

///|
/// All user-visible text the given model call received, for envelope and
/// outcome-injection assertions.
fn wakeup_call_text(model : ScriptedModel, call : Int) -> String raise {
  let received = model.received_messages
  if call < 1 || call > received.length() {
    fail("model call \{call} was never recorded")
  }
  let buf = StringBuilder()
  for message in received[call - 1] {
    match message {
      UserMessage(content~) =>
        for item in content {
          match item {
            Text(text) => {
              buf.write_string(text)
              buf.write_char(' ')
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  buf.to_string()
}

///|
fn wakeup_events_ready(observer : SignalObserver) -> Array[@types.TurnEvent] {
  observer.events.filter(fn(event) {
    match event {
      Custom(source~, label~, ..) =>
        source == "posoco.tasks" && label == "background_outcome_ready"
      _ => false
    }
  })
}

///|
fn custom_data_number(event : @types.TurnEvent, key : String) -> Double? {
  match event {
    Custom(data~, ..) =>
      match data {
        Object(fields) =>
          match fields.get(key) {
            Some(Number(value, ..)) => Some(value)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
async test "wakeup/request is scope-gated and validates session and tag" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    RecordingSessionStore(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  // No live run_scoped: admission is closed.
  guard port.request(session="s", tag="t") is Err(ScopeInactive) else {
    fail("requests outside a scope must read ScopeInactive")
  }
  agent.run_scoped(async fn(_agent) {
    @async.pause()
    guard port.request(session="", tag="t") is Err(InvalidSession(_)) else {
      fail("empty session must be rejected")
    }
    guard port.request(session="s", tag="") is Err(TagInvalid(_)) else {
      fail("empty tag must be rejected")
    }
    let long_tag = String::from_array(Array::make(81, 'x'))
    guard port.request(session="s", tag=long_tag) is Err(TagInvalid(_)) else {
      fail("over-long tag must be rejected")
    }
  })
  // A closed admission never reopens.
  guard port.request(session="s", tag="t") is Err(ScopeInactive) else {
    fail("requests after shutdown must read ScopeInactive")
  }
  assert_eq(model.call_count(), 0)
}

///|
async test "wakeup/pump executes one ordinary turn carrying the envelope" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([Respond(tk_stop_response("ack"))])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    let ticket = match
      port.request(session="w-exec", tag="watch", note="files changed") {
      Ok(value) => value
      Err(error) => fail("request failed: \{repr(error)}")
    }
    assert_eq(ticket.session, "w-exec")
    assert_eq(ticket.tag, "watch")
    let requested = wakeup_events(observer, "wakeup_requested")
    assert_eq(requested.length(), 1)
    fail_unless_custom(requested[0], "ticket_id", ticket.id)
    // The event's observation timestamp carries the ticket's field verbatim.
    match custom_data_number(requested[0], "ticket_enqueued_at") {
      Some(value) => assert_true(value == ticket.enqueued_at.to_double())
      None => fail("requested event missing ticket_enqueued_at")
    }
    ignore(observer.wait("posoco.wakeup|wakeup_requested"))
    ignore(observer.wait("posoco.wakeup|wakeup_completed"))
  })
  // The wakeup ran as an ordinary turn: same boundaries, real transcript.
  assert_eq(model.call_count(), 1)
  assert_true(
    wakeup_call_text(model, 1).contains(
      "[posoco-wakeup tag=watch] files changed",
    ),
  )
  guard store.store.get("w-exec") is Some(_) else {
    fail("the wakeup turn must be persisted like a host turn")
  }
  // Operation projection: the wakeup origin with its own operation id.
  let started = operation_events(observer, "operation_started")
  let settled = operation_events(observer, "operation_settled")
  assert_eq(started.length(), 1)
  assert_eq(settled.length(), 1)
  fail_unless_custom(started[0], "origin", "wakeup")
  fail_unless_custom(settled[0], "origin", "wakeup")
  fail_unless_custom(settled[0], "outcome", "completed")
  let operation_id = match custom_data_text(started[0], "operation_id") {
    Some(value) => value
    None => fail("started event missing operation_id")
  }
  assert_true(operation_id.has_prefix("agent_wakeup_"))
  // The executing event carried the display envelope and the operation id.
  let executing = wakeup_events(observer, "wakeup_executing")
  assert_eq(executing.length(), 1)
  fail_unless_custom(executing[0], "operation_id", operation_id)
  match custom_data_text(executing[0], "envelope") {
    Some(envelope) =>
      assert_true(envelope.contains("[posoco-wakeup tag=watch]"))
    None => fail("executing event missing the display envelope")
  }
}

///|
async test "wakeup/same tag coalesces, user turn covers, late request survives" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([
    Respond(tk_stop_response("user turn")),
    Respond(tk_stop_response("wakeup turn")),
  ])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    let first = match port.request(session="w-co", tag="w") {
      Ok(value) => value
      Err(error) => fail("request failed: \{repr(error)}")
    }
    let again = match port.request(session="w-co", tag="w") {
      Ok(value) => value
      Err(error) => fail("re-request failed: \{repr(error)}")
    }
    // Same pending key: same ticket, requested fired once, demand refreshed.
    assert_eq(again.id, first.id)
    assert_eq(wakeup_events(observer, "wakeup_requested").length(), 1)
    // A user turn's input snapshot covers the pending demand: zero extra
    // turns, the ticket terminates satisfied.
    ignore(agent.run_turn(tk_user_msg("hello"), "w-co"))
    ignore(observer.wait("posoco.wakeup|wakeup_satisfied|w-co|w"))
    assert_eq(model.call_count(), 1)
    assert_eq(wakeup_events(observer, "wakeup_executing").length(), 0)
    // The late same-tag request lands after that snapshot: new ticket, and
    // the pump runs exactly one more ordinary turn for it.
    let late = match port.request(session="w-co", tag="w", note="late") {
      Ok(value) => value
      Err(error) => fail("late request failed: \{repr(error)}")
    }
    assert_true(late.id != first.id)
    ignore(observer.wait("posoco.wakeup|wakeup_completed|w-co|w"))
  })
  assert_eq(model.call_count(), 2)
  assert_true(wakeup_call_text(model, 2).contains("[posoco-wakeup tag=w] late"))
}

///|
async test "wakeup/compact and replay-resume never cover pending demand" {
  let capture = WakeupCapture::WakeupCapture()
  // Chat steps in call order: wc wakeup, resume replay, wr wakeup.
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: Replace,
    }),
    Respond(tk_stop_response("woken-c")),
    Respond(tk_stop_response("resumed")),
    Respond(tk_stop_response("woken-r")),
  ])
  let store = RecordingSessionStore()
  store.seed("wc", { messages: [], metadata: Map::from_array([]), })
  store.seed("wr", {
    messages: [tk_user_msg("persisted")],
    metadata: Map::from_array([]),
  })
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    // Sync admission order: the ticket is requested, then the compact admits
    // before the pump can pop (no await in between).
    let _ = port.request(session="wc", tag="c")
    ignore(agent.compact_session("wc"))
    assert_eq(wakeup_events(observer, "wakeup_satisfied").length(), 0)
    assert_eq(model.call_count(), 0)
    ignore(observer.wait("posoco.wakeup|wakeup_completed|wc|c"))
    // A resume that replays the persisted trailing user message injects no
    // new information, so it never covers the demand either.
    let _ = port.request(session="wr", tag="r")
    ignore(agent.resume_turn("wr"))
    assert_eq(wakeup_events(observer, "wakeup_satisfied").length(), 0)
    ignore(observer.wait("posoco.wakeup|wakeup_completed|wr|r"))
  })
  assert_eq(model.call_count(), 3)
  assert_true(wakeup_call_text(model, 2).contains("persisted"))
  assert_true(wakeup_call_text(model, 3).contains("[posoco-wakeup tag=r]"))
}

///|
async test "wakeup/background outcome rides the wakeup turn with applied ids" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([Respond(tk_stop_response("ack"))])
  let store = RecordingSessionStore()
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => fail("task capability was not composed")
    }
    let handle = match
      tasks.submit({
        session_id: "wt",
        mode: @port.TaskMode::Background,
        label: "child",
        timeout_ms: None,
        run: fn() { tk_user_msg("child result") },
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    ignore(observer.wait("posoco.tasks|background_outcome_ready|wt|"))
    // Core-owned ready projection: receipt identity, attribution, authority
    // status — after the inbox write, never a result body.
    let ready = wakeup_events_ready(observer)
    assert_eq(ready.length(), 1)
    let task_id = match custom_data_text(ready[0], "task_id") {
      Some(value) => value
      None => fail("ready event missing task_id")
    }
    assert_true(task_id.has_prefix("agent_task_"))
    fail_unless_custom(ready[0], "session", "wt")
    fail_unless_custom(ready[0], "extension_id", "waker")
    fail_unless_custom(ready[0], "label", "child")
    fail_unless_custom(ready[0], "status", "completed")
    let _ = handle.wait()
    // The extension decides to request; core never auto-requests.
    let _ = port.request(session="wt", tag="child_done")
    ignore(observer.wait("posoco.wakeup|wakeup_completed|wt|child_done"))
  })
  assert_eq(model.call_count(), 1)
  let delivered = wakeup_call_text(model, 1)
  let task_id = match
    custom_data_text(wakeup_events_ready(observer)[0], "task_id") {
    Some(value) => value
    None => fail("ready event missing task_id")
  }
  assert_true(delivered.contains("[posoco-task-outcome id=\{task_id}]"))
  assert_true(delivered.contains("child result"))
  assert_true(delivered.contains("[posoco-wakeup tag=child_done]"))
  // The delivered outcome is committed through the applied-ids metadata.
  let mut applied = false
  for pair in store.save_snapshots() {
    let (_, metadata) = pair
    match metadata.get("posoco.task.applied_ids") {
      Some(Array(values)) =>
        for value in values {
          match value {
            String(id) => if id == task_id { applied = true }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(applied)
}

///|
async test "wakeup/save failure fails the ticket and the agent stays usable" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([Respond(tk_stop_response("after heal"))])
  let store = RecordingSessionStore()
  store.fail_save("wf")
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    let _ = port.request(session="wf", tag="t")
    ignore(observer.wait("posoco.wakeup|wakeup_failed|wf|t"))
    assert_eq(wakeup_events(observer, "wakeup_completed").length(), 0)
    // No core auto-retry: the failed terminal is the only wakeup terminal.
    assert_eq(wakeup_events(observer, "wakeup_executing").length(), 1)
    store.heal_save("wf")
    let turn = agent.run_turn(tk_user_msg("direct"), "wf")
    guard turn.message
      is @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text("after heal")],
        ..
      ) else {
      fail("the Agent must stay usable after a failed wakeup turn")
    }
  })
}

///|
async test "wakeup/model failure fails the ticket without retry" {
  let capture = WakeupCapture::WakeupCapture()
  let model = ScriptedModel([Fail(@error.ModelError::Transport("down"))])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    RecordingSessionStore(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(_agent) {
    let _ = port.request(session="wm", tag="t")
    ignore(observer.wait("posoco.wakeup|wakeup_failed|wm|t"))
    assert_eq(model.call_count(), 1)
    assert_eq(wakeup_events(observer, "wakeup_completed").length(), 0)
    let settled = operation_events(observer, "operation_settled")
    assert_eq(settled.length(), 1)
    fail_unless_custom(settled[0], "outcome", "failed")
  })
}

///|
async test "wakeup/abort during executing cancels the ticket without wedging" {
  let capture = WakeupCapture::WakeupCapture()
  let model = GatedModel::GatedModel(responses=["late"])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    RecordingSessionStore(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(agent) {
    let _ = port.request(session="ws", tag="t")
    ignore(observer.wait("posoco.wakeup|wakeup_executing|ws|t"))
    assert_true(
      agent.control().abort_active(Some("stop")) is @runtime.Accepted(_),
    )
    ignore(observer.wait("posoco.wakeup|wakeup_cancelled|ws|t"))
    // Cancellation ended the operation, not the session.
    model.gate.put(1)
    let next = agent.run_turn(tk_user_msg("next"), "ws")
    guard next.message
      is @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text("late")],
        ..
      ) else {
      fail("the same session must accept a turn after the cancelled wakeup")
    }
  })
}

///|
async test "wakeup/hard-cancelled host turn releases the guard to the pump" {
  let capture = WakeupCapture::WakeupCapture()
  let model = GatedModel::GatedModel(responses=["after cancel"])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    RecordingSessionStore(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let host = group.spawn(async fn() {
        let r : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(tk_user_msg("long"), "wh"),
        ) catch {
          e => Err(e)
        }
        r
      })
      ignore(model.entered.get())
      // Raw cancellation: the unwind release must settle the operation
      // cancelled and free the guard for the pump.
      host.cancel()
      ignore(observer.wait("posoco.operation|operation_settled|wh|"))
      let settled = operation_events(observer, "operation_settled")
      assert_eq(settled.length(), 1)
      fail_unless_custom(settled[0], "outcome", "cancelled")
      let _ = port.request(session="wh", tag="t")
      model.gate.put(1)
      ignore(observer.wait("posoco.wakeup|wakeup_completed|wh|t"))
    })
  })
  assert_eq(model.call_count(), 2)
}

///|
async test "wakeup/shutdown drops pending tickets and closes admission" {
  let capture = WakeupCapture::WakeupCapture()
  let model = GatedModel::GatedModel(responses=["only"])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    RecordingSessionStore(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let _ = port.request(session="wsh", tag="first")
      ignore(observer.wait("posoco.wakeup|wakeup_executing|wsh|first"))
      // Pending work queued behind the executing ticket.
      let _ = port.request(session="wsh", tag="second")
      let _ = port.request(session="wsh", tag="third")
      let shutdowner = group.spawn(async fn() {
        let r : Result[Unit, Error] = Ok(agent.shutdown()) catch { e => Err(e) }
        r
      })
      // Pending scheduling requests die with the scope; the executing ticket
      // finishes its ordinary turn lifecycle.
      ignore(observer.wait("posoco.wakeup|wakeup_dropped|wsh|second"))
      ignore(observer.wait("posoco.wakeup|wakeup_dropped|wsh|third"))
      guard port.request(session="wsh", tag="late") is Err(ScopeInactive) else {
        fail("admission must stay closed after shutdown begins")
      }
      model.gate.put(1)
      ignore(observer.wait("posoco.wakeup|wakeup_completed|wsh|first"))
      guard shutdowner.wait() is Ok(_) else { fail("shutdown raised") }
    })
  })
  // run_scoped returned: the pump exited and dropped nothing twice.
  assert_eq(wakeup_events(observer, "wakeup_dropped").length(), 2)
}

///|
async test "tasks/ready notification covers all four terminals without payloads" {
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    ScriptedModel([]),
    RecordingSessionStore(),
    observer,
  )
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => fail("task capability was not composed")
    }
    let park_forever : async () -> @kernel.Message = async fn() {
      @async.sleep(60000)
      tk_user_msg("never")
    }
    let completed = match
      tasks.submit({
        session_id: "wt-a",
        mode: @port.TaskMode::Background,
        label: "completed",
        timeout_ms: None,
        run: fn() { tk_user_msg("done") },
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    let failed = match
      tasks.submit({
        session_id: "wt-b",
        mode: @port.TaskMode::Background,
        label: "failed",
        timeout_ms: None,
        run: async fn() {
          @async.pause()
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed("worker boom"),
          )
        },
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    let timed_out = match
      tasks.submit({
        session_id: "wt-c",
        mode: @port.TaskMode::Background,
        label: "timed_out",
        timeout_ms: Some(20),
        run: park_forever,
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    let cancelled = match
      tasks.submit({
        session_id: "wt-d",
        mode: @port.TaskMode::Background,
        label: "cancelled",
        timeout_ms: None,
        run: park_forever,
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    cancelled.cancel()
    let outcomes : Array[@port.TaskOutcome] = [
      completed.wait(),
      failed.wait(),
      timed_out.wait(),
      cancelled.wait(),
    ]
    // Every terminal announced exactly one ready event; the payload carries
    // receipt identity, attribution, and authority status only.
    let ready = wakeup_events_ready(observer)
    assert_eq(ready.length(), 4)
    let mut seen_completed = false
    let mut seen_failed = false
    let mut seen_timed_out = false
    let mut seen_cancelled = false
    for event in ready {
      match data_keys(event) {
        Some(keys) => {
          assert_eq(keys.length(), 5)
          assert_true(keys.contains("task_id"))
          assert_true(keys.contains("session"))
          assert_true(keys.contains("extension_id"))
          assert_true(keys.contains("label"))
          assert_true(keys.contains("status"))
        }
        None => fail("ready event data must be an object")
      }
      match custom_data_text(event, "status") {
        Some("completed") => seen_completed = true
        Some("failed") => seen_failed = true
        Some("timed_out") => seen_timed_out = true
        Some("cancelled") => seen_cancelled = true
        Some(other) => fail("unexpected ready status \{other}")
        None => fail("ready event missing status")
      }
    }
    assert_true(seen_completed)
    assert_true(seen_failed)
    assert_true(seen_timed_out)
    assert_true(seen_cancelled)
    for outcome in outcomes {
      match outcome.status {
        @port.TaskStatus::Completed(..) => ()
        @port.TaskStatus::Failed(..) => ()
        @port.TaskStatus::TimedOut => ()
        @port.TaskStatus::Cancelled(..) => ()
      }
    }
  })
}

///|
/// Exact data-key set of a Custom event (payload-shape assertion).
fn data_keys(event : @types.TurnEvent) -> Array[String]? {
  match event {
    Custom(data~, ..) =>
      match data {
        Object(fields) => {
          let keys : Array[String] = []
          for key in fields.keys() {
            keys.push(key)
          }
          Some(keys)
        }
        _ => None
      }
    _ => None
  }
}
