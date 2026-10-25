///|
async test "tool_assembly/static_definitions_are_read_once_and_bound_to_manifest" {
  let provider = RecordingToolProvider(
    [tk_tool_def("static_echo", "static echo")],
    Map::from_array([("static_echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("static_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="declaring_extension", tools=[provider]),
    ],
    config=tk_config(),
  )
  assert_eq(provider.list_call_count(), 1)
  let result = agent.run_turn(tk_user_msg("hello"), "assembly")
  assert_eq(contribution_result_texts(result.tool_results), ["ok"])
  assert_eq(provider.list_call_count(), 1)
  assert_eq(model.received_tools[0][0].owner.to_string(), "declaring_extension")
}

///|
priv struct MutableDefinitions {
  definitions : Array[@kernel.ToolDef]
  mut reads : Int32
  calls : Array[String]
}

///|
impl @port.ToolProvider for MutableDefinitions with fn list_tools(self) -> Array[
  @kernel.ToolDef,
] {
  self.reads += 1
  self.definitions
}

///|
impl @port.ToolProvider for MutableDefinitions with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome {
  self.calls.push(ctx.name.to_string())
  Success(content="ok", structured=None)
}

///|
async test "tool_directory/static_and_dynamic_definitions_are_deep_copied_at_commit" {
  let properties : Map[String, Json] = { "value": { "type": "string" } }
  let schema : Json = {
    "type": "object",
    "properties": Json::object(properties),
    "required": ["value"],
  }
  let static_provider = MutableDefinitions::{
    definitions: [
      { ..tk_tool_def("static_raw", "original"), input_schema: schema, },
    ],
    reads: 0,
    calls: [],
  }
  let dynamic_provider = MutableDefinitions::{
    definitions: [
      { ..tk_tool_def("dynamic_raw", "original"), input_schema: schema, },
    ],
    reads: 0,
    calls: [],
  }
  let publisher = ContributionPublisher::new(dynamic_provider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("static_raw", "static", { "value": "text" })),
    Respond(
      tk_tool_call_response("dynamic_raw", "dynamic", { "value": "text" }),
    ),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="static", tools=[static_provider]),
      tk_ext(id="dynamic", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  properties["value"] = { "type": "number" }
  static_provider.definitions[0] = tk_tool_def("changed_static", "changed")
  dynamic_provider.definitions[0] = tk_tool_def("changed_dynamic", "changed")
  let result = agent.run_turn(tk_user_msg("hello"), "definition-copy")
  assert_eq(contribution_result_texts(result.tool_results), ["ok", "ok"])
  assert_eq(static_provider.calls, ["static_raw"])
  assert_eq(dynamic_provider.calls, ["dynamic_raw"])
  assert_eq(static_provider.reads, 1)
  assert_eq(dynamic_provider.reads, 1)
  assert_eq(model.received_tools[0].map(t => t.description), [
    "original", "original",
  ])
}

///|
async test "tool_directory/memory_is_core_bound_with_source_and_contribution" {
  let memory = ScriptedMemoryPort(inbounds=[None], search_script=[Some("found")])
  let provider = RecordingToolProvider(
    [tk_tool_def("dynamic", "dynamic")],
    Map::from_array([]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response("memory_search", "search", { "query": "needle" }),
    ),
    Respond(tk_stop_response("done")),
  ])
  let runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="memory-source", memory=[memory]),
      tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime~,
    catalog_source=ContributionCatalogSource::{ },
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "memory-owner"))
  assert_eq(memory.received_searches(), [("needle", None)])
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), [
    "memory_search", "memory_add", "dynamic",
  ])
  assert_eq(model.received_tools[0][0].owner.to_string(), "posoco.core")
  assert_eq(model.received_tools[0][1].owner.to_string(), "posoco.core")
}

