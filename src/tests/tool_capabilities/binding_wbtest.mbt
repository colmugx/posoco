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
  let runtime = FakeRuntime(
    @runtime.PortRuntime(model~, tools=Map::from_array([])),
  )
  runtime.bound_support = true
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
  assert_true(runtime.seen_contexts[0].has_bound_tool())
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
async test "tool_binding/unsupported_runtime_is_rejected_before_on_compose" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dynamic", "dynamic")],
    Map::from_array([]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = ScriptedModel([])
  let runtime = FakeRuntime(
    @runtime.PortRuntime(model~, tools=Map::from_array([])),
  )
  try
    Agent::with_runtime(
      exts=[
        tk_ext(id="model", model=Some(model)),
        tk_ext(id="publisher", lifecycle=[publisher], requires=[
          @port.ToolContribution,
        ]),
      ],
      config=tk_config(),
      runtime~,
    )
  catch {
    @error.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      assert_eq(manifest_id, "publisher")
      assert_true(detail.contains("supports_bound_tools"))
    }
    other => fail("unexpected failure: " + other.to_string())
  } noraise {
    _ => fail("unsupported runtime was accepted")
  }
  assert_true(publisher.contributions is None)
  assert_eq(provider.list_call_count(), 0)
}
