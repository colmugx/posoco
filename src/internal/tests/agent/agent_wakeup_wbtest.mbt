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
  store : &@port.SessionPort,
  observer : SignalObserver,
  tools~ : Array[&@port.ToolProvider] = [],
  max_tool_rounds~ : Int32 = 10,
) -> Agent raise @error.CompositionError {
  Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[store],
        observers=[observer],
        tools~,
      ),
      @test_support.tk_ext(
        id="waker",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks, Wakeup],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(max_tool_rounds)),
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
  let model = @test_support.ScriptedModel([])
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
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
    @test_support.ScriptedModel([]),
    @test_support.RecordingSessionPort(),
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
      @test_support.tk_user_msg("never")
    }
    let completed = match
      tasks.submit({
        session_id: "wt-a",
        mode: Background,
        label: "completed",
        timeout_ms: None,
        run: fn() { @test_support.tk_user_msg("done") },
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    let failed = match
      tasks.submit({
        session_id: "wt-b",
        mode: Background,
        label: "failed",
        timeout_ms: None,
        run: async fn() {
          @async.pause()
          raise @error.AgentError::Runtime(InvocationFailed("worker boom"))
        },
      }) {
      Ok(value) => value
      Err(error) => fail("submit failed: \{repr(error)}")
    }
    let timed_out = match
      tasks.submit({
        session_id: "wt-c",
        mode: Background,
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
        mode: Background,
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
    guard outcomes[0].status is Completed(message~) else {
      fail("expected Completed, got \{outcomes[0].status.to_repr()}")
    }
    assert_eq(message, @test_support.tk_user_msg("done"))
    assert_eq(outcomes[1].receipt.label, "failed")
    guard outcomes[1].status is Failed(reason~) else {
      fail("expected Failed, got \{outcomes[1].status.to_repr()}")
    }
    assert_true(reason.contains("worker boom"))
    assert_eq(outcomes[2].receipt.label, "timed_out")
    assert_eq(outcomes[2].status, TimedOut)
    assert_eq(outcomes[3].receipt.label, "cancelled")
    guard outcomes[3].status is Cancelled(reason~) else {
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
      assert_eq(word, @task.task_outcome_status_label(outcome.status))
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

///|
priv struct WakeupStepGate {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
fn WakeupStepGate::WakeupStepGate() -> WakeupStepGate {
  { entered: Queue(kind=Unbounded), release: Queue(kind=Unbounded), }
}

///|
async fn WakeupStepGate::hold(self : WakeupStepGate) -> Unit {
  self.entered.put(())
  self.release.get()
}

///|
priv struct WakeupStepModel {
  script : @test_support.ScriptedModel
  gate : WakeupStepGate
}

///|
impl @port.ModelPort for WakeupStepModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  let result = self.script.chat(scope, messages, tools, options, stream)
  if self.script.call_count() == 1 {
    self.gate.hold() catch {
      error => raise ResponseParse(error.to_string())
    }
  }
  result
}

///|
impl @port.ModelPort for WakeupStepModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise ResponseParse("unexpected compact")
}

///|
impl @port.ModelPort for WakeupStepModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
priv struct WakeupSerialTool {
  first_wave : WakeupStepGate?
}

///|
impl @port.ToolProvider for WakeupSerialTool with fn list_tools(_self) {
  let serial = @test_support.tk_tool_def("serial", "serial wakeup test tool")
  [{ ..serial, policy: Sequential, }]
}

///|
impl @port.ToolProvider for WakeupSerialTool with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let id = ctx.call_id.to_string()
  if id == "first" && self.first_wave is Some(gate) {
    gate.hold() catch {
      error => raise InvocationFailed(error.to_string())
    }
  }
  @test_support.tk_ok_result("result for \{id}")
}

///|
async test "wakeup/ready task continues a stopped model in the same turn exactly once" {
  let session = "wakeup-step"
  let note = "check the finished worker"
  let payload = "worker completed the report"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let store = @test_support.RecordingSessionPort()
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("initial stop")),
    Respond(@test_support.tk_tool_call_response("serial", "continue", {})),
    Respond(@test_support.tk_stop_response("finished same turn")),
    Respond(@test_support.tk_stop_response("finished later turn")),
  ])
  let gate = WakeupStepGate::WakeupStepGate()
  let model = WakeupStepModel::{ script, gate, }
  let tool = WakeupSerialTool::{ first_wave: None, }
  let agent = wakeup_capture_agent(capture, model, store, observer, tools=[tool])
  let port = wakeup_capture_port(capture)
  let requested : Ref[Result[@port.WakeupTicket, @port.WakeupError]?] = Ref(
    None,
  )
  let model_scopes : Array[@types.EventScope?] = []
  let wakeup_events : Array[@events.EventEnvelope] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      match envelope.event {
        @events.Core(ModelRequestStarted) => model_scopes.push(envelope.scope)
        @events.Core(
          Custom(source="posoco.tasks", label="background_outcome_ready", ..),
        ) => requested.val = Some(port.request(session~, tag="report", note~))
        @events.Core(Custom(source="posoco.wakeup", ..)) =>
          wakeup_events.push(envelope)
        _ => ()
      }
    })
    .unwrap()
  defer subscription.cancel()
  let task_id = Ref("")
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          agent.run_turn(@test_support.tk_user_msg("start report"), session)
        })
        // The next input cannot be frozen before the worker announces readiness.
        gate.entered.get()
        let tasks = capture.tasks.unwrap()
        let handle = tasks
          .submit({
            session_id: session,
            mode: Background,
            label: "report",
            timeout_ms: None,
            run: fn() { @test_support.tk_user_msg(payload) },
          })
          .unwrap()
        let outcome = handle.wait()
        assert_true(outcome.status is Completed(_))
        task_id.val = outcome.receipt.id
        let ready = wakeup_events_ready(observer)
        assert_eq(ready.length(), 1)
        fail_unless_custom(ready[0], "task_id", task_id.val)
        assert_true(requested.val is Some(Ok(_)))
        assert_eq(script.call_count(), 1)
        gate.release.put(())
        let result = turn.wait()
        assert_true(
          result.message
          is AssistantMessage(content=[Text("finished same turn")], ..),
        )
        assert_eq(script.call_count(), 3)
        assert_eq(operation_events(observer, "operation_started").length(), 1)
      })
      ignore(agent.run_turn(@test_support.tk_user_msg("check later"), session))
    })
  })

  assert_eq(script.call_count(), 4)
  let marker = "[posoco-task-outcome id=\{task_id.val}]"
  for text in [note, marker, payload] {
    assert_eq(acceptance_text_count(script.received_messages[0], text), 0)
    // Delivery stays in history, but later steps and turns must not append it again.
    for i in 1..<4 {
      assert_eq(acceptance_text_count(script.received_messages[i], text), 1)
      assert_true(
        acceptance_user_message_contains(script.received_messages[i], text),
      )
    }
    assert_eq(acceptance_text_count(store.store[session].messages, text), 1)
  }
  assert_eq(
    store.store[session].metadata.get("posoco.task.applied_ids"),
    Some(Json::array([Json::string(task_id.val)])),
  )

  guard model_scopes is [Some(first), Some(second), Some(third), Some(later)] else {
    fail("expected four scoped model requests")
  }
  assert_eq(first.session_id.to_string(), session)
  assert_eq(second, first)
  assert_eq(third, first)
  assert_not_eq(later.turn_id, first.turn_id)

  // Seeing only requested/satisfied even after shutdown rules out a second
  // delivery by the idle pump or an unconsumed ticket dropped at shutdown.
  assert_eq(wakeup_events.length(), 2)
  assert_true(
    wakeup_events[0].event is @events.Core(Custom(label="wakeup_requested", ..)),
  )
  let satisfied = wakeup_events[1]
  guard satisfied.event
    is @events.Core(Custom(label="wakeup_satisfied", ..) as event) &&
    requested.val is Some(Ok(ticket)) else {
    fail("expected the in-turn step to satisfy the admitted ticket")
  }
  assert_eq(satisfied.scope, Some(second))
  fail_unless_custom(event, "ticket_id", ticket.id)
  fail_unless_custom(event, "delivery", "step")
  fail_unless_custom(event, "turn_id", second.turn_id.to_string())
  let operation = operation_events(observer, "operation_started")[0]
  assert_eq(
    custom_data_text(event, "operation_id"),
    custom_data_text(operation, "operation_id"),
  )
}

