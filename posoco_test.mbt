///|
/// posoco_test.mbt — Blackbox tests against the public API.
///
/// Types imported via `@posoco` prefix. Covers public helpers,
/// type constructors, and lifecycle scenarios with mock ports.

///|
/// ——— Mock implementations (blackbox, implementing pub(open) traits) ———
struct MockModelPort {
  responses : Array[@posoco.ModelResponse]
  mut index : Int
}

///|
impl @posoco.ModelPort for MockModelPort with chat(
  self,
  _messages,
  _tools,
  _options,
) {
  if self.index < self.responses.length() {
    let resp = self.responses[self.index]
    self.index = self.index + 1
    Ok(resp)
  } else {
    Err(@posoco.ModelError::Transport("no more responses"))
  }
}

///|
struct MockToolProvider {
  tools : Array[@posoco.ToolDef]
}

///|
impl @posoco.ToolProvider for MockToolProvider with list_tools(self) {
  self.tools
}

///|
struct MockToolRuntime {
  results : Map[String, Result[@posoco.ToolResult, @posoco.RuntimeError]]
}

///|
impl @posoco.ToolRuntime for MockToolRuntime with execute(self, name, _call) {
  if self.results.contains(name) {
    self.results[name]
  } else {
    Err(@posoco.RuntimeError::InvocationFailed("tool not found"))
  }
}

///|
struct MockSessionStore {
  store : Map[String, @posoco.Session]
}

///|
impl @posoco.SessionStore for MockSessionStore with load(self, id) {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok(@posoco.Session::{ messages: [], metadata: Map::from_array([]) })
  }
}

///|
impl @posoco.SessionStore for MockSessionStore with save(self, id, session) {
  self.store[id] = session
  Ok(())
}

///|
struct MockObserver {
  events : Array[@posoco.TurnEvent]
}

///|
impl @posoco.Observer for MockObserver with on_event(self, event) {
  self.events.push(event)
}

///|
/// ——— Helpers ———
fn make_config() -> @posoco.AgentConfig {
  @posoco.AgentConfig::{
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
  @posoco.Message::{
    role: @posoco.Role::User,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
fn stop_response(text : String) -> @posoco.ModelResponse {
  @posoco.ModelResponse::{
    message: @posoco.Message::{
      role: @posoco.Role::Assistant,
      content: [@posoco.Content::Text(text)],
      tool_calls: [],
      tool_call_id: None,
      name: Some("assistant"),
    },
    tool_calls: [],
    finish_reason: @posoco.FinishReason::Stop,
    usage: None,
    reasoning_summary: None,
  }
}

///|
/// ——— Test b1: Simple turn via blackbox ———
test "b1_simple_turn_no_tools" {
  let model = MockModelPort::{ responses: [stop_response("hi")], index: 0 }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = @posoco.Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    @posoco.NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("hello"), "session_b1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.final_session_id, "session_b1")
      assert_true(turn_result.tool_results.is_empty())
    }
    Err(_) => fail("expected Ok")
  }
}

///|
/// ——— Test b2: NoopCompressor public API ———
test "b2_noop_compressor" {
  let comp = @posoco.NoopCompressor::{  }
  let ctx = @posoco.CompressContext::{
    session_id: "x",
    model_context_window: None,
  }
  let action = comp.compress([], ctx)
  assert_true(action is @posoco.CompressAction::None)
}

///|
/// ——— Test b3: NoopHook passes through ———
test "b3_noop_hook" {
  let hook = @posoco.NoopHook::{  }
  let result = hook.on_stage(@posoco.Stage::BeforeTurn)
  match result {
    Ok(@posoco.Stage::BeforeTurn) => ()
    _ => fail("expected BeforeTurn stage")
  }
}

///|
/// ——— Test b4: HookChain with two hooks ———
test "b4_hook_chain" {
  let h1 = @posoco.NoopHook::{  }
  let h2 = @posoco.NoopHook::{  }
  let chain = @posoco.HookChain::{ hooks: [h1, h2] }
  let result = chain.on_stage(@posoco.Stage::BeforeTurn)
  assert_true(result is Ok(_))
}

///|
/// ——— Test b5: ToolCall and ToolResult message building ———
test "b5_build_tool_result_message" {
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
  assert_true(msg.role == @posoco.Role::Tool)
  assert_true(msg.tool_call_id == Some("ct_1"))
  assert_true(msg.name == Some("tool_a"))
}

///|
/// ——— Test b6: build_error_message ———
test "b6_build_error_message" {
  let call = @posoco.ToolCall::{
    id: "ct_2",
    name: "tool_b",
    arguments: Json::null(),
  }
  let err = @posoco.RuntimeError::InvocationFailed("fail")
  let msg = @posoco.build_error_message(call, err)
  assert_true(msg.role == @posoco.Role::Tool)
  assert_true(msg.tool_call_id == Some("ct_2"))
}

///|
/// ——— Test b7: AgentError display ———
test "b7_agent_error_display" {
  let model_err = @posoco.AgentError::Model(
    @posoco.ModelError::Transport("nope"),
  )
  let s = model_err.to_string()
  assert_true(s.length() > 0)
  assert_true(s.contains("Transport"))
}

///|
/// ——— Test b8: TurnEvent lifecycle ———
test "b8_turn_event_lifecycle" {
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0 }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = @posoco.Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    @posoco.NoopCompressor::{  },
    None,
    config,
  )
  let _ = agent.run_turn(user_msg("event test"), "session_b8")

  let events = observer.events
  assert_true(events.length() >= 2)
  match events[0] {
    @posoco.TurnEvent::TurnStarted => ()
    _ => fail("first event should be TurnStarted")
  }
  match events[events.length() - 1] {
    @posoco.TurnEvent::TurnCompleted => ()
    _ => fail("last event should be TurnCompleted")
  }
}

///|
/// ——— Test b9: Model error aborts via blackbox ———
test "b9_model_error_aborts" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = @posoco.Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    @posoco.NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("boom"), "session_b9")

  match result {
    Err(@posoco.AgentError::Model(_)) => ()
    _ => fail("expected Model error")
  }
}
