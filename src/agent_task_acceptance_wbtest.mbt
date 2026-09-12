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
  mut shutdowns : Int
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
  entered : @aqueue.Queue[Int]
  release : @aqueue.Queue[Int]
}

///|
fn acceptance_content_text(content : @kernel.Content) -> String {
  match content {
    @kernel.Content::Text(text) => text
    @kernel.Content::Image(media_type~, ..) => "[image=\{media_type}]"
  }
}

///|
fn acceptance_message_text(message : @kernel.Message) -> String {
  match message {
    @kernel.Message::SystemMessage(content~) =>
      content.map(acceptance_content_text).join("")
    @kernel.Message::UserMessage(content~) =>
      content.map(acceptance_content_text).join("")
    @kernel.Message::AssistantMessage(content~, ..) =>
      content.map(acceptance_content_text).join("")
    @kernel.Message::ToolMessage(outcome~, ..) => outcome.summary()
  }
}

///|
fn acceptance_text_count(
  messages : Array[@kernel.Message],
  needle : String,
) -> Int {
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
      @kernel.Message::UserMessage(..) if acceptance_message_text(message).contains(
          needle,
        ) => return true
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
    tasks.submit({
      session_id,
      mode: @port.TaskMode::Background,
      label,
      timeout_ms: None,
      run,
    }) {
    Ok(handle) => handle
    Err(_) => abort("background task admission failed")
  }
}

///|
fn acceptance_assert_cancelled(outcome : @port.TaskOutcome) -> Unit raise {
  guard outcome.status is @port.TaskStatus::Cancelled(_) else {
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
    mode: @port.TaskMode::Background,
    label: "late-submit",
    timeout_ms: None,
    run: fn() {
      @kernel.Message::UserMessage(content=[@kernel.Content::Text("late")])
    },
  })
  assert_true(result is Err(@port.TaskSubmitError::Closed))
}

