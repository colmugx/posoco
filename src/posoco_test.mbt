///|
/// Blackbox tests against the public API. Mocks live in this file.
/// R3 M3.7: all fixtures use canonical kernel types directly.
struct MockModelPort {
  responses : Array[@kernel.ModelCallResult]
  mut index : Int
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
    raise @error.ModelError::Transport("no more responses")
  }
}

///|
impl @port.ModelPort for MockModelPort with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse(
    "MockModelPort does not implement compact",
  )
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
  name : String,
  _call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  match self.results.get(name) {
    Some(Ok(r)) => r
    Some(Err(e)) => raise e
    None =>
      raise @error.RuntimeError::InvocationFailed("tool not found: \{name}")
  }
}

///|
struct MockSessionStore {
  store : Map[String, @types.Session]
}

///|
impl @port.SessionStore for MockSessionStore with fn load(self, id) -> @types.Session {
  if self.store.contains(id) {
    self.store[id]
  } else {
    { messages: [], metadata: Map::from_array([]), }
  }
}

///|
impl @port.SessionStore for MockSessionStore with fn save(self, id, session) -> Unit {
  self.store[id] = session
}

///|
struct MockObserver {
  events : Array[@types.TurnEvent]
}

///|
impl @port.Observer for MockObserver with fn on_event(self, event) {
  self.events.push(event)
}

///|
fn make_config() -> @posoco.AgentConfig {
  @posoco.agent_config(max_tool_rounds=Some(10))
}

///|
fn user_msg(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
fn stop_response(text : String) -> @kernel.ModelCallResult {
  {
    completion: @kernel.Completion(
      content=[@kernel.Text(text)],
      tool_calls=[],
      reasoning=None,
      finish_reason=@kernel.Stop,
      usage=None,
    ),
    processed_messages: [],
  }
}

///|
/// Helper: empty tool provider
fn empty_tools() -> MockToolProvider {
  MockToolProvider::{ tools: [], results: Map::from_array([]), }
}

///|
async test "b1_simple_turn_no_tools" {
  let model = MockModelPort::{ responses: [stop_response("hi")], index: 0, }
  let store = MockSessionStore::{ store: Map::from_array([]), }
  let observer = MockObserver::{ events: [], }
  let config = make_config()

  let agent = @posoco.Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("hello"), "session_b1")
  assert_eq(result.final_session_id, "session_b1")
  assert_true(result.tool_results.is_empty())
}

///|
async test "b5_build_tool_result_message" {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("ct_1"),
    name: @kernel.ToolName::unchecked("tool_a"),
    arguments: Json::null(),
  }
  let outcome = @kernel.Success(content="done", structured=None)
  let msg = @posoco.build_tool_result_message(call, outcome)
  assert_true(msg is @kernel.ToolMessage(..))
  match msg {
    @kernel.ToolMessage(call_id~, ..) => assert_eq(call_id.to_string(), "ct_1")
    _ => fail("expected ToolMessage")
  }
}

///|
async test "b6_build_error_message" {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("ct_2"),
    name: @kernel.ToolName::unchecked("tool_b"),
    arguments: Json::null(),
  }
  let err = @error.RuntimeError::InvocationFailed("fail")
  let msg = @posoco.build_error_message(call, err)
  match msg {
    @kernel.ToolMessage(call_id~, outcome~, ..) => {
      assert_eq(call_id.to_string(), "ct_2")
      assert_true(outcome is @kernel.RuntimeFailure(..))
    }
    _ => fail("expected ToolMessage")
  }
}

///|
async test "b7_agent_error_display" {
  let model_err = @error.AgentError::Model("nope")
  let s = model_err.to_string()
  assert_true(s.length() > 0)
  assert_true(s.contains("nope"))
}

///|
async test "b8_turn_event_lifecycle" {
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0, }
  let store = MockSessionStore::{ store: Map::from_array([]), }
  let observer = MockObserver::{ events: [], }
  let config = make_config()

  let agent = @posoco.Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let _ = agent.run_turn(user_msg("event test"), "session_b8")

  let events = observer.events
  assert_true(events.length() >= 2)
  match events[0] {
    @types.TurnEvent::TurnStarted => ()
    _ => fail("first event should be TurnStarted")
  }
  match events[events.length() - 1] {
    @types.TurnEvent::TurnCompleted => ()
    _ => fail("last event should be TurnCompleted")
  }
}

///|
async test "b9_model_error_aborts" {
  let model = MockModelPort::{ responses: [], index: 0, }
  let store = MockSessionStore::{ store: Map::from_array([]), }
  let observer = MockObserver::{ events: [], }
  let config = make_config()

  let agent = @posoco.Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("boom"), "session_b9")) catch { e => Err(e) }) {
    Err(@error.AgentError::Model(_)) => ()
    _ => fail("expected Model error")
  }
}

///|
async test "b10_agent_reuses_one_puppet_across_turns" {
  let model = MockModelPort::{
    responses: [stop_response("first"), stop_response("second")],
    index: 0,
  }
  let store = MockSessionStore::{ store: Map::from_array([]), }
  let observer = MockObserver::{ events: [], }
  let agent = @posoco.Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
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
test "b11_agent_requires_session_store_at_composition" {
  let model = MockModelPort::{ responses: [], index: 0, }
  let result = Ok(
    @posoco.Agent(
      exts=[tk_ext(id="model", model=Some(model))],
      config=make_config(),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@error.CompositionError::EmptyPort("SessionStore")) => ()
    _ => fail("expected missing SessionStore to fail composition")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// ToolRegistry — register vs register_strict collision semantics
// ──────────────────────────────────────────────────────────────────────────

///|
fn registry_test_tool(name : String) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=@kernel.ToolName::unchecked(name),
    description="registry test tool",
    input_schema=Json::null(),
    owner=@kernel.OwnerId::unchecked("test"),
    policy=@kernel.Parallel,
    provenance=None,
  )
}

///|
fn registry_test_executor(_call : @kernel.ToolCall) -> @kernel.ToolOutcome {
  @kernel.Success(content="ok", structured=None)
}

///|
test "tool_registry/register_overwrites_deliberately_strict_fails_fast" {
  let registry = @posoco.ToolRegistry()
  let tool = registry_test_tool("dup")
  registry.register(tool, registry_test_executor)
  // Lenient register is deliberate hot-replacement: same name overwrites.
  registry.register(tool, registry_test_executor)
  assert_eq(registry.list_tools().length(), 1)
  // Strict registration fails fast on the same name (M0-T06-B parity: a
  // name collision is never silently resolved by last-wins).
  let rejected = Ok(registry.register_strict(tool, registry_test_executor)) catch {
    e => Err(e)
  }
  match rejected {
    Err(@error.RuntimeError::ToolAlreadyRegistered(_)) => ()
    _ => fail("expected RuntimeError::ToolAlreadyRegistered")
  }
  // Strict registration of a fresh name succeeds.
  registry.register_strict(registry_test_tool("fresh"), registry_test_executor)
  assert_eq(registry.list_tools().length(), 2)
}
