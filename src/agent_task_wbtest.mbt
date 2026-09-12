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
  release : @aqueue.Queue[Int]
  response : @kernel.ModelCallResult
}

///|
fn ForegroundAbortModel::new() -> ForegroundAbortModel {
  {
    release: Queue(kind=Unbounded),
    response: tk_tool_call_response("abort-tool", "abort-call", Json::null()),
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
    error => raise @error.ModelError::ResponseParse(error.to_string())
  }
  ignore(gate)
  self.response
}

///|
impl @port.ModelPort for ForegroundAbortModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse("compact is not used by this test")
}

///|
impl @port.ModelPort for ForegroundAbortModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
priv struct CompactBusyModel {
  started : @aqueue.Queue[Int]
  release : @aqueue.Queue[Int]
}

///|
fn CompactBusyModel::new() -> CompactBusyModel {
  { started: Queue(kind=Unbounded), release: Queue(kind=Unbounded), }
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
  tk_stop_response("turn must not enter while compact is busy")
}

///|
impl @port.ModelPort for CompactBusyModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.started.put(1) catch {
    error => raise @error.ModelError::ResponseParse(error.to_string())
  }
  ignore(
    self.release.get() catch {
      error => raise @error.ModelError::ResponseParse(error.to_string())
    },
  )
  {
    compacted_messages: messages.to_owned(),
    mode: @kernel.CompactMode::Replace,
  }
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
  started : @aqueue.Queue[Int]
  foreground_gate : @aqueue.Queue[Int]
  background_gate : @aqueue.Queue[Int]
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
      mode: @port.TaskMode::Foreground,
      label: "foreground-one",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.foreground_gate.get())
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("foreground-one"),
        ])
      },
    }) {
    Ok(handle) => handle
    Err(_) => abort("first foreground task admission failed")
  }
  let foreground_two = match
    tasks.submit({
      session_id: "abort-session",
      mode: @port.TaskMode::Foreground,
      label: "foreground-two",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.foreground_gate.get())
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("foreground-two"),
        ])
      },
    }) {
    Ok(handle) => handle
    Err(_) => abort("second foreground task admission failed")
  }
  let background = match
    tasks.submit({
      session_id: "background-session",
      mode: @port.TaskMode::Background,
      label: "background-survivor",
      timeout_ms: None,
      run: async fn() {
        self.started.put(1)
        ignore(self.background_gate.get())
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("background-survivor"),
        ])
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
async test "managed_tasks/run_scoped_completes_and_waits" {
  let capture = TaskCapture::new()
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
      tk_ext(id="tasks", lifecycle=[capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
      ]),
    ],
    config=tk_config(),
  )
  let observed : Ref[TaskOutcome?] = Ref(None)
  agent.run_scoped(async fn(_agent) {
    let tasks = match capture.tasks {
      Some(value) => value
      None => abort("task capability was not composed")
    }
    let handle = match
      tasks.submit({
        session_id: "session_1",
        mode: @port.TaskMode::Background,
        label: "probe",
        timeout_ms: None,
        run: fn() {
          @kernel.Message::UserMessage(content=[@kernel.Content::Text("done")])
        },
      }) {
      Ok(value) => value
      Err(_) => abort("task submit failed")
    }
    observed.val = Some(handle.wait())
  })
  let outcome = match observed.val {
    Some(value) => value
    None => fail("task did not complete")
  }
  let receipt = outcome.receipt
  guard outcome.status is TaskStatus::Completed(_) else {
    fail("task did not complete")
  }
  assert_eq(receipt.session_id, "session_1")
  assert_eq(receipt.extension_id, "tasks")
  assert_eq(receipt.label, "probe")
}

///|
fn task_test_agent(
  model : &@port.ModelPort,
  store : RecordingSessionStore,
  capture : TaskCapture,
) -> Agent raise @error.CompositionError {
  Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
      tk_ext(id="tasks", lifecycle=[capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
      ]),
    ],
    config=tk_config(),
  )
}

///|
fn task_test_spec(session_id : String, label : String) -> TaskSpec {
  {
    session_id,
    mode: TaskMode::Background,
    label,
    timeout_ms: None,
    run: fn() {
      @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text("worker result")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.FinishReason::Stop,
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
      @kernel.Message::UserMessage(content~) =>
        content
        .iter()
        .any(fn(content) {
          content is @kernel.Content::Text(text) && text.contains(marker)
        })
      _ => false
    }
  })
}

///|
async test "managed_tasks/outcomes_route_to_fixed_session" {
  let capture = TaskCapture::new()
  let model = ScriptedModel([
    Respond(tk_stop_response("B")),
    Respond(tk_stop_response("A")),
  ])
  let store = RecordingSessionStore()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(agent) {
    let a = task_test_submit(capture, "session_a", "a")
    let b = task_test_submit(capture, "session_b", "b")
    let a_marker = "[posoco-task-outcome id=\{a.receipt().id}]"
    let b_marker = "[posoco-task-outcome id=\{b.receipt().id}]"
    ignore(a.wait())
    ignore(b.wait())
    ignore(agent.run_turn(tk_user_msg("b input"), "session_b"))
    let b_session = store.store["session_b"]
    assert_true(task_test_has_marker(b_session, b_marker))
    assert_false(task_test_has_marker(b_session, a_marker))
    ignore(agent.run_turn(tk_user_msg("a input"), "session_a"))
    let a_session = store.store["session_a"]
    assert_true(task_test_has_marker(a_session, a_marker))
  })
}

