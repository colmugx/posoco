///|
/// Blackbox tests against the public API. Mocks live in this file.
struct MockModelPort {
  responses : Array[@posoco.ModelResponse]
  mut index : Int
}

///|
impl @posoco.ModelPort for MockModelPort with fn chat(
  self,
  _messages,
  _tools,
  _options,
) {
  if self.index < self.responses.length() {
    let resp = self.responses[self.index]
    self.index = self.index + 1
    resp
  } else {
    raise Transport("no more responses")
  }
}

///|
/// MockToolProvider — implements the unified ToolProvider trait.
struct MockToolProvider {
  tools : Array[@posoco.ToolDef]
  results : Map[String, Result[@posoco.ToolResult, @posoco.RuntimeError]]
}

///|
impl @posoco.ToolProvider for MockToolProvider with fn list_tools(self) {
  self.tools
}

///|
impl @posoco.ToolProvider for MockToolProvider with fn execute(
  self,
  name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  match self.results.get(name) {
    Some(Ok(r)) => r
    Some(Err(e)) => raise e
    None => raise @posoco.InvocationFailed("tool not found: \{name}")
  }
}

///|
struct MockSessionStore {
  store : Map[String, @posoco.Session]
}

///|
impl @posoco.SessionStore for MockSessionStore with fn load(self, id) {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok({ messages: [], metadata: Map::from_array([]) })
  }
}

///|
impl @posoco.SessionStore for MockSessionStore with fn save(self, id, session) {
  self.store[id] = session
  Ok(())
}

///|
struct MockObserver {
  events : Array[@posoco.TurnEvent]
}

///|
impl @posoco.Observer for MockObserver with fn on_event(self, event) {
  self.events.push(event)
}

///|
fn make_config() -> @posoco.AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    thinking: None,
    model_context_window: None,
  }
}

///|
fn user_msg(text : String) -> @posoco.Message {
  {
    role: User,
    content: [Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
fn stop_response(text : String) -> @posoco.ModelResponse {
  {
    message: {
      role: Assistant,
      content: [Text(text)],
      tool_calls: [],
      tool_call_id: None,
      name: Some("assistant"),
    },
    tool_calls: [],
    finish_reason: Stop,
    usage: None,
    reasoning_summary: None,
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

  let agent = @posoco.Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("hello"), "session_b1")
  assert_eq(result.final_session_id, "session_b1")
  assert_true(result.tool_results.is_empty())
}

///|
async test "b2_noop_compressor" {
  let comp = @posoco.NoopCompressor::{  }
  let ctx = @posoco.CompressContext::{
    session_id: "x",
    model_context_window: None,
  }
  let action = comp.compress([], ctx)
  assert_true(action is None)
}

///|
async test "b3_noop_hook" {
  let hook = @posoco.NoopHook::{  }
  let result = hook.on_stage(BeforeTurn)
  match result {
    Ok(BeforeTurn) => ()
    _ => fail("expected BeforeTurn stage")
  }
}

///|
async test "b4_hook_chain" {
  let h1 = @posoco.NoopHook::{  }
  let h2 = @posoco.NoopHook::{  }
  let chain = @posoco.HookChain::{ hooks: [h1, h2] }
  let result = chain.on_stage(BeforeTurn)
  assert_true(result is Ok(_))
}

///|
async test "b5_build_tool_result_message" {
  let call = @posoco.ToolCall::{
    id: "ct_1",
    name: "tool_a",
    arguments: Json::null(),
  }
  let result = @posoco.ToolResult::{
    content: "done",
    structured: None,
    is_error: false,
  }
  let msg = @posoco.build_tool_result_message(call, result)
  assert_true(msg.role == Tool)
  assert_true(msg.tool_call_id == Some("ct_1"))
  assert_true(msg.name == Some("tool_a"))
}

///|
async test "b6_build_error_message" {
  let call = @posoco.ToolCall::{
    id: "ct_2",
    name: "tool_b",
    arguments: Json::null(),
  }
  let err = @posoco.InvocationFailed("fail")
  let msg = @posoco.build_error_message(call, err)
  assert_true(msg.role == Tool)
  assert_true(msg.tool_call_id == Some("ct_2"))
}

///|
async test "b7_agent_error_display" {
  let model_err = @posoco.Model("nope")
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

  let agent = @posoco.Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn(user_msg("event test"), "session_b8")

  let events = observer.events
  assert_true(events.length() >= 2)
  match events[0] {
    TurnStarted => ()
    _ => fail("first event should be TurnStarted")
  }
  match events[events.length() - 1] {
    TurnCompleted => ()
    _ => fail("last event should be TurnCompleted")
  }
}

///|
async test "b9_model_error_aborts" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = @posoco.Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("boom"), "session_b9")) catch { e => Err(e) }) {
    Err(Model(_)) => ()
    _ => fail("expected Model error")
  }
}
