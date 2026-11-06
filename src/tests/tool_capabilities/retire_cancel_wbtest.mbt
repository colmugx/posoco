///|
async test "tool_retire/caller_cancellation_releases_the_operation_lease_and_retires_before_return" {
  let publisher = ManualPublisher::new()
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("leaf", "leaf")],
    Map([]),
  )
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::StreamParked(chunks=[]),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("retry"),
    ),
  ])
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  let retired = Ref(false)
  ignore(
    publisher
    .capability()
    .replace(provider~, retire=async fn() {
      @async.pause()
      retired.val = true
      Ok(())
    }),
  )
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(allow_failure=true, () => {
      agent.run_turn(@test_support.tk_user_msg("hello"), "retire-cancel")
    })
    while model.parked_calls == 0 {
      @async.pause()
    }
    ignore(publisher.capability().withdraw())
    assert_false(retired.val)
    turn.cancel()
    ignore(
      @async.handle_cancellation(() => {
        ignore(turn.wait()) catch {
          @error.AgentError::Cancelled(_) | @async.WaitedTaskAlreadyCancelled =>
            ()
          error => raise error
        }
      }),
    )
  })
  assert_true(retired.val)
  ignore(agent.run_turn(@test_support.tk_user_msg("retry"), "retire-cancel"))
  agent.shutdown()
}

///|
async test "tool_retire/unconfirmed_execution_keeps_resources_until_shutdown_confirms_stop" {
  let publisher = ManualPublisher::new()
  let facet = CancellationProbe::{ disposition: NotPropagated, ids: [], }
  let entered = Ref(false)
  let provider = InvocationFixture::{
    id: "leaf",
    definitions: [@test_support.tk_tool_def("leaf", "leaf")],
    owners: [],
    action: async fn(ctx) {
      (ctx.register_cancel)(facet)
      entered.val = true
      @cond_var.Cond::Cond().wait()
      @test_support.tk_ok_result("unreachable")
    },
  }
  let probe = RetireProbe::RetireProbe()
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_tool_call_response("leaf", "call", Json::null()),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(publisher.capability().replace(provider~, retire=probe.callback()))
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(allow_failure=true, () => {
      agent.run_turn(@test_support.tk_user_msg("hello"), "unknown-execution")
    })
    while !entered.val {
      @async.pause()
    }
    ignore(publisher.capability().withdraw())
    turn.cancel()
    ignore(
      @async.handle_cancellation(() => {
        ignore(turn.wait()) catch {
          @error.AgentError::Cancelled(_) | @async.WaitedTaskAlreadyCancelled =>
            ()
          error => raise error
        }
      }),
    )
  })
  assert_eq(probe.attempts, 0)
  try
    agent.run_turn(@test_support.tk_user_msg("unsafe"), "unknown-execution")
  catch {
    error =>
      assert_true(error.to_string().contains("unconfirmed tool execution"))
  } noraise {
    _ => fail("an unknown execution lost its admission barrier")
  }
  facet.disposition = Stopped
  agent.shutdown()
  assert_eq(probe.completed, 1)
}

///|
/// Foreground work admitted by the probe during a turn: the hard cancel must
/// settle it through the worker's unwind cleanup instead of leaving it live.
priv struct ForegroundCleanupProbe {
  mut tasks : @port.Tasks?
  mut handle : @port.TaskHandle?
  started : Ref[Bool]
}

///|
fn ForegroundCleanupProbe::new() -> ForegroundCleanupProbe {
  { tasks: None, handle: None, started: Ref(false), }
}

///|
impl @port.PipelineHook for ForegroundCleanupProbe with fn on_turn_begin(self) -> Unit {
  let tasks = match self.tasks {
    Some(value) => value
    None => return
  }
  let handle = match
    tasks.submit({
      session_id: "worker-cleanup",
      mode: @port.TaskMode::Foreground,
      label: "foreground-parked",
      timeout_ms: None,
      run: async fn() {
        self.started.val = true
        // Parked until the operation's cancellation cleanup settles it; never
        // elapses in a test.
        @async.sleep(600_000)
        @kernel.Message::UserMessage(content=[@kernel.Content::Text("late")])
      },
    }) {
    Ok(handle) => handle
    Err(_) => return
  }
  self.handle = Some(handle)
}

