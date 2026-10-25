///|
priv struct ExposureSwitch {
  mut disabled : Bool
  mut control : AgentControl?
}

///|
impl @port.PipelineHook for ExposureSwitch with fn tool_exposure(
  self,
  def : @kernel.ToolDef,
) -> @kernel.ToolExposure {
  if self.disabled && def.owner.to_string() == "tools" {
    Disabled
  } else {
    Direct
  }
}

///|
impl @port.PipelineHook for ExposureSwitch with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if !self.disabled {
    self.disabled = true
    if self.control is Some(control) {
      guard control.enqueue_follow_up(tk_user_msg("follow up"))
        is @runtime.Accepted(..) else {
        abort("follow up rejected")
      }
    }
  }
  Approve(call~)
}

///|
async test "tool_exposure/rules_are_frozen_for_followups_and_recomputed_for_next_operation" {
  let hook = ExposureSwitch::{ disabled: false, control: None, }
  let provider = RecordingToolProvider(
    [tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "a1", Json::null())),
    Respond(tk_stop_response("a1 done")),
    Respond(tk_tool_call_response("echo", "a2", Json::null())),
    Respond(tk_stop_response("a2 done")),
    Respond(tk_tool_call_response("echo", "b", Json::null())),
    Respond(tk_stop_response("b done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[provider], hooks=[hook]),
    ],
    config=tk_config(),
  )
  hook.control = Some(agent.control())
  ignore(agent.run_turn(tk_user_msg("A"), "projection"))
  assert_eq(provider.exec_records().length(), 2)
  let next = agent.run_turn(tk_user_msg("B"), "projection")
  guard next.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("next operation must use disabled projection")
  }
  assert_eq(provider.exec_records().length(), 2)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), ["echo"])
  assert_eq(model.received_tools[2].map(t => t.name.to_string()), ["echo"])
  assert_eq(model.received_tools[4].length(), 0)
}

///|
priv struct ExposureRewrite {}

///|
impl @port.PipelineHook for ExposureRewrite with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Approve(call={ ..call, name: @kernel.ToolName::unchecked("disabled"), })
}

///|
async test "tool_exposure/hook_rewrite_cannot_enter_disabled_target" {
  let provider = RecordingToolProvider(
    [
      tk_tool_def("direct", "direct"),
      { ..tk_tool_def("disabled", "disabled"), exposure: Disabled, },
    ],
    Map::from_array([]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("direct", "rewrite", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[provider], hooks=[ExposureRewrite::{ }]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "rewrite-exposure")
  guard result.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("rewrites must be checked against effective exposure")
  }
  assert_eq(provider.exec_records().length(), 0)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), ["direct"])
}

///|
async test "tool_exposure/deferred_tool_is_not_offered_and_guessing_is_rejected" {
  let deferred = {
    ..tk_tool_def("secret", "deferred"),
    exposure: @kernel.ToolExposure::Deferred,
  }
  let provider = RecordingToolProvider(
    [deferred],
    Map::from_array([("secret", OutcomeOk(tk_ok_result("must not execute")))]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("secret", "guess", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="owner", tools=[provider]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "exposure")
  assert_eq(model.received_tools[0].length(), 0)
  assert_eq(provider.exec_records().length(), 0)
  guard result.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("a guessed deferred tool must be rejected")
  }
}

///|
async test "tool_exposure/manual_compact_only_receives_direct_projection" {
  let model = ScriptedModel([Compact(result=policy_replace_result())])
  let store = RecordingSessionStore()
  compact_tools_seed(store, "exposure-compact")
  let provider = RecordingToolProvider(
    [
      { ..tk_tool_def("deferred", "deferred"), exposure: Deferred, },
      { ..tk_tool_def("disabled", "disabled"), exposure: Disabled, },
      tk_tool_def("direct", "direct"),
    ],
    Map::from_array([]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[store]),
      tk_ext(id="tools", tools=[provider]),
    ],
    config=tk_config(),
  )
  ignore(agent.compact_session("exposure-compact"))
  assert_eq(model.received_compact_tools[0].map(t => t.name.to_string()), [
    "direct",
  ])
}