///|
async test "managed_tasks/background_routes_by_session_and_normalizes_result" {
  let capture = AcceptanceTaskCapture::new()
  let model = ScriptedModel([
    Respond(tk_stop_response("B complete")),
    Respond(tk_stop_response("A complete")),
    Respond(tk_stop_response("A follow-up complete")),
  ])
  let store = RecordingSessionStore()
  let gate = AcceptanceTurnGate::{
    entered: Queue(kind=Unbounded),
    release: Queue(kind=Unbounded),
  }
  let a_release : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], hooks=[gate]),
      tk_ext(id="tasks", lifecycle=[capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
      ]),
    ],
    config=tk_config(),
  )
  agent.run_scoped(async fn(agent) {
    let tasks = acceptance_tasks(capture)
    let handle = acceptance_background_task(
      tasks,
      "session_a",
      "background-a",
      async fn() {
        ignore(a_release.get())
        @kernel.Message::SystemMessage(content=[
          @kernel.Content::Text("background-a-value"),
        ])
      },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"

    @async.with_task_group(async fn(group) {
      let b_turn = group.spawn(async fn() {
        agent.run_turn(tk_user_msg("B turn"), "session_b")
      })
      ignore(gate.entered.get())

      // The A worker is released only after B has entered its model gate, so
      // completion is observed while B is still the active operation.
      a_release.put(1)
      let outcome = handle.wait()
      match outcome.status {
        @port.TaskStatus::Completed(message~) => {
          let returned_system = message is @kernel.Message::SystemMessage(..)
          assert_true(returned_system)
        }
        _ => fail("background task did not complete")
      }

      gate.release.put(1)
      ignore(b_turn.wait())

      // B must not consume A's inbox. The next A turn receives it as a user
      // message, and the following A turn must not append another copy.
      ignore(agent.run_turn(tk_user_msg("A turn"), "session_a"))
      ignore(agent.run_turn(tk_user_msg("A follow-up"), "session_a"))
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
  let model = ScriptedModel([
    Respond(tk_stop_response("first attempt")),
    Respond(tk_stop_response("healed attempt")),
  ])
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
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "retry-session",
      "retryable-background",
      fn() {
        @kernel.Message::SystemMessage(content=[
          @kernel.Content::Text("retained-background-value"),
        ])
      },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"
    let outcome = handle.wait()
    guard outcome.status is @port.TaskStatus::Completed(_) else {
      fail("background task did not complete")
    }

    store.fail_save("retry-session")
    let first : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(tk_user_msg("first attempt"), "retry-session"),
    ) catch {
      error => Err(error)
    }
    match first {
      Err(@error.AgentError::Session(_)) => ()
      _ => fail("failed session save must surface AgentError::Session")
    }

    store.heal_save("retry-session")
    ignore(agent.run_turn(tk_user_msg("healed attempt"), "retry-session"))

    let persisted = (store as &@port.SessionStore).load("retry-session")
    assert_eq(acceptance_text_count(persisted.messages, marker), 1)
    assert_eq(acceptance_text_count(model.received_messages[0], marker), 1)
    assert_eq(acceptance_text_count(model.received_messages[1], marker), 1)
    assert_eq(
      acceptance_text_count(persisted.messages, "retained-background-value"),
      1,
    )
  })
}

///|
async test "managed_tasks/cancelled_waiter_does_not_cancel_background_and_late_waits_agree" {
  let capture = AcceptanceTaskCapture::new()
  let model = ScriptedModel([Respond(tk_stop_response("unused"))])
  let store = RecordingSessionStore()
  let waiter_started : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let cancelled_wait : Ref[Result[@port.TaskOutcome, Error]?] = Ref(None)
  let late_one : Ref[@port.TaskOutcome?] = Ref(None)
  let late_two : Ref[@port.TaskOutcome?] = Ref(None)
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
  agent.run_scoped(async fn(_agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "wait-session",
      "waitable-background",
      async fn() {
        ignore(release.get())
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("waited-background-value"),
        ])
      },
    )
    @async.with_task_group(async fn(group) {
      let waiter = group.spawn(async fn() {
        waiter_started.put(1)
        let result : Result[@port.TaskOutcome, Error] = Ok(handle.wait()) catch {
          error => Err(error)
        }
        cancelled_wait.val = Some(result)
      })
      ignore(waiter_started.get())
      waiter.cancel()

      // Cancellation belongs to the wait operation. It must leave the
      // Agent-owned background worker alive for a later terminal wait.
      release.put(1)
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
  match cancelled_wait.val {
    Some(Err(error)) if @async.is_cancellation_error(error) => ()
    _ => fail("cancelled waiter must terminate with cancellation")
  }
  let first = match late_one.val {
    Some(outcome) => outcome
    None => fail("first late wait did not return")
  }
  let second = match late_two.val {
    Some(outcome) => outcome
    None => fail("second late wait did not return")
  }
  assert_eq(first, second)
  guard first.status is @port.TaskStatus::Completed(_) else {
    fail("late waits must observe the background terminal result")
  }
}

///|
async test "managed_tasks/user_marker_does_not_suppress_first_task_outcome" {
  let capture = AcceptanceTaskCapture::new()
  let model = ScriptedModel([Respond(tk_stop_response("collision handled"))])
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
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "collision-session",
      "collision-check",
      fn() {
        @kernel.Message::SystemMessage(content=[
          @kernel.Content::Text("actual-collision-value"),
        ])
      },
    )
    let receipt = handle.receipt()
    let marker = "[posoco-task-outcome id=\{receipt.id}]"
    // The persisted user text is not a receipt, even though it contains the
    // same marker spelling as the first task id in this fresh Agent.
    store.seed("collision-session", {
      messages: [tk_user_msg(marker)],
      metadata: Map::from_array([]),
    })
    guard handle.wait().status is @port.TaskStatus::Completed(_) else {
      fail("collision task did not complete")
    }
    ignore(
      agent.run_turn(
        tk_user_msg("deliver collision result"),
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
  let model = ScriptedModel([Respond(tk_stop_response("outer turn completed"))])
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
      Err(
        @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(reason)
        )
      ) => assert_true(reason.contains("already active"))
      _ => fail("nested run_scoped must reject with the active-scope error")
    }
    assert_false(nested_ran.val)

    // The failed nested admission must not close the outer runtime.
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "nested-session",
      "outer-task",
      fn() {
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("outer-task-value"),
        ])
      },
    )
    guard handle.wait().status is @port.TaskStatus::Completed(_) else {
      fail("outer scope must still admit and complete work")
    }
    let turn = agent.run_turn(tk_user_msg("outer input"), "nested-session")
    assert_eq(turn.final_session_id, "nested-session")
  })
}

