///|
priv struct TaskCapture {
  mut tasks : @port.Tasks?
}

///|
fn TaskCapture::new() -> TaskCapture {
  { tasks: None, }
}

///|
impl @port.Lifecycle for TaskCapture with fn on_compose(
  self : TaskCapture,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for TaskCapture with fn on_shutdown(_self : TaskCapture) {
  ()
}

///|
/// Model gate used to keep one Agent operation active while its task hook
/// admits overlapping foreground and background work.
priv struct ForegroundAbortModel {
  release : @aqueue.Queue[Int32]
  response : @kernel.ModelCallResult
}

///|
fn ForegroundAbortModel::new() -> ForegroundAbortModel {
  {
    release: Queue(kind=Unbounded),
    response: @test_support.tk_tool_call_response(
      "abort-tool",
      "abort-call",
      Json::null(),
    ),
  }
}

///|
async fn ForegroundAbortModel::release(self : ForegroundAbortModel) -> Unit {
  self.release.put(1)
}

///|
impl @port.ModelPort for ForegroundAbortModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  let gate = self.release.get() catch {
    error => raise ResponseParse(error.to_string())
  }
  ignore(gate)
  self.response
}

///|
impl @port.ModelPort for ForegroundAbortModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise ResponseParse("compact is not used by this test")
}

///|
impl @port.ModelPort for ForegroundAbortModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
priv struct CompactBusyModel {
  mut tasks : @port.Tasks?
  mut first_compact : Bool
  foreground_started : @aqueue.Queue[Int32]
  cleanup_started : @aqueue.Queue[Int32]
  cleanup_release : @aqueue.Queue[Int32]
  foreground_hold : @aqueue.Queue[Int32]
  started : @aqueue.Queue[Int32]
  release : @aqueue.Queue[Int32]
}

///|
fn CompactBusyModel::new() -> CompactBusyModel {
  {
    tasks: None,
    first_compact: true,
    foreground_started: Queue(kind=Unbounded),
    cleanup_started: Queue(kind=Unbounded),
    cleanup_release: Queue(kind=Unbounded),
    foreground_hold: Queue(kind=Unbounded),
    started: Queue(kind=Unbounded),
    release: Queue(kind=Unbounded),
  }
}

///|
fn CompactBusyModel::submit_foreground(
  self : CompactBusyModel,
) -> Unit raise @error.ModelError {
  let tasks = match self.tasks {
    Some(value) => value
    None => raise ResponseParse("compact task capability was not composed")
  }
  ignore(
    match
      tasks.submit({
        session_id: "compact-busy",
        mode: Foreground,
        label: "compact-cleanup",
        timeout_ms: None,
        run: async fn() {
          self.foreground_started.put(1) catch {
            _ => abort("compact foreground start signal failed")
          }
          // Cancellation is a runtime signal since async 0.22: detect it
          // explicitly instead of catching a cancellation error.
          let released : Bool = match
            @async.handle_cancellation(async fn() {
              ignore(self.foreground_hold.get())
            }) {
            Some(_) => true
            None => false
          }
          if released {
            UserMessage(content=[Text("unexpected foreground release")])
          } else {
            ignore(
              @async.protect_from_cancel(async fn() {
                self.cleanup_started.put(1) catch {
                  _ => abort("compact cleanup start signal failed")
                }
                ignore(
                  self.cleanup_release.get() catch {
                    _ => abort("compact cleanup release failed")
                  },
                )
              }) catch {
                _ => ()
              },
            )
            UserMessage(content=[Text("foreground cleanup released")])
          }
        },
      }) {
      Ok(value) => value
      Err(_) => raise ResponseParse("compact foreground task admission failed")
    },
  )
}

///|
impl @port.Lifecycle for CompactBusyModel with fn on_compose(
  self : CompactBusyModel,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for CompactBusyModel with fn on_shutdown(
  _self : CompactBusyModel,
) {
  ()
}

///|
async fn CompactBusyModel::release(self : CompactBusyModel) -> Unit {
  self.release.put(1)
}

///|
impl @port.ModelPort for CompactBusyModel with fn chat(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  @test_support.tk_stop_response("turn must not enter while compact is busy")
}

///|
impl @port.ModelPort for CompactBusyModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  if self.first_compact {
    self.first_compact = false
    self.submit_foreground()
    ignore(
      self.foreground_started.get() catch {
        error => raise ResponseParse(error.to_string())
      },
    )
    self.started.put(1) catch {
      error => raise ResponseParse(error.to_string())
    }
    ignore(
      self.release.get() catch {
        error => raise ResponseParse(error.to_string())
      },
    )
  }
  { compacted_messages: messages.to_owned(), mode: Replace, }
}

///|
impl @port.ModelPort for CompactBusyModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
priv struct ForegroundAbortProbe {
  mut tasks : @port.Tasks?
  mut submitted : Bool
  mut foreground_one : @port.TaskHandle?
  mut foreground_two : @port.TaskHandle?
  mut background : @port.TaskHandle?
  started : @aqueue.Queue[Int32]
  foreground_gate : @aqueue.Queue[Int32]
  background_gate : @aqueue.Queue[Int32]
}