///|
async test "managed_tasks/save_failure_retains_one_pending_outcome" {
  let capture = TaskCapture::new()
  let model = ScriptedModel([
    Respond(tk_stop_response("first")),
    Respond(tk_stop_response("retry")),
  ])
  let store = RecordingSessionStore()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(agent) {
    let handle = task_test_submit(capture, "session_save", "save")
    let marker = "[posoco-task-outcome id=\{handle.receipt().id}]"
    ignore(handle.wait())
    store.fail_save("session_save")
    let first : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(tk_user_msg("first"), "session_save"),
    ) catch {
      error => Err(error)
    }
    guard first is Err(_) else { fail("first save should fail") }
    store.heal_save("session_save")
    ignore(agent.run_turn(tk_user_msg("retry"), "session_save"))
    let saved = store.store["session_save"]
    let markers = saved.messages
      .iter()
      .filter(fn(message) {
        task_test_has_marker(
          { messages: [message], metadata: Map::from_array([]), },
          marker,
        )
      })
    assert_eq(markers.length(), 1)
  })
}

///|
async test "managed_tasks/abort_cancels_overlapping_foreground_and_keeps_background" {
  let model = ForegroundAbortModel::new()
  let probe = ForegroundAbortProbe::new()
  let store = RecordingSessionStore()
  let tools = RecordingToolProvider(
    [tk_tool_def("abort-tool", "abort test tool")],
    Map::from_array([("abort-tool", OutcomeOk(tk_ok_result("unused")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store]),
      tk_ext(
        id="task-probe",
        hooks=[probe as &@port.PipelineHook],
        lifecycle=[probe as &@port.Lifecycle],
        requires=[@port.Capability::Tasks],
      ),
    ],
    config=tk_config(),
  )
  let turn_result : Ref[Result[@types.TurnResult, Error]?] = Ref(None)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(tk_user_msg("abort me"), "abort-session"),
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
    guard foreground_one.wait().status is @port.TaskStatus::Cancelled(_) else {
      fail("first foreground task was not cancelled")
    }
    guard foreground_two.wait().status is @port.TaskStatus::Cancelled(_) else {
      fail("second foreground task was not cancelled")
    }
    probe.background_gate.put(1)
    guard background.wait().status is @port.TaskStatus::Completed(_) else {
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
  let model = ScriptedModel([Respond(tk_stop_response("healed"))])
  let store = RecordingSessionStore()
  store.seed("malformed", {
    messages: [],
    metadata: Map::from_array([
      ("posoco.task.applied_ids", Json::string("not-an-array")),
    ]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("must fail before model"), "malformed"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      @error.AgentError::Runtime(@error.RuntimeError::InvocationFailed(detail))
    ) => assert_true(detail.contains("malformed posoco.task.applied_ids"))
    _ =>
      fail("malformed applied-id metadata must fail during session admission")
  }
  assert_eq(model.call_count(), 0)
}

///|
async test "managed_tasks/repeated_waits_are_payload_isolated" {
  let capture = TaskCapture::new()
  let model = ScriptedModel([Respond(tk_stop_response("unused"))])
  let store = RecordingSessionStore()
  let agent = task_test_agent(model as &@port.ModelPort, store, capture)
  agent.run_scoped(async fn(_agent) {
    let handle = task_test_submit(capture, "snapshot-session", "snapshot")
    let first = handle.wait()
    let first_message = match first.status {
      @port.TaskStatus::Completed(message~) => message
      _ => fail("snapshot task did not complete")
    }
    match first_message {
      @kernel.Message::AssistantMessage(content~, ..) =>
        content[0] = @kernel.Content::Text("mutated")
      _ => fail("snapshot task returned the wrong message")
    }
    let second = handle.wait()
    let second_message = match second.status {
      @port.TaskStatus::Completed(message~) => message
      _ => fail("second wait did not return the stable task terminal")
    }
    match second_message {
      @kernel.Message::AssistantMessage(
        content=[@kernel.Content::Text(text)],
        ..
      ) => assert_eq(text, "worker result")
      _ => fail("second wait returned the wrong message")
    }
  })
}

///|
async test "managed_tasks/compact_keeps_busy_guard_through_blocked_operation" {
  let model = CompactBusyModel::new()
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let compact_result : Ref[Result[@types.CompactOutcome, Error]?] = Ref(None)
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
    let turn_result : Result[@types.TurnResult, Error] = Ok(
      agent.run_turn(tk_user_msg("busy turn"), "compact-busy"),
    ) catch {
      error => Err(error)
    }
    guard turn_result
      is Err(
        @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(detail)
        )
      ) &&
      detail.contains("agent turn busy") else {
      fail("a turn must be rejected while compact is still running")
    }
    model.release()
    ignore(compact.wait())
  })
  guard compact_result.val is Some(Ok(_)) else {
    fail("blocked compact did not finish after release")
  }
}
