///|
async test "tool_binding/custom_runtime_can_inspect_forward_and_refuse_bound_execution" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dynamic", "dynamic")],
    Map::from_array([("dynamic", OutcomeOk(tk_ok_result("bound")))]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dynamic", "allowed", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_tool_call_response("dynamic", "refused", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime~,
  )
  let allowed = agent.run_turn(tk_user_msg("allow"), "bound-decorator")
  assert_eq(contribution_result_texts(allowed.tool_results), ["bound"])
  assert_eq(runtime.seen_contexts.length(), 1)
  assert_eq(runtime.seen_contexts[0].owner.to_string(), "publisher")
  runtime.deny_tools = true
  let refused = agent.run_turn(tk_user_msg("refuse"), "bound-decorator")
  guard refused.tool_results
    is [RuntimeFailure(error_category="HostDenied", ..)] else {
    fail("bound execution bypassed host refusal")
  }
  assert_eq(runtime.seen_contexts.length(), 2)
  assert_eq(provider.exec_records().length(), 1)
}

///|
async test "tool_binding/runtime_contract_needs_no_optional_support_flag" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dynamic", "dynamic")],
    Map::from_array([("dynamic", OutcomeOk(tk_ok_result("bound")))]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dynamic", "bound", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime~,
  )
  assert_true(publisher.contributions is Some(_))
  let result = agent.run_turn(tk_user_msg("execute"), "mandatory-binding")
  assert_eq(contribution_result_texts(result.tool_results), ["bound"])
  assert_eq(provider.exec_records().length(), 1)
  assert_eq(runtime.seen_contexts[0].owner.to_string(), "publisher")
}
