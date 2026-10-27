///|
priv struct MinimalTool {
  calls : Array[String]
}

///|
impl @port.ToolProvider for MinimalTool with fn list_tools(_) {
  [
    tk_tool_def("direct", "direct"),
    { ..tk_tool_def("deferred", "deferred"), exposure: Deferred, },
    { ..tk_tool_def("disabled", "disabled"), exposure: Disabled, },
  ]
}

///|
impl @port.ToolProvider for MinimalTool with fn execute(self, ctx) {
  self.calls.push(ctx.name.to_string())
  tk_ok_result("executed")
}

///|
priv struct BeforeToolOnly {
  calls : Array[String]
}

///|
impl @port.PipelineHook for BeforeToolOnly with fn before_tool(self, call) {
  self.calls.push(call.name.to_string())
  @port.ToolDecision::Approve(call~)
}

///|
priv struct StartOnly {
  starts : Ref[Int32]
}

///|
impl @port.Lifecycle for StartOnly with fn on_start(self) {
  self.starts.val += 1
}

///|
async test "port_defaults/minimal_tool_and_hook_preserve_declared_exposure" {
  let tools = MinimalTool::{ calls: [], }
  let hook = BeforeToolOnly::{ calls: [], }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("direct", "d", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_tool_call_response("deferred", "f", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_tool_call_response("disabled", "x", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools], hooks=[hook]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("direct"), "minimal-ports"))
  for name in ["deferred", "disabled"] {
    let result = agent.run_turn(tk_user_msg(name), "minimal-ports")
    guard result.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
      fail("default hook widened tool exposure")
    }
  }
  assert_eq(tools.calls, ["direct"])
  assert_eq(hook.calls, ["direct"])
  for definitions in model.received_tools {
    assert_eq(definitions.map(def => def.name.to_string()), ["direct"])
  }
  agent.shutdown()
}

///|
async test "port_defaults/start_only_lifecycle_can_shutdown_without_an_override" {
  let lifecycle = StartOnly::{ starts: Ref(0), }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_stop_response("one")),
            Respond(tk_stop_response("two")),
          ]),
        ),
      ),
      tk_ext(id="lifecycle", lifecycle=[lifecycle]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("one"), "minimal-lifecycle"))
  ignore(agent.run_turn(tk_user_msg("two"), "minimal-lifecycle"))
  assert_eq(lifecycle.starts.val, 1)
  agent.shutdown()
}
