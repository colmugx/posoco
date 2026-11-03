///|
async test "tool_assembly/static_definitions_are_read_once_and_bound_to_manifest" {
  let provider = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("static_echo", "static echo")],
    Map::from_array([
      (
        "static_echo",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("ok")),
      ),
    ]),
  )
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("static_echo", "call_1", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="declaring_extension", tools=[provider]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  assert_eq(provider.list_call_count(), 1)
  let result = agent.run_turn(@testkit.tk_user_msg("hello"), "assembly")
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
      {
        ..@testkit.tk_tool_def("static_raw", "original"),
        input_schema: schema,
      },
    ],
    reads: 0,
    calls: [],
  }
  let dynamic_provider = MutableDefinitions::{
    definitions: [
      {
        ..@testkit.tk_tool_def("dynamic_raw", "original"),
        input_schema: schema,
      },
    ],
    reads: 0,
    calls: [],
  }
  let publisher = ContributionPublisher::new(dynamic_provider)
  // Publish in a managed async scope while the originals are still intact, so
  // the frozen definitions — not a later mutation — are what the operation
  // captures.
  publisher.publish_at_start = false
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("static_raw", "static", { "value": "text" }),
    ),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("dynamic_raw", "dynamic", {
        "value": "text",
      }),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="static", tools=[static_provider]),
      @testkit.tk_ext(id="dynamic", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(publisher.publish(dynamic_provider))
  properties["value"] = { "type": "number" }
  static_provider.definitions[0] = @testkit.tk_tool_def(
    "changed_static", "changed",
  )
  dynamic_provider.definitions[0] = @testkit.tk_tool_def(
    "changed_dynamic", "changed",
  )
  let result = agent.run_turn(@testkit.tk_user_msg("hello"), "definition-copy")
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
  let memory = @testkit.ScriptedMemoryPort(inbounds=[None], search_script=[
    Some("found"),
  ])
  let provider = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("dynamic", "dynamic")],
    Map::from_array([]),
  )
  let publisher = ContributionPublisher::new(provider)
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("memory_search", "search", {
        "query": "needle",
      }),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let runtime = @runtime.PortRuntime(model~)
  let agent = Agent::with_runtime(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="memory-source", memory=[memory]),
      @testkit.tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  ignore(agent.run_turn(@testkit.tk_user_msg("hello"), "memory-owner"))
  assert_eq(memory.received_searches(), [("needle", None)])
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), [
    "memory_search", "memory_add", "dynamic",
  ])
  assert_eq(model.received_tools[0][0].owner.to_string(), "posoco.core")
  assert_eq(model.received_tools[0][1].owner.to_string(), "posoco.core")
}

///|
async test "tool_directory/multiple_publishers_share_operation_boundary" {
  let old = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("dynamic", "old")],
    Map::from_array([
      (
        "dynamic",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("old")),
      ),
    ]),
  )
  let replacement = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("dynamic", "new")],
    Map::from_array([
      (
        "dynamic",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("new")),
      ),
    ]),
  )
  let publisher = ContributionPublisher::new(old)
  let source = @support.ToolPublisher(
    @testkit.RecordingToolProvider(
      [@testkit.tk_tool_def("meta_v1", "metadata")],
      Map([]),
    ),
  )
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("dynamic", "a1", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("a1 done")),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("dynamic", "a2", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("a2 done")),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("dynamic", "b", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("b done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  runtime.follow_up_on_tool = true
  runtime.on_first_execute = Some(async fn() {
    source.publish(
      @testkit.RecordingToolProvider(
        [@testkit.tk_tool_def("meta_v2", "metadata")],
        Map([]),
      ),
    )
    ignore(publisher.publish(replacement))
  })
  let agent = Agent::with_runtime(
    exts=[
      source,
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  runtime.control = Some(agent.control())
  ignore(agent.run_turn(@testkit.tk_user_msg("A"), "source-snapshot"))
  assert_eq(old.exec_records().length(), 2)
  assert_eq(replacement.exec_records().length(), 0)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), [
    "meta_v1", "dynamic",
  ])
  assert_eq(model.received_tools[2].map(t => t.name.to_string()), [
    "meta_v1", "dynamic",
  ])
  let result = agent.run_turn(@testkit.tk_user_msg("B"), "source-snapshot")
  assert_eq(contribution_result_texts(result.tool_results), ["new"])
  assert_eq(model.received_tools[4].map(t => t.name.to_string()), [
    "meta_v2", "dynamic",
  ])
  assert_eq(replacement.exec_records().length(), 1)
}

///|
async test "tool_directory/renaming_and_owner_withdrawal_do_not_leave_stale_routes" {
  let old = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("old", "old")],
    Map::from_array([]),
  )
  let replacement = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("renamed", "new")],
    Map::from_array([
      (
        "renamed",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("new")),
      ),
    ]),
  )
  let other = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("other", "other")],
    Map::from_array([
      (
        "other",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("other")),
      ),
    ]),
  )
  let a = ContributionPublisher::new(old)
  let b = ContributionPublisher::new(other)
  a.publish_at_start = false
  b.publish_at_start = false
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("old", "stale", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("renamed", "new", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("other", "other", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="a", lifecycle=[a], requires=[@port.ToolContribution]),
      @testkit.tk_ext(id="b", lifecycle=[b], requires=[@port.ToolContribution]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(a.publish(old))
  ignore(b.publish(other))
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
  let result = agent.run_turn(@testkit.tk_user_msg("hello"), "owner-isolation")
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
