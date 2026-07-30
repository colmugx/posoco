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
  _messages : Array[@kernel.Message],
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
  self,
  _messages : Array[@kernel.Message],
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
    { messages: [], metadata: Map::from_array([]) }
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
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
    model: None,
  }
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
  MockToolProvider::{ tools: [], results: Map::from_array([]) }
}

///|
async test "b1_simple_turn_no_tools" {
  let model = MockModelPort::{ responses: [stop_response("hi")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
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
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
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
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
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
