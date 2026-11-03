///|
priv struct MinimalTool {
  calls : Array[String]
}

///|
impl @port.ToolProvider for MinimalTool with fn list_tools(_) {
  [
    @test_support.tk_tool_def("direct", "direct"),
    { ..@test_support.tk_tool_def("deferred", "deferred"), exposure: Deferred, },
    { ..@test_support.tk_tool_def("disabled", "disabled"), exposure: Disabled, },
  ]
}

///|
impl @port.ToolProvider for MinimalTool with fn execute(self, ctx) {
  self.calls.push(ctx.name.to_string())
  @test_support.tk_ok_result("executed")
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
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("direct", "d", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("deferred", "f", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("disabled", "x", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools], hooks=[hook]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("direct"), "minimal-ports"))
  for name in ["deferred", "disabled"] {
    let result = agent.run_turn(
      @test_support.tk_user_msg(name),
      "minimal-ports",
    )
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
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("one"),
            ),
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("two"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(id="lifecycle", lifecycle=[lifecycle]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "minimal-lifecycle"))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "minimal-lifecycle"))
  assert_eq(lifecycle.starts.val, 1)
  agent.shutdown()
}