///|
fn ForegroundAbortProbe::new() -> ForegroundAbortProbe {
  {
    tasks: None,
    submitted: false,
    foreground_one: None,
    foreground_two: None,
    background: None,
    started: Queue(kind=Unbounded),
    foreground_gate: Queue(kind=Unbounded),
    background_gate: Queue(kind=Unbounded),
  }
}

///|
fn ForegroundAbortProbe::submit(self : ForegroundAbortProbe) -> Unit {
  let tasks = match self.tasks {
    Some(value) => value
    None => abort("task capability was not composed")
  }
  let foreground_one = match
    tasks.submit({
      session_id: "abort-session",
      mode: Foreground,
      label: "foreground-one",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.foreground_gate.get())
        UserMessage(content=[Text("foreground-one")])
      },
    }) {
    Ok(handle) => handle
    Err(_) => abort("first foreground task admission failed")
  }
  let foreground_two = match
    tasks.submit({
      session_id: "abort-session",
      mode: Foreground,
      label: "foreground-two",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.foreground_gate.get())
        UserMessage(content=[Text("foreground-two")])
      },
    }) {
    Ok(handle) => handle
    Err(_) => abort("second foreground task admission failed")
  }
  let background = match
    tasks.submit({
      session_id: "background-session",
      mode: Background,
      label: "background-survivor",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.background_gate.get())
        UserMessage(content=[Text("background-survivor")])
      },
    }) {
    Ok(handle) => handle
    Err(_) => abort("background task admission failed")
  }
  self.foreground_one = Some(foreground_one)
  self.foreground_two = Some(foreground_two)
  self.background = Some(background)
}

///|
impl @port.Lifecycle for ForegroundAbortProbe with fn on_compose(
  self : ForegroundAbortProbe,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for ForegroundAbortProbe with fn on_shutdown(
  _self : ForegroundAbortProbe,
) {
  ()
}

///|
impl @port.PipelineHook for ForegroundAbortProbe with fn before_model(
  self : ForegroundAbortProbe,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  if !self.submitted {
    self.submitted = true
    self.submit()
  }
  messages
}

///|
fn foreground_abort_tasks(
  probe : ForegroundAbortProbe,
) -> (@port.TaskHandle, @port.TaskHandle, @port.TaskHandle) {
  let first = match probe.foreground_one {
    Some(handle) => handle
    None => abort("first foreground handle was not published")
  }
  let second = match probe.foreground_two {
    Some(handle) => handle
    None => abort("second foreground handle was not published")
  }
  let background = match probe.background {
    Some(handle) => handle
    None => abort("background handle was not published")
  }
  (first, second, background)
}

///|
fn task_test_agent(
  model : &@port.ModelPort,
  store : @test_support.RecordingSessionPort,
  capture : TaskCapture,
) -> Agent raise @error.CompositionError {
  Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
}

///|
fn task_test_spec(session_id : String, label : String) -> TaskSpec {
  {
    session_id,
    mode: Background,
    label,
    timeout_ms: None,
    run: fn() {
      AssistantMessage(
        content=[Text("worker result")],
        tool_calls=[],
        reasoning=None,
        finish_reason=Stop,
      )
    },
  }
}

///|
fn task_test_submit(
  capture : TaskCapture,
  session_id : String,
  label : String,
) -> TaskHandle {
  let tasks = match capture.tasks {
    Some(value) => value
    None => abort("task capability was not composed")
  }
  match tasks.submit(task_test_spec(session_id, label)) {
    Ok(handle) => handle
    Err(_) => abort("task submit failed")
  }
}

///|
fn task_test_has_marker(session : @types.Session, marker : String) -> Bool {
  session.messages
  .iter()
  .any(fn(message) {
    match message {
      UserMessage(content~) =>
        content
        .iter()
        .any(fn(content) { content is Text(text) && text.contains(marker) })
      _ => false
    }
  })
}

///|
async test "managed_tasks/long_horizon_background_outcomes_are_exactly_once" {
  let capture = TaskCapture::new()
  let steps : Array[@test_support.ScriptedModelStep] = []
  for i = 0; i < 32; i = i + 1 {
    steps.push(Respond(@test_support.tk_stop_response("turn-\{i}")))
  }
  let model = @test_support.ScriptedModel(steps)
  let store = @test_support.RecordingSessionPort()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  let markers : Array[String] = []
  agent.run_scoped(async fn(agent) {
    for turn = 0; turn < 32; turn = turn + 1 {
      for worker = 0; worker < 2; worker = worker + 1 {
        let handle = task_test_submit(
          capture,
          "long_horizon",
          "turn-\{turn}-worker-\{worker}",
        )
        markers.push("[posoco-task-outcome id=\{handle.receipt().id}]")
        ignore(handle.wait())
      }
      ignore(
        agent.run_turn(
          @test_support.tk_user_msg("turn-\{turn}"),
          "long_horizon",
        ),
      )
    }
  })

  assert_eq(model.call_count(), 32)
  assert_eq(markers.length(), 64)
  let saved = store.store["long_horizon"]
  for marker in markers {
    let mut count = 0
    for message in saved.messages {
      if task_test_has_marker(
          { messages: [message], metadata: Map::from_array([]), },
          marker,
        ) {
        count = count + 1
      }
    }
    assert_eq(count, 1)
  }
  match saved.metadata.get("posoco.task.applied_ids") {
    Some(Array(ids)) => assert_eq(ids.length(), 64)
    _ => fail("long-horizon session is missing applied task ids")
  }
}

///|
async test "managed_tasks/abort_cancels_overlapping_foreground_and_keeps_background" {
  let model = ForegroundAbortModel::new()
  let probe = ForegroundAbortProbe::new()
  let store = @test_support.RecordingSessionPort()
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("abort-tool", "abort test tool")],
    Map::from_array([
      ("abort-tool", OutcomeOk(@test_support.tk_ok_result("unused"))),
    ]),
  )
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="task-probe",
        hooks=[probe as &@port.PipelineHook],
        lifecycle=[probe as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let turn_result : Ref[Result[@types.TurnResult, Error]?] = Ref(None)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(@test_support.tk_user_msg("abort me"), "abort-session"),
        ) catch {
          error => Err(error)
        }
        turn_result.val = Some(result)
      })
      ignore(probe.started.get())
      ignore(probe.started.get())
      ignore(probe.started.get())
      assert_true(
        agent.control().abort_active(Some("stop")) is @runtime.Accepted(_),
      )
      model.release()
      ignore(turn.wait())
    })
    let (foreground_one, foreground_two, background) = foreground_abort_tasks(
      probe,
    )
    guard foreground_one.wait().status is Cancelled(_) else {
      fail("first foreground task was not cancelled")
    }
    guard foreground_two.wait().status is Cancelled(_) else {
      fail("second foreground task was not cancelled")
    }
    probe.background_gate.put(1)
    guard background.wait().status is Completed(_) else {
      fail("background task did not survive operation abort")
    }
  })
  match turn_result.val {
    Some(Err(@error.AgentError::Cancelled(_))) => ()
    value => fail("abort must cancel the active operation: \{repr(value)}")
  }
}

