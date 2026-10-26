///|
async test "tool_retire/caller_cancellation_releases_the_operation_lease_and_retires_before_return" {
  let publisher = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let model = ScriptedModel([
    @agent.StreamParked(chunks=[]),
    Respond(tk_stop_response("retry")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
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
      agent.run_turn(tk_user_msg("hello"), "retire-cancel")
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
  ignore(agent.run_turn(tk_user_msg("retry"), "retire-cancel"))
  agent.shutdown()
}

///|
async test "tool_retire/unconfirmed_execution_keeps_resources_until_shutdown_confirms_stop" {
  let publisher = ManualPublisher::new()
  let facet = CancellationProbe::{ disposition: NotPropagated, ids: [], }
  let entered = Ref(false)
  let provider = InvocationFixture::{
    id: "leaf",
    definitions: [tk_tool_def("leaf", "leaf")],
    owners: [],
    action: async fn(ctx) {
      (ctx.register_cancel)(facet)
      entered.val = true
      @async.CondVar::Cond().wait()
      tk_ok_result("unreachable")
    },
  }
  let probe = RetireProbe::RetireProbe()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_tool_call_response("leaf", "call", Json::null())),
          ]),
        ),
      ),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  ignore(publisher.capability().replace(provider~, retire=probe.callback()))
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(allow_failure=true, () => {
      agent.run_turn(tk_user_msg("hello"), "unknown-execution")
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
  try agent.run_turn(tk_user_msg("unsafe"), "unknown-execution") catch {
    error =>
      assert_true(error.to_string().contains("unconfirmed tool execution"))
  } noraise {
    _ => fail("an unknown execution lost its admission barrier")
  }
  facet.disposition = Stopped
  agent.shutdown()
  assert_eq(probe.completed, 1)
}
