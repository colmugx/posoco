///|
async test "tool_revoke/late_child_refusal_returns_interrupted_without_side_effects" {
  let publisher = ManualPublisher::new()
  let replies : Array[@kernel.InvocationResult] = []
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [
      { ..@testkit.tk_tool_def("parent", "parent"), policy: Exclusive, },
    ],
    owners: ["contrib"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("dyn_echo", Json::null()))
      @testkit.tk_ok_result("parent finished")
    },
  }
  let child = @testkit.RecordingToolProvider(
    [{ ..@testkit.tk_tool_def("dyn_echo", "child"), exposure: Deferred, }],
    Map([
      (
        "dyn_echo",
        @testkit.ScriptedToolOutcome::OutcomeOk(
          @testkit.tk_ok_result("unexpected"),
        ),
      ),
    ]),
  )
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("parent", "p", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let observer = @testkit.RecordingObserver()
  let runtime = AwaitingRuntime::AwaitingRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model), observers=[observer]),
      parent,
      @testkit.tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  ignore(publisher.capability().replace(provider=child))
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(() => {
      agent.run_turn(@testkit.tk_user_msg("hello"), "late-child")
    })
    while !runtime.entered.val {
      @async.pause()
    }
    ignore(publisher.capability().withdraw(mode=@port.Hard))
    runtime.released.val = true
    runtime.release.broadcast()
    ignore(turn.wait())
  })
  guard replies
    is [
      Interrupted(cancellation=AlreadySettled, side_effects_possible=false, ..),
    ] else {
    fail("a revoked child that never entered its provider must be Interrupted")
  }
  assert_eq(child.exec_records().length(), 0)
  assert_eq(
    observer.events().filter(e => e is ToolCallAbandoned(..)).length(),
    1,
  )
  agent.shutdown()
}