///|
async test "managed_tasks/rejects_malformed_applied_ids_before_model_call" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("healed")),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("malformed", {
    messages: [],
    metadata: Map::from_array([
      ("posoco.task.applied_ids", Json::string("not-an-array")),
    ]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(
      @test_support.tk_user_msg("must fail before model"),
      "malformed",
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(Runtime(InvocationFailed(detail))) =>
      assert_true(detail.contains("malformed posoco.task.applied_ids"))
    _ =>
      fail("malformed applied-id metadata must fail during session admission")
  }
  assert_eq(model.call_count(), 0)
}

///|
async test "managed_tasks/compact_keeps_busy_guard_through_blocked_operation" {
  let model = CompactBusyModel::new()
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(model),
        lifecycle=[model as &@port.Lifecycle],
        requires=[Tasks],
      ),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let compact_result : Ref[Result[@types.CompactOutcome, Error]?] = Ref(None)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let compact = group.spawn(async fn() {
        let result : Result[@types.CompactOutcome, Error] = Ok(
          agent.compact_session("compact-busy"),
        ) catch {
          error => Err(error)
        }
        compact_result.val = Some(result)
      })
      ignore(model.started.get())
      model.release()
      ignore(model.cleanup_started.get())
      let turn_result : Result[@types.TurnResult, Error] = Ok(
        agent.run_turn(@test_support.tk_user_msg("busy turn"), "compact-busy"),
      ) catch {
        error => Err(error)
      }
      guard turn_result is Err(@error.AgentError::Busy(operation_id~, session~)) &&
        session == "compact-busy" &&
        operation_id.contains("agent_compact_session_") else {
        fail(
          "a turn must be rejected with the structured busy error while compact cleanup is joining, got \{repr(turn_result)}",
        )
      }
      model.cleanup_release.put(1)
      ignore(compact.wait())
    })
    let next = agent.run_turn(
      @test_support.tk_user_msg("after compact"),
      "compact-busy",
    )
    guard next.message is AssistantMessage(content=[Text(text)], ..) else {
      fail("same Agent did not accept a turn after compact cleanup")
    }
    assert_eq(text, "turn must not enter while compact is busy")
    let compact_again = agent.compact_session("compact-busy")
    assert_eq(compact_again.final_session_id, "compact-busy")
  })
  guard compact_result.val is Some(Ok(_)) else {
    fail("blocked compact did not finish after release")
  }
}

///|
async test "managed_tasks/timeout_survives_masked_raise" {
  let capture = TaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("unused")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => abort("task capability was not composed")
    }
    let handle = match
      tasks.submit({
        session_id: "masked-raise",
        mode: Background,
        label: "masked-raise",
        timeout_ms: Some(150),
        run: async fn() {
          match @async.handle_cancellation(async fn() { @async.sleep(60000) }) {
            // Simulate an adapter masking the cancellation as a typed raise;
            // the timeout must still win.
            None => raise @error.AgentError::Runtime(InvocationFailed("masked"))
            Some(_) => ()
          }
          UserMessage(content=[Text("never")])
        },
      }) {
      Ok(value) => value
      Err(_) => abort("task submit failed")
    }
    let outcome = handle.wait()
    guard outcome.status is TimedOut else {
      fail("masked raise degraded the timeout: \{repr(outcome.status)}")
    }
  })
}