///|
async test "wakeup/waits for every serialized tool wave before continuing the model" {
  let session = "wakeup-waves"
  let note = "refresh after the tools"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let calls : Array[@kernel.ToolCall] = ["first", "second"].map(fn(id) {
    {
      call_id: @kernel.CallId::unchecked(id),
      name: @kernel.ToolName::unchecked("serial"),
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
    Respond(@test_support.tk_stop_response("finished tools")),
  ])
  let gate = WakeupStepGate::WakeupStepGate()
  let tool = WakeupSerialTool::{ first_wave: Some(gate), }
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
    tools=[tool],
  )
  let port = wakeup_capture_port(capture)
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          agent.run_turn(@test_support.tk_user_msg("run both tools"), session)
        })
        gate.entered.get()
        let started = observer.events.filter(fn(event) {
          event is ToolCallStarted(..)
        })
        guard started is [ToolCallStarted(call~)] &&
          call.call_id.to_string() == "first" else {
          fail("only the first serialized wave may be in flight")
        }
        guard port.request(session~, tag="tools", note~) is Ok(_) else {
          fail("wakeup request must be accepted during the first wave")
        }
        assert_eq(model.call_count(), 1)
        gate.release.put(())
        let result = turn.wait()
        assert_true(
          result.message
          is AssistantMessage(content=[Text("finished tools")], ..),
        )
      })
    })
  })

  assert_eq(model.call_count(), 2)
  assert_eq(operation_events(observer, "operation_started").length(), 1)
  let delivered = model.received_messages[1].filter(fn(message) {
    message is ToolMessage(..) ||
    (message is UserMessage(content=[Text(text)]) && text.contains(note))
  })
  guard delivered
    is [
      ToolMessage(
        call_id=first,
        outcome=Success(content="result for first", ..),
        ..
      ),
      ToolMessage(
        call_id=second,
        outcome=Success(content="result for second", ..),
        ..
      ),
      UserMessage(..),
    ] else {
    fail(
      "the next model request must contain both real tool results before the wakeup note",
    )
  }
  assert_eq(first.to_string(), "first")
  assert_eq(second.to_string(), "second")
  let trace : Array[String] = []
  for event in observer.events {
    match event {
      ModelRequestStarted => trace.push("model")
      ToolCallStarted(call~) => trace.push("start \{call.call_id.to_string()}")
      ToolCallSucceeded(call~, ..) =>
        trace.push("finish \{call.call_id.to_string()}")
      ToolCallAbandoned(..) => fail("wakeup must not abandon a tool call")
      _ => ()
    }
  }
  assert_eq(trace, [
    "model", "start first", "finish first", "start second", "finish second", "model",
  ])
}

