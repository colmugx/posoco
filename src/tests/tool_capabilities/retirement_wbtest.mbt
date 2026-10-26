///|
async test "tool_retire/failed_cleanup_preserves_the_committed_revision_and_retries_idempotently" {
  let publisher = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let probe = RetireProbe::RetireProbe(failures_left=1)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let cap = publisher.capability()
  guard cap.replace(provider~, retire=probe.callback()) is Ok(_) else {
    fail("publish failed")
  }
  guard cap.withdraw()
    is Err(@port.CleanupPending(revision=2, state=Withdrawn, ..)) else {
    fail("cleanup failure must acknowledge the committed withdrawal")
  }
  assert_eq(cap.state(), @port.Withdrawn)
  assert_eq(cap.revision(), None)
  guard cap.withdraw() is Ok({ revision: 2, .. }) else {
    fail("withdrawal retry changed revision")
  }
  assert_eq(probe.attempts, 2)
  assert_eq(probe.completed, 1)
  agent.shutdown()
  assert_eq(cap.state(), @port.Closed)
  guard cap.replace(provider~) is Err(@port.ToolContributionError::Closed) else {
    fail("closed handle published")
  }
  assert_eq(probe.attempts, 2)
}

///|
async test "tool_retire/shutdown_retries_failed_cleanup_without_repeating_successful_retire" {
  let publisher = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let probe = RetireProbe::RetireProbe(failures_left=1)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  guard publisher.capability().replace(provider~, retire=probe.callback())
    is Ok(_) else {
    fail("publish failed")
  }
  try agent.shutdown() catch {
    error => assert_true(error.to_string().contains("cleanup pending"))
  } noraise {
    _ => fail("failed retire was silently accepted")
  }
  assert_eq(probe.completed, 0)
  agent.shutdown()
  assert_eq(probe.completed, 1)
  agent.shutdown()
  assert_eq(probe.attempts, 2)
}

///|
async test "tool_retire/shutdown_does_not_succeed_while_a_retire_is_in_progress" {
  let publisher = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let entered = Ref(false)
  let released = Ref(false)
  let signal = @async.CondVar::Cond()
  ignore(
    publisher
    .capability()
    .replace(provider~, retire=async fn() {
      entered.val = true
      while !released.val {
        signal.wait()
      }
      Ok(())
    }),
  )
  @async.with_task_group(async fn(group) {
    let withdrawal = group.spawn(() => publisher.capability().withdraw())
    while !entered.val {
      @async.pause()
    }
    try agent.shutdown() catch {
      error => assert_true(error.to_string().contains("cleanup pending"))
    } noraise {
      _ => fail("shutdown completed with a live retire callback")
    }
    released.val = true
    signal.broadcast()
    guard withdrawal.wait() is Ok(_) else { fail("withdrawal failed") }
  })
  agent.shutdown()
}

///|
async test "tool_retire/another_owners_cleanup_failure_does_not_fail_a_publication" {
  let a = ManualPublisher::new()
  let b = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let probe = RetireProbe::RetireProbe(failures_left=3)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="a", lifecycle=[a], requires=[@port.ToolContribution]),
      tk_ext(id="b", lifecycle=[b], requires=[@port.ToolContribution]),
    ],
    config=tk_config(),
  )
  ignore(a.capability().replace(provider~, retire=probe.callback()))
  guard a.capability().withdraw() is Err(@port.CleanupPending(..)) else {
    fail("expected cleanup failure")
  }
  guard b.capability().replace(provider~)
    is Ok({ owner: "b", state: Active, .. }) else {
    fail("another owner's retire must not make b's ACK a cleanup failure")
  }
  assert_eq(probe.attempts, 1)
  probe.failures_left = 0
  agent.shutdown()
}

///|
async test "tool_retire/revoking_an_old_owner_does_not_revoke_a_reused_tool_name" {
  let a = ManualPublisher::new()
  let b = ManualPublisher::new()
  let provider = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf")],
    Map([("leaf", OutcomeOk(tk_ok_result("b result")))]),
  )
  let probe = RetireProbe::RetireProbe(failures_left=100)
  let hook = ConsentWaitHook::ConsentWaitHook()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_tool_call_response("leaf", "call", Json::null())),
            Respond(tk_stop_response("done")),
          ]),
        ),
        hooks=[hook],
      ),
      tk_ext(id="a", lifecycle=[a], requires=[@port.ToolContribution]),
      tk_ext(id="b", lifecycle=[b], requires=[@port.ToolContribution]),
    ],
    config=tk_config(),
  )
  ignore(a.capability().replace(provider~, retire=probe.callback()))
  ignore(a.capability().withdraw())
  guard b.capability().replace(provider~) is Ok(_) else {
    fail("b publish failed")
  }
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(() => {
      agent.run_turn(tk_user_msg("hello"), "reused-name")
    })
    while !hook.waiting.val {
      @async.pause()
    }
    ignore(a.capability().withdraw(mode=@port.Hard))
    hook.released.val = true
    hook.release.broadcast()
    let result = turn.wait()
    assert_eq(contribution_result_texts(result.tool_results), ["b result"])
  })
  assert_eq(provider.exec_records().length(), 1)
  probe.failures_left = 0
  agent.shutdown()
}