///|
async test "tool_directory/source_and_binding_updates_share_operation_boundary" {
  let old = RecordingToolProvider(
    [tk_tool_def("dynamic", "old")],
    Map::from_array([("dynamic", OutcomeOk(tk_ok_result("old")))]),
  )
  let replacement = RecordingToolProvider(
    [tk_tool_def("dynamic", "new")],
    Map::from_array([("dynamic", OutcomeOk(tk_ok_result("new")))]),
  )
  let publisher = ContributionPublisher::new(old)
  let source = FakeCatalogSource([tk_tool_def("legacy_v1", "legacy")])
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dynamic", "a1", Json::null())),
    Respond(tk_stop_response("a1 done")),
    Respond(tk_tool_call_response("dynamic", "a2", Json::null())),
    Respond(tk_stop_response("a2 done")),
    Respond(tk_tool_call_response("dynamic", "b", Json::null())),
    Respond(tk_stop_response("b done")),
  ])
  let runtime = FakeRuntime(
    @runtime.PortRuntime(model~, tools=Map::from_array([])),
  )
  runtime.bound_support = true
  runtime.follow_up_on_tool = true
  runtime.on_first_execute = Some(fn() {
    source.defs = [tk_tool_def("legacy_v2", "legacy")]
    source.revision += 1
    ignore(publisher.publish(replacement))
  })
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime~,
    catalog_source=source,
  )
  runtime.control = Some(agent.control())
  ignore(agent.run_turn(tk_user_msg("A"), "source-snapshot"))
  assert_eq(old.exec_records().length(), 2)
  assert_eq(replacement.exec_records().length(), 0)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), [
    "legacy_v1", "dynamic",
  ])
  assert_eq(model.received_tools[2].map(t => t.name.to_string()), [
    "legacy_v1", "dynamic",
  ])
  let result = agent.run_turn(tk_user_msg("B"), "source-snapshot")
  assert_eq(contribution_result_texts(result.tool_results), ["new"])
  assert_eq(model.received_tools[4].map(t => t.name.to_string()), [
    "legacy_v2", "dynamic",
  ])
  assert_eq(replacement.exec_records().length(), 1)
}

///|
async test "tool_directory/renaming_and_owner_withdrawal_do_not_leave_stale_routes" {
  let old = RecordingToolProvider(
    [tk_tool_def("old", "old")],
    Map::from_array([]),
  )
  let replacement = RecordingToolProvider(
    [tk_tool_def("renamed", "new")],
    Map::from_array([("renamed", OutcomeOk(tk_ok_result("new")))]),
  )
  let other = RecordingToolProvider(
    [tk_tool_def("other", "other")],
    Map::from_array([("other", OutcomeOk(tk_ok_result("other")))]),
  )
  let a = ContributionPublisher::new(old)
  let b = ContributionPublisher::new(other)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("old", "stale", Json::null())),
    Respond(tk_tool_call_response("renamed", "new", Json::null())),
    Respond(tk_tool_call_response("other", "other", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="a", lifecycle=[a], requires=[@port.ToolContribution]),
      tk_ext(id="b", lifecycle=[b], requires=[@port.ToolContribution]),
    ],
    config=tk_config(),
  )
  guard a.capability().withdraw() is Ok(first) else {
    fail("withdraw rejected")
  }
  assert_eq(first.revision, 2)
  guard a.capability().withdraw() is Ok(repeated) else {
    fail("repeated withdraw rejected")
  }
  assert_eq(repeated.revision, 2)
  let accepted = a.publish(replacement)
  assert_eq(accepted.revision, 3)
  assert_eq(b.capability().revision(), Some(1))
  let result = agent.run_turn(tk_user_msg("hello"), "owner-isolation")
  guard result.tool_results
    is [
      NotExecuted(reason=UnknownTool, ..),
      Success(content="new", ..),
      Success(content="other", ..),
    ] else {
    fail("rename/withdraw changed another owner or retained stale route")
  }
  assert_eq(old.exec_records().length(), 0)
  assert_eq(replacement.exec_records().length(), 1)
  assert_eq(other.exec_records().length(), 1)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), [
    "renamed", "other",
  ])
}