///|
async test "wakeup/an idle request starts an ordinary wakeup turn" {
  let session = "wakeup-idle"
  let note = "refresh while idle"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("finished idle wakeup")),
  ])
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  let terminal : @aqueue.Queue[@types.TurnEvent] = Queue(kind=Unbounded)
  let subscription = agent
    .subscribe_events(fn(envelope) {
      match envelope.event {
        @events.Core(
          Custom(
            source="posoco.wakeup",
            label="wakeup_completed"
            | "wakeup_failed"
            | "wakeup_cancelled"
            | "wakeup_dropped",
            ..
          ) as event,
        ) => ignore(try! terminal.try_put(event))
        _ => ()
      }
    })
    .unwrap()
  defer subscription.cancel()
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      let ticket = port.request(session~, tag="idle", note~).unwrap()
      let event = terminal.get()
      guard event is Custom(label="wakeup_completed", ..) else {
        fail("expected the idle wakeup turn to complete, got \{event}")
      }
      fail_unless_custom(event, "ticket_id", ticket.id)
    })
  })
  assert_eq(model.call_count(), 1)
  assert_true(
    acceptance_user_message_contains(model.received_messages[0], note),
  )
  let started = operation_events(observer, "operation_started")
  assert_eq(started.length(), 1)
  fail_unless_custom(started[0], "origin", "wakeup")
  fail_unless_custom(started[0], "session", session)
}