///|
async test "managed_tasks/timeout_survives_masked_return" {
  let capture = TaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("unused")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => abort("task capability was not composed")
    }
    let handle = match
      tasks.submit({
        session_id: "masked-return",
        mode: Background,
        label: "masked-return",
        timeout_ms: Some(150),
        run: async fn() {
          match @async.handle_cancellation(async fn() { @async.sleep(60000) }) {
            // Simulate an adapter masking the cancellation and returning a
            // garbage message; the masking guard must still surface Cancelled.
            None => ()
            Some(_) => ()
          }
          UserMessage(content=[Text("garbage-after-cancel")])
        },
      }) {
      Ok(value) => value
      Err(_) => abort("task submit failed")
    }
    let outcome = handle.wait()
    guard outcome.status is TimedOut else {
      fail("masked return degraded the timeout: \{repr(outcome.status)}")
    }
  })
}

///|
async test "managed_tasks/business_error_survives_cancel_guard" {
  let capture = TaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("unused")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => abort("task capability was not composed")
    }
    let handle = match
      tasks.submit({
        session_id: "business-error",
        mode: Background,
        label: "business-error",
        timeout_ms: None,
        run: fn() raise {
          raise @error.AgentError::Runtime(InvocationFailed("boom"))
        },
      }) {
      Ok(value) => value
      Err(_) => abort("task submit failed")
    }
    let outcome = handle.wait()
    let reason = match outcome.status {
      Failed(reason~) => reason
      other => fail("business error must stay Failed: \{repr(other)}")
    }
    assert_true(reason.contains("boom"))
  })
}

///|
/// Independent Agent-facing acceptance coverage for managed task lifetimes,
/// session routing, and terminal result delivery.

///|
priv struct AcceptanceTaskCapture {
  mut tasks : @port.Tasks?
}

///|
suberror AcceptanceScopeBodyFailed {
  AcceptanceScopeBodyFailed
}

///|
priv struct AcceptanceShutdownProbe {
  mut shutdowns : Int32
}

///|
fn AcceptanceShutdownProbe::new() -> AcceptanceShutdownProbe {
  { shutdowns: 0, }
}

///|
impl @port.Lifecycle for AcceptanceShutdownProbe with fn on_compose(
  _self : AcceptanceShutdownProbe,
  _view : @port.CompositionView,
) {
  ()
}

///|
impl @port.Lifecycle for AcceptanceShutdownProbe with fn on_shutdown(
  self : AcceptanceShutdownProbe,
) {
  self.shutdowns = self.shutdowns + 1
}

///|
fn AcceptanceTaskCapture::new() -> AcceptanceTaskCapture {
  { tasks: None, }
}

