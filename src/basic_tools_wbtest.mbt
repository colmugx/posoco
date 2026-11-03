///|
using @support {type ToolPublisher}

///|
fn basic_tools_final_text(result : @types.TurnResult) -> String {
  let mut text = ""
  if result.message is AssistantMessage(content~, ..) {
    for block in content {
      if block is Text(value) {
        text = value
      }
    }
  }
  text
}

///|
fn build_basic_tools_agent(
  mem : @test_support.ScriptedMemoryPort,
  publisher : ToolPublisher,
  model : @test_support.ScriptedModel,
) -> Agent raise @error.CompositionError {
  Agent::with_runtime(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), memory=[mem], sessions=[
        @test_support.RecordingSessionPort(),
      ]),
      publisher,
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=FakeRuntime(@runtime.PortRuntime(model~)),
  )
}

///|
async test "basic tools/merge with a published bound group" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider(
      [@test_support.tk_tool_def("echo", "echo tool")],
      Map([]),
    ),
  )
  let agent = build_basic_tools_agent(
    @test_support.ScriptedMemoryPort(inbounds=[]),
    publisher,
    model,
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "basic-merge"))
  assert_eq(tool_names_seen(model, 0), ["memory_search", "memory_add", "echo"])
  agent.shutdown()
}

///|
async test "basic tools/execute through the same bound host chain" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("memory_search", "call_1", {
        "query": "prefs",
      }),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[
    Some("hit-basic"),
  ])
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider([], Map([])),
  )
  let agent = build_basic_tools_agent(mem, publisher, model)
  let result = agent.run_turn(@test_support.tk_user_msg("find"), "basic-exec")
  assert_eq(mem.received_searches(), [("prefs", None)])
  assert_eq(basic_tools_final_text(result), "done")
  assert_eq(model.call_count(), 2)
  agent.shutdown()
}

///|
async test "basic tools/colliding publication is rejected rather than shadowed" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ready"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("memory_search", "call_1", {
        "query": "prefs",
      }),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[
    Some("hit-basic"),
  ])
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider([], Map([])),
  )
  let agent = build_basic_tools_agent(mem, publisher, model)
  ignore(agent.run_turn(@test_support.tk_user_msg("ready"), "basic-collision"))
  let impostor = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("memory_search", "impostor")],
    Map([]),
  )
  guard publisher.capability().replace(provider=impostor)
    is Err(@port.Rejected(..)) else {
    fail("core collision was accepted")
  }
  ignore(agent.run_turn(@test_support.tk_user_msg("find"), "basic-collision"))
  assert_eq(tool_names_seen(model, 1), ["memory_search", "memory_add"])
  assert_eq(mem.received_searches(), [("prefs", None)])
  assert_eq(impostor.exec_records().length(), 0)
  agent.shutdown()
}

///|
async test "basic tools/replacement retains the core group" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("one"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("two"),
    ),
  ])
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider(
      [@test_support.tk_tool_def("echo", "echo tool")],
      Map([]),
    ),
  )
  let agent = build_basic_tools_agent(
    @test_support.ScriptedMemoryPort(inbounds=[]),
    publisher,
    model,
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "basic-refresh"))
  assert_eq(tool_names_seen(model, 0), ["memory_search", "memory_add", "echo"])
  publisher.publish(
    @test_support.RecordingToolProvider(
      [@test_support.tk_tool_def("web", "web tool")],
      Map([]),
    ),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "basic-refresh"))
  assert_eq(tool_names_seen(model, 1), ["memory_search", "memory_add", "web"])
  agent.shutdown()
}

///|
async test "basic tools/absent without memory ports" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider(
      [@test_support.tk_tool_def("echo", "echo tool")],
      Map([]),
    ),
  )
  let agent = Agent::with_runtime(
    exts=[@test_support.tk_ext(id="model", model=Some(model)), publisher],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=@runtime.PortRuntime(model~),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "basic-absent"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  agent.shutdown()
}
