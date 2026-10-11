///|
/// Wakeup seam tests (plan step 3/4): scope gating and (session, tag)
/// validation on the wakeup request port, plus the core-owned tasks
/// ready projection across all four terminal statuses.

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
    // Cancellation-aware park: `pause` is a cancellation point, so a
    // timed-out or cancelled task unwinds here instead of holding a
    // long-lived timer (no wall-clock hang if cancellation semantics change).
    let park_forever : async () -> @kernel.Message = async fn() {
      while @async.is_being_cancelled() == false {
        @async.pause()
      }
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
    // Outcomes are asserted in submit order with their concrete terminal
    // status, not just "some terminal status".
    assert_eq(outcomes[0].receipt.label, "completed")
    guard outcomes[0].status is @port.TaskStatus::Completed(message~) else {
      fail("expected Completed, got \{outcomes[0].status.to_repr()}")
    }
    assert_eq(message, tk_user_msg("done"))
    assert_eq(outcomes[1].receipt.label, "failed")
    guard outcomes[1].status is @port.TaskStatus::Failed(reason~) else {
      fail("expected Failed, got \{outcomes[1].status.to_repr()}")
    }
    assert_true(reason.contains("worker boom"))
    assert_eq(outcomes[2].receipt.label, "timed_out")
    assert_eq(outcomes[2].status, @port.TaskStatus::TimedOut)
    assert_eq(outcomes[3].receipt.label, "cancelled")
    guard outcomes[3].status is @port.TaskStatus::Cancelled(reason~) else {
      fail("expected Cancelled, got \{outcomes[3].status.to_repr()}")
    }
    assert_eq(reason, "task cancelled")
    // Event/outcome consistency: the ready event carrying a task's label
    // announces exactly the status word of that task's outcome.
    for outcome in outcomes {
      let label = outcome.receipt.label
      let mut event_status : String? = None
      for event in ready {
        if custom_data_text(event, "label") == Some(label) {
          event_status = custom_data_text(event, "status")
        }
      }
      guard event_status is Some(word) else {
        fail("no ready event status for label \{label}")
      }
      assert_eq(word, task_outcome_status_label(outcome.status))
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