///|
impl @port.Lifecycle for AcceptanceTaskCapture with fn on_compose(
  self : AcceptanceTaskCapture,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for AcceptanceTaskCapture with fn on_shutdown(
  _self : AcceptanceTaskCapture,
) {
  ()
}

///|
priv struct AcceptanceTurnGate {
  entered : @aqueue.Queue[Int32]
  release : @aqueue.Queue[Int32]
}

///|
/// Captures the composed task capability and probes foreground admission
/// while a real turn owns a different operation.
priv struct AcceptanceForegroundAdmissionProbe {
  mut tasks : @port.Tasks?
  mut submitted : Bool
  mut mismatch : Result[@port.TaskHandle, @port.TaskSubmitError]?
}

///|
fn AcceptanceForegroundAdmissionProbe::new() -> AcceptanceForegroundAdmissionProbe {
  { tasks: None, submitted: false, mismatch: None, }
}

///|
impl @port.Lifecycle for AcceptanceForegroundAdmissionProbe with fn on_compose(
  self : AcceptanceForegroundAdmissionProbe,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for AcceptanceForegroundAdmissionProbe with fn on_shutdown(
  _self : AcceptanceForegroundAdmissionProbe,
) {
  ()
}

///|
impl @port.PipelineHook for AcceptanceForegroundAdmissionProbe with fn before_model(
  self : AcceptanceForegroundAdmissionProbe,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  if !self.submitted {
    self.submitted = true
    let tasks = match self.tasks {
      Some(value) => value
      None => abort("foreground admission task capability was not composed")
    }
    self.mismatch = Some(
      tasks.submit({
        session_id: "foreground-wrong-session",
        mode: Foreground,
        label: "foreground-session-mismatch",
        timeout_ms: None,
        run: fn() { UserMessage(content=[Text("must not be admitted")]) },
      }),
    )
  }
  messages
}

///|
fn acceptance_content_text(content : @kernel.Content) -> String {
  match content {
    Text(text) => text
    Image(media_type~, ..) => "[image=\{media_type}]"
  }
}

///|
fn acceptance_message_text(message : @kernel.Message) -> String {
  match message {
    SystemMessage(content~) => content.map(acceptance_content_text).join("")
    UserMessage(content~) => content.map(acceptance_content_text).join("")
    AssistantMessage(content~, ..) =>
      content.map(acceptance_content_text).join("")
    ToolMessage(outcome~, ..) => outcome.summary()
  }
}

///|
fn acceptance_text_count(
  messages : Array[@kernel.Message],
  needle : String,
) -> Int32 {
  let mut count = 0
  for message in messages {
    if acceptance_message_text(message).contains(needle) {
      count = count + 1
    }
  }
  count
}

///|
fn acceptance_user_message_contains(
  messages : Array[@kernel.Message],
  needle : String,
) -> Bool {
  for message in messages {
    match message {
      UserMessage(..) if acceptance_message_text(message).contains(needle) =>
        return true
      _ => ()
    }
  }
  false
}

///|
impl @port.PipelineHook for AcceptanceTurnGate with fn before_model(
  self : AcceptanceTurnGate,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  let mut is_b_turn = false
  for message in messages {
    if acceptance_message_text(message).contains("B turn") {
      is_b_turn = true
    }
  }
  if is_b_turn {
    self.entered.put(1) catch {
      _ => raise Aborted(reason="acceptance gate enter failed")
    }
    ignore(
      self.release.get() catch {
        _ => raise Aborted(reason="acceptance gate release failed")
      },
    )
  }
  messages
}

///|
fn acceptance_tasks(capture : AcceptanceTaskCapture) -> @port.Tasks {
  match capture.tasks {
    Some(tasks) => tasks
    None => abort("managed task capability was not composed")
  }
}

///|
fn acceptance_background_task(
  tasks : @port.Tasks,
  session_id : String,
  label : String,
  run : async () -> @kernel.Message,
) -> @port.TaskHandle {
  match
    tasks.submit({ session_id, mode: Background, label, timeout_ms: None, run, }) {
    Ok(handle) => handle
    Err(_) => abort("background task admission failed")
  }
}

///|
fn acceptance_task_handle(
  tasks : @port.Tasks,
  session_id : String,
  mode : @port.TaskMode,
  label : String,
  timeout_ms : Int32?,
  run : async () -> @kernel.Message,
) -> @port.TaskHandle {
  match tasks.submit({ session_id, mode, label, timeout_ms, run, }) {
    Ok(handle) => handle
    Err(_) => abort("task admission failed")
  }
}

///|
fn acceptance_assert_cancelled(outcome : @port.TaskOutcome) -> Unit raise {
  guard outcome.status is Cancelled(_) else {
    fail("scope shutdown must leave a cancelled task terminal")
  }
}

///|
fn acceptance_assert_closed(
  tasks : @port.Tasks,
  session_id : String,
) -> Unit raise {
  let result = tasks.submit({
    session_id,
    mode: Background,
    label: "late-submit",
    timeout_ms: None,
    run: fn() { UserMessage(content=[Text("late")]) },
  })
  assert_true(result is Err(Closed))
}

///|
async test "managed_tasks/background_routes_by_session_and_normalizes_result" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("B complete")),
    Respond(@test_support.tk_stop_response("A complete")),
    Respond(@test_support.tk_stop_response("A follow-up complete")),
  ])
  let store = @test_support.RecordingSessionPort()
  let gate = AcceptanceTurnGate::{
    entered: Queue(kind=Unbounded),
    release: Queue(kind=Unbounded),
  }
  let a_release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], hooks=[gate]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let tasks = acceptance_tasks(capture)
    let handle = acceptance_background_task(
      tasks,
      "session_a",
      "background-a",
      async fn() {
        ignore(a_release.get())
        SystemMessage(content=[Text("background-a-value")])
      },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"

    @async.with_task_group(async fn(group) {
      let b_turn = group.spawn(async fn() {
        agent.run_turn(@test_support.tk_user_msg("B turn"), "session_b")
      })
      ignore(gate.entered.get())

      // The A worker is released only after B has entered its model gate, so
      // completion is observed while B is still the active operation.
      a_release.put(1)
      let outcome = handle.wait()
      match outcome.status {
        Completed(message~) => {
          let returned_system = message is SystemMessage(..)
          assert_true(returned_system)
        }
        _ => fail("background task did not complete")
      }

      gate.release.put(1)
      ignore(b_turn.wait())

      // B must not consume A's inbox. The next A turn receives it as a user
      // message, and the following A turn must not append another copy.
      ignore(agent.run_turn(@test_support.tk_user_msg("A turn"), "session_a"))
      ignore(
        agent.run_turn(@test_support.tk_user_msg("A follow-up"), "session_a"),
      )
    })

    let b_prompt = model.received_messages[0]
    let a_prompt = model.received_messages[1]
    let a_follow_up_prompt = model.received_messages[2]
    assert_eq(acceptance_text_count(b_prompt, marker), 0)
    assert_eq(acceptance_text_count(a_prompt, marker), 1)
    assert_true(
      acceptance_user_message_contains(a_prompt, "background-a-value"),
    )
    assert_eq(acceptance_text_count(a_follow_up_prompt, marker), 1)
  })
}