///|
async test "wakeup/can continue the same turn with a zero tool round budget" {
  let session = "wakeup-no-tools"
  let capture = WakeupCapture::WakeupCapture()
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first")),
    Respond(@test_support.tk_stop_response("second")),
  ])
  let gate = WakeupStepGate::WakeupStepGate()
  let model = WakeupStepModel::{ script, gate, }
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
    max_tool_rounds=0,
  )
  let port = wakeup_capture_port(capture)
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          agent.run_turn(@test_support.tk_user_msg("start"), session)
        })
        gate.entered.get()
        ignore(
          port
          .request(session~, tag="notice", note="continue without tools")
          .unwrap(),
        )
        gate.release.put(())
        let result = turn.wait()
        assert_true(
          result.message is AssistantMessage(content=[Text("second")], ..),
        )
      })
    })
  })
  assert_eq(operation_events(observer, "operation_started").length(), 1)
  assert_eq(script.call_count(), 2)
}

///|
priv struct WakeupCheckpointStore {
  inner : @test_support.RecordingSessionPort
  mut rejected : @types.Session?
}

///|
impl @port.SessionPort for WakeupCheckpointStore with fn load(self, id) {
  self.inner.load(id)
}

///|
impl @port.SessionPort for WakeupCheckpointStore with fn save(self, id, session) {
  if self.rejected is None &&
    session.metadata.contains("posoco.task.applied_ids") {
    self.rejected = Some(session)
    raise Save("wakeup checkpoint failed")
  }
  self.inner.save(id, session)
}

///|
impl @port.SessionPort for WakeupCheckpointStore with fn checkpoint(
  self,
  id,
  checkpoint,
) {
  self.inner.checkpoint(id, checkpoint)
}

///|
async test "wakeup/failed step checkpoint reports the error and recovers the context once" {
  let session = "wakeup-checkpoint-failure"
  let note = "after worker completion"
  let capture = WakeupCapture::WakeupCapture()
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("stop before failure")),
    Respond(@test_support.tk_stop_response("recovered")),
  ])
  let gate = WakeupStepGate::WakeupStepGate()
  let model = WakeupStepModel::{ script, gate, }
  let observer = SignalObserver::SignalObserver()
  let store = WakeupCheckpointStore::{
    inner: @test_support.RecordingSessionPort(),
    rejected: None,
  }
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let port = wakeup_capture_port(capture)
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          let result : Result[@types.TurnResult, @error.AgentError] = Ok(
            agent.run_turn(@test_support.tk_user_msg("start"), session),
          ) catch {
            error => Err(error)
          }
          result
        })
        gate.entered.get()
        let handle = capture.tasks
          .unwrap()
          .submit({
            session_id: session,
            mode: Background,
            label: "worker",
            timeout_ms: None,
            run: fn() { @test_support.tk_user_msg("finished payload") },
          })
          .unwrap()
        let id = handle.wait().receipt.id
        let marker = "[posoco-task-outcome id=\{id}]"
        let expected_ids = Some(Json::array([Json::string(id)]))
        ignore(port.request(session~, tag="done", note~).unwrap())
        gate.release.put(())
        guard turn.wait() is Err(error) else {
          fail("the checkpoint failure must surface")
        }
        guard error is Runtime(InvocationFailed(detail)) else {
          fail("expected checkpoint subscriber failure, got \{error}")
        }
        assert_true(
          detail.contains("SubscriberFailed(agent_session_checkpoint"),
        )
        assert_eq(script.call_count(), 1)
        let rejected = store.rejected.unwrap()
        assert_eq(acceptance_text_count(rejected.messages, marker), 1)
        assert_eq(acceptance_text_count(rejected.messages, note), 1)
        assert_eq(
          rejected.metadata.get("posoco.task.applied_ids"),
          expected_ids,
        )
        let before = store.inner.store[session]
        assert_eq(acceptance_text_count(before.messages, marker), 0)
        assert_eq(before.metadata.get("posoco.task.applied_ids"), None)

        ignore(agent.run_turn(@test_support.tk_user_msg("recover"), session))
        assert_eq(script.call_count(), 2)
        assert_eq(acceptance_text_count(script.received_messages[1], marker), 1)
        assert_eq(acceptance_text_count(script.received_messages[1], note), 1)
        let after = store.inner.store[session]
        assert_eq(acceptance_text_count(after.messages, marker), 1)
        assert_eq(after.metadata.get("posoco.task.applied_ids"), expected_ids)
      })
    })
  })
}

