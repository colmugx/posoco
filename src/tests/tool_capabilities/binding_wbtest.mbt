///|
async test "tool_binding/custom_runtime_can_inspect_forward_and_refuse_bound_execution" {
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("dynamic", "dynamic")],
    Map::from_array([
      (
        "dynamic",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("bound"),
        ),
      ),
    ]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("dynamic", "allowed", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("dynamic", "refused", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let allowed = agent.run_turn(
    @test_support.tk_user_msg("allow"),
    "bound-decorator",
  )
  assert_eq(contribution_result_texts(allowed.tool_results), ["bound"])
  assert_eq(runtime.seen_contexts.length(), 1)
  assert_eq(runtime.seen_contexts[0].owner.to_string(), "publisher")
  runtime.deny_tools = true
  let refused = agent.run_turn(
    @test_support.tk_user_msg("refuse"),
    "bound-decorator",
  )
  guard refused.tool_results
    is [RuntimeFailure(error_category="HostDenied", ..)] else {
    fail("bound execution bypassed host refusal")
  }
  assert_eq(runtime.seen_contexts.length(), 2)
  assert_eq(provider.exec_records().length(), 1)
}