///|
async test "managed_tasks/background_outcome_survives_failed_save_and_heal" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first attempt")),
    Respond(@test_support.tk_stop_response("healed attempt")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "retry-session",
      "retryable-background",
      fn() { SystemMessage(content=[Text("retained-background-value")]) },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"
    let outcome = handle.wait()
    guard outcome.status is Completed(_) else {
      fail("background task did not complete")
    }

    store.fail_save("retry-session")
    let first : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(
        @test_support.tk_user_msg("first attempt"),
        "retry-session",
      ),
    ) catch {
      error => Err(error)
    }
    match first {
      Err(Session(_)) => ()
      _ => fail("failed session save must surface AgentError::Session")
    }

    store.heal_save("retry-session")
    ignore(
      agent.run_turn(
        @test_support.tk_user_msg("healed attempt"),
        "retry-session",
      ),
    )

    let persisted = (store as &@port.SessionPort).load("retry-session")
    assert_eq(acceptance_text_count(persisted.messages, marker), 1)
    assert_eq(model.received_messages.length(), 1)
    assert_eq(acceptance_text_count(model.received_messages[0], marker), 1)
    assert_eq(
      acceptance_text_count(persisted.messages, "retained-background-value"),
      1,
    )
  })
}

///|
async test "managed_tasks/cancelled_waiter_does_not_cancel_background_and_late_waits_agree" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("unused")),
  ])
  let store = @test_support.RecordingSessionPort()
  let waiter_started : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let late_one : Ref[@port.TaskOutcome?] = Ref(None)
  let late_two : Ref[@port.TaskOutcome?] = Ref(None)
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(_agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "wait-session",
      "waitable-background",
      async fn() {
        ignore(release.get())
        UserMessage(content=[Text("waited-background-value")])
      },
    )
    @async.with_task_group(async fn(group) {
      let waiter = group.spawn(async fn() {
        waiter_started.put(1)
        // The waiter is cancelled mid-wait; the signal bypasses catch, so
        // its cancelled termination is observed from the task handle below.
        ignore(handle.wait())
      })
      ignore(waiter_started.get())
      waiter.cancel()

      // Cancellation belongs to the wait operation. It must leave the
      // Agent-owned background worker alive for a later terminal wait.
      release.put(1)
      let waiter_done : Result[Unit, Error] = Ok(waiter.wait()) catch {
        error => Err(error)
      }
      match waiter_done {
        Err(error) if error is @async.WaitedTaskAlreadyCancelled => ()
        _ => fail("cancelled waiter must terminate with cancellation")
      }
      let first_late = group.spawn(async fn() {
        late_one.val = Some(handle.wait())
      })
      let second_late = group.spawn(async fn() {
        late_two.val = Some(handle.wait())
      })
      ignore(first_late.wait())
      ignore(second_late.wait())
    })
  })
  let first = match late_one.val {
    Some(outcome) => outcome
    None => fail("first late wait did not return")
  }
  let second = match late_two.val {
    Some(outcome) => outcome
    None => fail("second late wait did not return")
  }
  assert_eq(first, second)
  guard first.status is Completed(_) else {
    fail("late waits must observe the background terminal result")
  }
}

///|
async test "managed_tasks/user_marker_does_not_suppress_first_task_outcome" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("collision handled")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "collision-session",
      "collision-check",
      fn() { SystemMessage(content=[Text("actual-collision-value")]) },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"
    // The persisted user text is not a receipt, even though it contains the
    // same marker spelling as the first task id in this fresh Agent.
    store.seed("collision-session", {
      messages: [@test_support.tk_user_msg(marker)],
      metadata: Map::from_array([]),
    })
    guard handle.wait().status is Completed(_) else {
      fail("collision task did not complete")
    }
    ignore(
      agent.run_turn(
        @test_support.tk_user_msg("deliver collision result"),
        "collision-session",
      ),
    )

    let prompt = model.received_messages[0]
    assert_eq(acceptance_text_count(prompt, "actual-collision-value"), 1)
    assert_true(
      acceptance_user_message_contains(prompt, "actual-collision-value"),
    )
  })
}

///|
async test "managed_tasks/nested_scope_rejects_without_closing_outer_scope" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("outer turn completed")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let nested_ran = Ref(false)
    let nested : Result[Unit, Error] = Ok(
      agent.run_scoped(fn(_nested_agent) {
        nested_ran.val = true
        abort("nested scope body must not run")
      }),
    ) catch {
      error => Err(error)
    }
    match nested {
      Err(@error.AgentError::Runtime(InvocationFailed(reason))) =>
        assert_true(reason.contains("already active"))
      _ => fail("nested run_scoped must reject with the active-scope error")
    }
    assert_false(nested_ran.val)

    // The failed nested admission must not close the outer runtime.
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "nested-session",
      "outer-task",
      fn() { UserMessage(content=[Text("outer-task-value")]) },
    )
    guard handle.wait().status is Completed(_) else {
      fail("outer scope must still admit and complete work")
    }
    let turn = agent.run_turn(
      @test_support.tk_user_msg("outer input"),
      "nested-session",
    )
    assert_eq(turn.final_session_id, "nested-session")
  })
}