///|
async test "wakeup/continuous requests cannot hold the current turn open indefinitely" {
  let session = "wakeup-continuation-limit"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let model_steps : Array[@test_support.ScriptedModelStep] = Array::make(
    66,
    Respond(@test_support.tk_stop_response("stop")),
  )
  let model = @test_support.ScriptedModel(model_steps)
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
    max_tool_rounds=0,
  )
  let port = wakeup_capture_port(capture)
  let requests : Array[Result[@port.WakeupTicket, @port.WakeupError]] = []
  let first_scope : Ref[@types.EventScope?] = Ref(None)
  let idle_terminal : @aqueue.Queue[@types.TurnEvent] = Queue(kind=Unbounded)
  let subscription = agent
    .subscribe_events(fn(envelope) {
      match envelope.event {
        @events.Core(ModelRequestStarted) => {
          if first_scope.val is None {
            first_scope.val = envelope.scope
          }
          if envelope.scope == first_scope.val {
            requests.push(
              port.request(
                session~,
                tag="continuous",
                note="step \{requests.length()}",
              ),
            )
          }
        }
        @events.Core(
          Custom(
            source="posoco.wakeup",
            label="wakeup_completed"
            | "wakeup_failed",
            ..
          ) as event,
        ) => ignore(try! idle_terminal.try_put(event))
        _ => ()
      }
    })
    .unwrap()
  defer subscription.cancel()
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      ignore(agent.run_turn(@test_support.tk_user_msg("start"), session))
      assert_eq(requests.length(), 65)
      assert_true(requests.all(fn(request) { request is Ok(_) }))
      let last_ticket = requests.last().unwrap().unwrap()
      let event = idle_terminal.get()
      assert_true(event is Custom(label="wakeup_completed", ..))
      fail_unless_custom(event, "ticket_id", last_ticket.id)
    })
  })
  assert_eq(model.call_count(), 66)
  assert_eq(operation_events(observer, "operation_started").length(), 2)
}

///|
async test "wakeup/an abort leaves an uncommitted ticket for the idle pump" {
  let session = "wakeup-after-abort"
  let note = "process after abort"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("interrupted")),
    Respond(@test_support.tk_stop_response("wakeup completed")),
  ])
  let gate = WakeupStepGate::WakeupStepGate()
  let model = WakeupStepModel::{ script, gate, }
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  let completed : @aqueue.Queue[@types.TurnEvent] = Queue(kind=Unbounded)
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event
        is @events.Core(
          Custom(
            source="posoco.wakeup",
            label="wakeup_completed"
            | "wakeup_failed",
            ..
          ) as event,
        ) {
        ignore(try! completed.try_put(event))
      }
    })
    .unwrap()
  defer subscription.cancel()
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          Ok(agent.run_turn(@test_support.tk_user_msg("start"), session)) catch {
            error => Err(error)
          }
        })
        gate.entered.get()
        let ticket = port.request(session~, tag="after-abort", note~).unwrap()
        assert_true(agent.control().abort_active(None) is Accepted(_))
        assert_true(turn.wait() is Err(Cancelled(_)))
        let event = completed.get()
        assert_true(event is Custom(label="wakeup_completed", ..))
        fail_unless_custom(event, "ticket_id", ticket.id)
      })
    })
  })
  assert_eq(script.call_count(), 2)
  assert_true(
    acceptance_user_message_contains(script.received_messages[1], note),
  )
  assert_false(
    observer.events.any(event => {
      event is Custom(source="posoco.wakeup", label="wakeup_satisfied", ..)
    }),
  )
}