///|
impl @port.Lifecycle for ForegroundCleanupProbe with fn on_compose(
  self,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for ForegroundCleanupProbe with fn on_shutdown(_self) -> Unit {
  ()
}

///|
async test "tool_retire/hard_cancel_settles_foreground_work_and_closes_the_pending_tool_call" {
  let publisher = ManualPublisher::new()
  let tool_entered = Ref(false)
  let provider = InvocationFixture::{
    id: "leaf",
    definitions: [@test_support.tk_tool_def("leaf", "leaf")],
    owners: [],
    action: async fn(_ctx) {
      tool_entered.val = true
      @async.sleep(600_000)
      @test_support.tk_ok_result("unreachable")
    },
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("leaf", "call", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("after cancel"),
    ),
  ])
  let observer = @test_support.RecordingObserver()
  let probe = ForegroundCleanupProbe::new()
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), observers=[observer]),
      @test_support.tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
      @test_support.tk_ext(
        id="tasks",
        hooks=[probe as &@port.PipelineHook],
        lifecycle=[probe as &@port.Lifecycle],
        requires=[@port.Capability::Tasks],
      ),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  let retired = Ref(false)
  ignore(
    publisher
    .capability()
    .replace(provider~, retire=async fn() {
      @async.pause()
      retired.val = true
      Ok(())
    }),
  )
  let outcome : Ref[Result[@types.TurnResult, Error]?] = Ref(None)
  agent.run_scoped(async fn(agent) {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, () => {
        agent.run_turn(@test_support.tk_user_msg("hello"), "worker-cleanup")
      })
      // Deterministic gates: the foreground task is running and the tool call
      // is mid-execution, so the cancel below lands with both kinds of work
      // still live.
      while !probe.started.val || !tool_entered.val {
        @async.pause()
      }
      let withdrawn = publisher.capability().withdraw()
      guard withdrawn is Ok(_) else {
        fail("the soft withdrawal must be accepted: \{repr(withdrawn)}")
      }
      // The operation still holds the lease: nothing may retire yet.
      assert_false(retired.val)
      turn.cancel()
      ignore(
        @async.handle_cancellation(() => {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
    let result : Result[@types.TurnResult, Error] = Ok(
      agent.run_turn(@test_support.tk_user_msg("retry"), "worker-cleanup"),
    ) catch {
      error => Err(error)
    }
    outcome.val = Some(result)
    // The unwind settled the foreground task instead of leaking it.
    let handle = match probe.handle {
      Some(value) => value
      None => abort("the foreground task was never admitted")
    }
    let settled_status = handle.wait().status
    guard settled_status is @port.TaskStatus::Cancelled(_) else {
      fail(
        "foreground work was not settled by the operation cleanup: \{repr(settled_status)}",
      )
    }
    // The pending tool call received exactly one terminal event: the
    // cancellation drain closed it instead of leaving the projection open.
    let terminals = observer
      .events()
      .filter(fn(event) {
        match event {
          ToolCallSucceeded(..)
          | ToolCallFailed(..)
          | ToolCallRejected(..)
          | ToolCallAbandoned(..) => true
          _ => false
        }
      })
    assert_eq(terminals.length(), 1)
    guard terminals[0] is ToolCallAbandoned(call~, reason~) else {
      fail(
        "expected the drained call to be abandoned, got \{repr(terminals[0])}",
      )
    }
    assert_eq(call.call_id.to_string(), "call")
    assert_true(reason != "")
    // The cancellation was recorded as its own settled outcome; the retried
    // turn then settled normally, on the same Agent.
    let settled_outcomes = observer
      .events()
      .filter_map(fn(event) {
        match event {
          Custom(source~, label~, data~) => {
            if source != "posoco.operation" || label != "operation_settled" {
              return None
            }
            match data {
              Object(fields) =>
                match fields.get("outcome") {
                  Some(String(value)) => Some(value)
                  _ => None
                }
              _ => None
            }
          }
          _ => None
        }
      })
    assert_eq(settled_outcomes, ["cancelled", "completed"])
  })
  // The lease was released by the unwind, so the withdrawn version could
  // retire; a leaked lease would keep the callback from ever running.
  assert_true(retired.val)
  guard outcome.val is Some(Ok(result)) else {
    fail("the Agent must admit the next operation after the hard cancel")
  }
  guard result.message
    is @kernel.Message::AssistantMessage(
      content=[@kernel.Content::Text("after cancel")],
      ..
    ) else {
    fail("the retried turn must reach the model after the hard cancel")
  }
  agent.shutdown()
}