///|
async test "managed_tasks/scope_error_and_ambient_cancel_reap_background_work" {
  // Body-error exit: the scope error is preserved while shutdown cancels and
  // reaps the blocked worker. The handle remains a stable terminal capability.
  let error_capture = AcceptanceTaskCapture::new()
  let error_model = @test_support.ScriptedModel([])
  let error_store = @test_support.RecordingSessionPort()
  let error_agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(error_model)),
      @test_support.tk_ext(id="io", sessions=[error_store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[error_capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let error_tasks = acceptance_tasks(error_capture)
  let error_started : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let error_worker_gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let error_cleanup : Array[String] = []
  let error_handle : Ref[@port.TaskHandle?] = Ref(None)
  let error_result : Result[Unit, Error] = Ok(
    error_agent.run_scoped(async fn(_agent) {
      let handle = acceptance_background_task(
        error_tasks,
        "scope-error",
        "scope-error-worker",
        async fn() {
          defer error_cleanup.push("cleaned")
          error_started.put(1)
          ignore(error_worker_gate.get())
          UserMessage(content=[Text("unreachable")])
        },
      )
      error_handle.val = Some(handle)
      ignore(error_started.get())
      raise AcceptanceScopeBodyFailed::AcceptanceScopeBodyFailed
    }),
  ) catch {
    error => Err(error)
  }
  match error_result {
    Err(AcceptanceScopeBodyFailed::AcceptanceScopeBodyFailed) => ()
    _ => fail("scope body error must remain the primary result")
  }
  let error_handle = match error_handle.val {
    Some(handle) => handle
    None => fail("body-error scope did not publish its task handle")
  }
  acceptance_assert_cancelled(error_handle.wait())
  assert_eq(error_cleanup.length(), 1)
  assert_eq(error_cleanup[0], "cleaned")
  acceptance_assert_closed(error_tasks, "scope-error")

  // Ambient cancellation exit: cancel the task running run_scoped only after
  // its worker is blocked and its body has reached its own suspension point.
  let cancel_capture = AcceptanceTaskCapture::new()
  let cancel_model = @test_support.ScriptedModel([])
  let cancel_store = @test_support.RecordingSessionPort()
  let cancel_agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(cancel_model)),
      @test_support.tk_ext(id="io", sessions=[cancel_store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[cancel_capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let cancel_tasks = acceptance_tasks(cancel_capture)
  let cancel_worker_started : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let cancel_body_entered : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let cancel_worker_gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let cancel_body_gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let cancel_cleanup : Array[String] = []
  let cancel_handle : Ref[@port.TaskHandle?] = Ref(None)
  @async.with_task_group(async fn(group) {
    let scope_task = group.spawn(async fn() {
      cancel_agent.run_scoped(async fn(_agent) {
        let handle = acceptance_background_task(
          cancel_tasks,
          "scope-cancel",
          "scope-cancel-worker",
          async fn() {
            defer cancel_cleanup.push("cleaned")
            cancel_worker_started.put(1)
            ignore(cancel_worker_gate.get())
            UserMessage(content=[Text("unreachable")])
          },
        )
        cancel_handle.val = Some(handle)
        ignore(cancel_worker_started.get())
        cancel_body_entered.put(1)
        ignore(cancel_body_gate.get())
      })
    })
    ignore(cancel_body_entered.get())
    scope_task.cancel()
    // Ambient cancellation stays a runtime signal that bypasses catch inside
    // the scope body; observability is the scope task's cancelled termination.
    let scope_done : Result[Unit, Error] = Ok(scope_task.wait()) catch {
      error => Err(error)
    }
    match scope_done {
      Err(error) if error is @async.WaitedTaskAlreadyCancelled => ()
      _ => fail("ambient cancellation must remain observable from run_scoped")
    }
  })
  let cancel_handle = match cancel_handle.val {
    Some(handle) => handle
    None => fail("cancelled scope did not publish its task handle")
  }
  acceptance_assert_cancelled(cancel_handle.wait())
  assert_eq(cancel_cleanup.length(), 1)
  assert_eq(cancel_cleanup[0], "cleaned")
  acceptance_assert_closed(cancel_tasks, "scope-cancel")
}

///|
async test "managed_tasks/shutdown_before_start_calls_lifecycle_once" {
  let probe = AcceptanceShutdownProbe::new()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(@test_support.ScriptedModel([])),
      ),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
      @test_support.tk_ext(id="probe", lifecycle=[probe as &@port.Lifecycle]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.shutdown()
  assert_eq(probe.shutdowns, 1)
  agent.shutdown()
  assert_eq(probe.shutdowns, 1)
}

///|
async test "managed_tasks/external_worker_message_mutation_does_not_rewrite_terminal" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(_agent) {
    let external_content : Array[@kernel.Content] = [Text("external-original")]
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "ownership-external",
      "external-content",
      fn() { UserMessage(content=external_content) },
    )
    let first = handle.wait()
    external_content.push(Text("external-mutated"))

    match first.status {
      Completed(message~) =>
        assert_eq(acceptance_message_text(message), "external-original")
      _ => fail("external-content task did not complete")
    }
    let late = handle.wait()
    match late.status {
      Completed(message~) =>
        assert_eq(acceptance_message_text(message), "external-original")
      _ => fail("late wait did not preserve the external-content terminal")
    }
  })
}

///|
async test "managed_tasks/wait_result_mutation_isolated_from_late_wait_and_delivery" {
  let capture = AcceptanceTaskCapture::new()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("turn completed")),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "ownership-delivery",
      "returned-content",
      fn() { UserMessage(content=[Text("terminal-original")]) },
    )
    let first = handle.wait()
    match first.status {
      Completed(message~) =>
        match message {
          UserMessage(content~) => content.push(Text("caller-mutated"))
          _ => fail("returned task terminal was not a user message")
        }
      _ => fail("returned-content task did not complete")
    }

    let second = handle.wait()
    match second.status {
      Completed(message~) =>
        assert_eq(acceptance_message_text(message), "terminal-original")
      _ => fail("late wait did not preserve the returned terminal")
    }
    ignore(
      agent.run_turn(@test_support.tk_user_msg("next"), "ownership-delivery"),
    )

    let prompt = model.received_messages[0]
    assert_eq(acceptance_text_count(prompt, "terminal-original"), 1)
    assert_eq(acceptance_text_count(prompt, "caller-mutated"), 0)
    assert_true(acceptance_user_message_contains(prompt, "terminal-original"))
  })
}

