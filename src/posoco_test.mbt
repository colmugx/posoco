///|
/// Blackbox tests against the public API. Mocks live in this file and use
/// canonical kernel types directly.
struct MockModelPort {
  responses : Array[@kernel.ModelCallResult]
  mut index : Int32
}

///|
impl @port.ModelPort for MockModelPort with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  if self.index < self.responses.length() {
    let resp = self.responses[self.index]
    self.index = self.index + 1
    resp
  } else {
    raise Transport("no more responses")
  }
}

///|
impl @port.ModelPort for MockModelPort with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise ResponseParse("MockModelPort does not implement compact")
}

///|
impl @port.ModelPort for MockModelPort with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// MockToolProvider — implements the unified ToolProvider trait.
struct MockToolProvider {
  tools : Array[@kernel.ToolDef]
  results : Map[String, Result[@kernel.ToolOutcome, @error.RuntimeError]]
}

///|
impl @port.ToolProvider for MockToolProvider with fn list_tools(self) {
  self.tools
}

///|
impl @port.ToolProvider for MockToolProvider with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let name = ctx.name.to_string()
  match self.results.get(name) {
    Some(Ok(r)) => r
    Some(Err(e)) => raise e
    None => raise InvocationFailed("tool not found: \{name}")
  }
}

///|
struct MockSessionPort {
  store : Map[String, @types.Session]
}

///|
impl @port.SessionPort for MockSessionPort with fn load(self, id) -> @types.Session {
  if self.store.contains(id) {
    self.store[id]
  } else {
    { messages: [], metadata: Map::from_array([]), }
  }
}

///|
impl @port.SessionPort for MockSessionPort with fn save(self, id, session) -> Unit {
  self.store[id] = session
}

///|
struct MockObserver {
  events : Array[@types.TurnEvent]
}

///|
impl @port.Observer for MockObserver with fn on_event(self, _scope, event) {
  self.events.push(event)
}

///|
fn make_config() -> @posoco.AgentConfig {
  @posoco.agent_config(max_tool_rounds=Some(10))
}

///|
fn user_msg(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
fn stop_response(text : String) -> @kernel.ModelCallResult {
  {
    completion: Completion(
      content=[Text(text)],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: [],
  }
}

///|
/// Helper: empty tool provider
fn empty_tools() -> MockToolProvider {
  { tools: [], results: Map::from_array([]), }
}

///|
async test "b10_agent_reuses_one_puppet_across_turns" {
  let model = MockModelPort::{
    responses: [stop_response("first"), stop_response("second")],
    index: 0,
  }
  let store = MockSessionPort::{ store: Map::from_array([]), }
  let observer = MockObserver::{ events: [], }
  let agent = @posoco.Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=make_config(),
  )

  let first = agent.run_turn(user_msg("one"), "session_b10")
  assert_eq(model.index, 1)
  assert_eq(first.final_session_id, "session_b10")
  assert_true(store.store.contains("session_b10"))
  assert_eq(store.store["session_b10"].messages.length(), 2)

  let second = agent.run_turn(user_msg("two"), "session_b10")
  assert_eq(model.index, 2)
  assert_eq(second.final_session_id, "session_b10")
  assert_eq(store.store["session_b10"].messages.length(), 4)
}

///|
async test "b11_agent_runs_ephemerally_without_session_store" {
  let model = MockModelPort::{
    responses: [stop_response("ephemeral")],
    index: 0,
  }
  let agent = @posoco.Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("hello"), "ephemeral-session")
  assert_eq(result.final_session_id, "ephemeral-session")
  assert_eq(model.index, 1)
}

///|
fn registry_test_tool(name : String) -> @kernel.ToolDef {
  ToolDef(
    name=@kernel.ToolName::unchecked(name),
    description="registry test tool",
    input_schema=Json::null(),
    owner=@kernel.OwnerId::unchecked("test"),
    policy=Parallel,
    provenance=None,
  )
}

///|
fn registry_test_executor(_ctx : @port.ToolCallContext) -> @kernel.ToolOutcome {
  Success(content="ok", structured=None)
}

///|
test "tool_registry/register_overwrites_deliberately_strict_fails_fast" {
  let registry = @posoco.ToolRegistry()
  let tool = registry_test_tool("dup")
  registry.register(tool, registry_test_executor)
  // Lenient register is deliberate hot-replacement: same name overwrites.
  registry.register(tool, registry_test_executor)
  assert_eq(registry.list_tools().length(), 1)
  // Strict registration fails fast on the same name: a name collision is
  // never silently resolved by last-wins.
  let rejected = Ok(registry.register_strict(tool, registry_test_executor)) catch {
    e => Err(e)
  }
  match rejected {
    Err(ToolAlreadyRegistered(_)) => ()
    _ => fail("expected RuntimeError::ToolAlreadyRegistered")
  }
  // Strict registration of a fresh name succeeds.
  registry.register_strict(registry_test_tool("fresh"), registry_test_executor)
  assert_eq(registry.list_tools().length(), 2)
}
