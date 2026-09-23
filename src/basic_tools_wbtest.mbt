///|
/// Composition-seam contract tests: core basic tools (the built-in memory
/// surface) merge ahead of a host-owned `CatalogSource` catalog and execute
/// through their own providers even when the host runtime chain does not
/// know them.

///|
/// Final assistant text of a completed turn.
fn basic_tools_final_text(result : @types.TurnResult) -> String {
  let mut text = ""
  match result.message {
    AssistantMessage(content~, ..) =>
      for block in content {
        match block {
          Text(t) => text = t
          _ => ()
        }
      }
    _ => ()
  }
  text
}

///|
/// Build a with_runtime Agent wired with a memory source and a host-owned
/// catalog source. The inner PortRuntime knows none of the tools, so any
/// basic-tool execution must ride the core decorator.
fn build_basic_tools_agent(
  mem : ScriptedMemoryPort,
  source : FakeCatalogSource,
  model : ScriptedModel,
) -> Agent raise @error.CompositionError {
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let fake = FakeRuntime(port_runtime)
  Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), memory=[mem as &@port.MemoryPort], sessions=[
        RecordingSessionStore(),
      ]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
    catalog_source=source as &@runtime.CatalogSource,
  )
}

///|
/// Merge arithmetic: the model sees the basic layer ahead of the source's
/// definitions — 2 core tools + 1 source tool = 3 catalog entries.
async test "basic tools/merge ahead of a source-owned catalog" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let source = FakeCatalogSource([tk_tool_def("echo", "echo tool")])
  let agent = build_basic_tools_agent(
    ScriptedMemoryPort(inbounds=[]),
    source,
    model,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_basic_merge"))
  assert_eq(tool_names_seen(model, 0), ["memory_search", "memory_add", "echo"])
}

///|
/// A memory_search call executes through the core provider even though the
/// host runtime chain has no tool routing at all; the host runtime never
/// sees the basic effect.
async test "basic tools/execute through a host runtime that lacks them" {
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response(
        "memory_search",
        "call_1",
        Json::object(Map::from_array([("query", Json::string("prefs"))])),
      ),
    ),
    Respond(tk_stop_response("done")),
  ])
  let mem = ScriptedMemoryPort(inbounds=[], search_script=[Some("hit-basic")])
  let agent = build_basic_tools_agent(mem, FakeCatalogSource([]), model)
  let result = agent.run_turn(tk_user_msg("find"), "session_basic_exec")
  assert_eq(mem.received_searches(), [("prefs", None)])
  assert_eq(basic_tools_final_text(result), "done")
  assert_eq(model.call_count(), 2)
}

///|
/// A source definition colliding with a basic name is shadowed: the catalog
/// keeps the basic layer, and execution lands on the core provider.
async test "basic tools/source definition colliding with a basic name is shadowed" {
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response(
        "memory_search",
        "call_1",
        Json::object(Map::from_array([("query", Json::string("prefs"))])),
      ),
    ),
    Respond(tk_stop_response("done")),
  ])
  let mem = ScriptedMemoryPort(inbounds=[], search_script=[Some("hit-basic")])
  let source = FakeCatalogSource([tk_tool_def("memory_search", "impostor")])
  let agent = build_basic_tools_agent(mem, source, model)
  ignore(agent.run_turn(tk_user_msg("find"), "session_basic_shadow"))
  assert_eq(tool_names_seen(model, 0), ["memory_search", "memory_add"])
  assert_eq(mem.received_searches(), [("prefs", None)])
}

///|
/// A catalog refresh keeps the basic layer ahead of the new definitions.
async test "basic tools/refresh keeps the basic layer ahead" {
  let echo_def = tk_tool_def("echo", "echo tool")
  let web_def = tk_tool_def("web", "web tool")
  let model = ScriptedModel([
    Respond(tk_stop_response("one")),
    Respond(tk_stop_response("two")),
  ])
  let source = FakeCatalogSource([echo_def])
  let agent = build_basic_tools_agent(
    ScriptedMemoryPort(inbounds=[]),
    source,
    model,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_basic_refresh"))
  assert_eq(tool_names_seen(model, 0), ["memory_search", "memory_add", "echo"])
  source.defs = [web_def]
  source.revision = 2
  ignore(agent.run_turn(tk_user_msg("two"), "session_basic_refresh"))
  assert_eq(tool_names_seen(model, 1), ["memory_search", "memory_add", "web"])
}

///|
/// Without memory ports there is no basic layer: the model sees exactly the
/// source's definitions.
async test "basic tools/absent without memory ports" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let fake = FakeRuntime(port_runtime)
  let source = FakeCatalogSource([tk_tool_def("echo", "echo tool")])
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
    catalog_source=source as &@runtime.CatalogSource,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_basic_absent"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
}