///|
async test "managed_tasks/tasks_requires_gate_and_scope_admission" {
  let hidden = AcceptanceTaskCapture::new()
  let declared = AcceptanceTaskCapture::new()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(@test_support.ScriptedModel([])),
      ),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
      @test_support.tk_ext(id="hidden", lifecycle=[hidden as &@port.Lifecycle]),
      @test_support.tk_ext(
        id="declared",
        lifecycle=[declared as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  assert_true(hidden.tasks is None)
  let tasks = acceptance_tasks(declared)
  let before_scope = tasks.submit({
    session_id: "before-scope",
    mode: Background,
    label: "before-scope",
    timeout_ms: None,
    run: fn() { UserMessage(content=[Text("must not start before scope")]) },
  })
  assert_true(before_scope is Err(Unavailable))
  agent.shutdown()
}

///|
async test "managed_tasks/foreground_requires_operation_and_matching_session" {
  let probe = AcceptanceForegroundAdmissionProbe::new()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            Respond(@test_support.tk_stop_response("foreground admission turn")),
          ]),
        ),
      ),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
      @test_support.tk_ext(
        id="foreground-probe",
        hooks=[probe as &@port.PipelineHook],
        lifecycle=[probe as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let tasks = match probe.tasks {
      Some(value) => value
      None => abort("foreground admission task capability was not composed")
    }
    let no_operation = tasks.submit({
      session_id: "foreground-session",
      mode: Foreground,
      label: "foreground-without-operation",
      timeout_ms: None,
      run: fn() {
        UserMessage(content=[Text("must not start without operation")])
      },
    })
    assert_true(no_operation is Err(Unavailable))
    ignore(
      agent.run_turn(
        @test_support.tk_user_msg("foreground admission"),
        "foreground-session",
      ),
    )
  })
  match probe.mismatch {
    Some(Err(InvalidSession(reason~))) =>
      assert_true(reason.contains("does not match"))
    Some(Err(_)) =>
      fail("foreground mismatch returned the wrong admission error")
    Some(Ok(_)) => fail("foreground mismatch was admitted")
    None => fail("foreground hook did not attempt the mismatched admission")
  }
}

///|
async test "managed_tasks/background_failure_timeout_and_immediate_cancel_are_stable" {
  let capture = AcceptanceTaskCapture::new()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(@test_support.ScriptedModel([])),
      ),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(_agent) {
    let tasks = acceptance_tasks(capture)
    let failed = acceptance_task_handle(
      tasks,
      "terminal-failed",
      Background,
      "failed",
      None,
      fn() -> @kernel.Message raise Error {
        raise AcceptanceScopeBodyFailed::AcceptanceScopeBodyFailed
      },
    )
    let timeout_gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
    let timed_out = acceptance_task_handle(
      tasks,
      "terminal-timeout",
      Background,
      "timed-out",
      Some(20),
      async fn() {
        ignore(timeout_gate.get())
        UserMessage(content=[Text("must time out")])
      },
    )
    let cancel_gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
    let cancelled = acceptance_task_handle(
      tasks,
      "terminal-cancelled",
      Background,
      "cancelled-before-wait",
      None,
      async fn() {
        ignore(cancel_gate.get())
        UserMessage(content=[Text("must be cancelled")])
      },
    )
    // Cancel immediately after admission, before any wait can observe start.
    cancelled.cancel()

    let failed_first = failed.wait()
    let failed_late = failed.wait()
    assert_eq(failed_first, failed_late)
    match failed_first.status {
      Failed(reason~) => assert_true(reason != "")
      _ => fail("failed background task did not remain Failed")
    }

    let timeout_first = timed_out.wait()
    let timeout_late = timed_out.wait()
    assert_eq(timeout_first, timeout_late)
    assert_true(timeout_first.status is TimedOut)

    let cancelled_first = cancelled.wait()
    let cancelled_late = cancelled.wait()
    assert_eq(cancelled_first, cancelled_late)
    acceptance_assert_cancelled(cancelled_first)
  })
}