///|
async test "managed_tasks/scope_error_and_ambient_cancel_reap_background_work" {
  // Body-error exit: the scope error is preserved while shutdown cancels and
  // reaps the blocked worker. The handle remains a stable terminal capability.
  let error_capture = AcceptanceTaskCapture::new()
  let error_model = ScriptedModel([])
  let error_store = RecordingSessionStore()
  let error_agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(error_model)),
      tk_ext(id="io", sessions=[error_store]),
      tk_ext(id="tasks", lifecycle=[error_capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
      ]),
    ],
    config=tk_config(),
  )
  let error_tasks = acceptance_tasks(error_capture)
  let error_started : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let error_worker_gate : @aqueue.Queue[Int] = Queue(kind=Unbounded)
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
          @kernel.Message::UserMessage(content=[
            @kernel.Content::Text("unreachable"),
          ])
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
  let cancel_model = ScriptedModel([])
  let cancel_store = RecordingSessionStore()
  let cancel_agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(cancel_model)),
      tk_ext(id="io", sessions=[cancel_store]),
      tk_ext(id="tasks", lifecycle=[cancel_capture as &@port.Lifecycle], requires=[
        @port.Capability::Tasks,
      ]),
    ],
    config=tk_config(),
  )
  let cancel_tasks = acceptance_tasks(cancel_capture)
  let cancel_worker_started : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let cancel_body_entered : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let cancel_worker_gate : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let cancel_body_gate : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let cancel_cleanup : Array[String] = []
  let cancel_handle : Ref[@port.TaskHandle?] = Ref(None)
  let cancel_result : Ref[Result[Unit, Error]?] = Ref(None)
  @async.with_task_group(async fn(group) {
    let scope_task = group.spawn(async fn() {
      let result : Result[Unit, Error] = Ok(
        cancel_agent.run_scoped(async fn(_agent) {
          let handle = acceptance_background_task(
            cancel_tasks,
            "scope-cancel",
            "scope-cancel-worker",
            async fn() {
              defer cancel_cleanup.push("cleaned")
              cancel_worker_started.put(1)
              ignore(cancel_worker_gate.get())
              @kernel.Message::UserMessage(content=[
                @kernel.Content::Text("unreachable"),
              ])
            },
          )
          cancel_handle.val = Some(handle)
          ignore(cancel_worker_started.get())
          cancel_body_entered.put(1)
          ignore(cancel_body_gate.get())
        }),
      ) catch {
        error => Err(error)
      }
      cancel_result.val = Some(result)
    })
    ignore(cancel_body_entered.get())
    scope_task.cancel()
    ignore(scope_task.wait())
  })
  match cancel_result.val {
    Some(Err(error)) if @async.is_cancellation_error(error) => ()
    _ => fail("ambient cancellation must remain observable from run_scoped")
  }
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
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
      tk_ext(id="probe", lifecycle=[probe as &@port.Lifecycle]),
    ],
    config=tk_config(),
  )
  agent.shutdown()
  assert_eq(probe.shutdowns, 1)
  agent.shutdown()
  assert_eq(probe.shutdowns, 1)
}

///|
async test "managed_tasks/external_worker_message_mutation_does_not_rewrite_terminal" {
  let capture = AcceptanceTaskCapture::new()
  let model = ScriptedModel([])
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
  agent.run_scoped(async fn(_agent) {
    let external_content : Array[@kernel.Content] = [
      @kernel.Content::Text("external-original"),
    ]
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "ownership-external",
      "external-content",
      fn() { @kernel.Message::UserMessage(content=external_content) },
    )
    let first = handle.wait()
    external_content.push(@kernel.Content::Text("external-mutated"))

    match first.status {
      @port.TaskStatus::Completed(message~) =>
        assert_eq(acceptance_message_text(message), "external-original")
      _ => fail("external-content task did not complete")
    }
    let late = handle.wait()
    match late.status {
      @port.TaskStatus::Completed(message~) =>
        assert_eq(acceptance_message_text(message), "external-original")
      _ => fail("late wait did not preserve the external-content terminal")
    }
  })
}

///|
async test "managed_tasks/wait_result_mutation_isolated_from_late_wait_and_delivery" {
  let capture = AcceptanceTaskCapture::new()
  let model = ScriptedModel([Respond(tk_stop_response("turn completed"))])
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
  agent.run_scoped(async fn(agent) {
    let handle = acceptance_background_task(
      acceptance_tasks(capture),
      "ownership-delivery",
      "returned-content",
      fn() {
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("terminal-original"),
        ])
      },
    )
    let first = handle.wait()
    match first.status {
      @port.TaskStatus::Completed(message~) =>
        match message {
          @kernel.Message::UserMessage(content~) =>
            content.push(@kernel.Content::Text("caller-mutated"))
          _ => fail("returned task terminal was not a user message")
        }
      _ => fail("returned-content task did not complete")
    }

    let second = handle.wait()
    match second.status {
      @port.TaskStatus::Completed(message~) =>
        assert_eq(acceptance_message_text(message), "terminal-original")
      _ => fail("late wait did not preserve the returned terminal")
    }
    ignore(agent.run_turn(tk_user_msg("next"), "ownership-delivery"))

    let prompt = model.received_messages[0]
    assert_eq(acceptance_text_count(prompt, "terminal-original"), 1)
    assert_eq(acceptance_text_count(prompt, "caller-mutated"), 0)
    assert_true(acceptance_user_message_contains(prompt, "terminal-original"))
  })
}
