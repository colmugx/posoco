///|
/// posoco_wbtest.mbt — Whitebox tests with mock implementations.
///
/// Mocks implement port traits for testing Agent::run_turn.
/// 12 test cases cover the full Agent lifecycle.

///|
/// ——— Mock Implementations ———
struct MockModelPort {
  responses : Array[ModelResponse]
  mut index : Int
}

///|
impl ModelPort for MockModelPort with chat(self, _messages, _tools, _options) {
  if self.index < self.responses.length() {
    let resp = self.responses[self.index]
    self.index = self.index + 1
    Ok(resp)
  } else {
    Err(ModelError::Transport("no more responses"))
  }
}

///|
struct MockToolProvider {
  tools : Array[ToolDef]
}

///|
impl ToolProvider for MockToolProvider with list_tools(self) {
  self.tools
}

///|
struct MockToolRuntime {
  results : Map[String, Result[ToolResult, RuntimeError]]
}

///|
impl ToolRuntime for MockToolRuntime with execute(self, name, _call) {
  if self.results.contains(name) {
    self.results[name]
  } else {
    Err(RuntimeError::InvocationFailed("tool not found"))
  }
}

///|
struct MockSessionStore {
  store : Map[String, Session]
}

///|
impl SessionStore for MockSessionStore with load(self, id) {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok(Session::{ messages: [], metadata: Map::from_array([]) })
  }
}

///|
impl SessionStore for MockSessionStore with save(self, id, session) {
  self.store[id] = session
  Ok(())
}

///|
struct MockObserver {
  events : Array[TurnEvent]
}

///|
impl Observer for MockObserver with on_event(self, event) {
  self.events.push(event)
}

///|
/// ——— Custom PipelineHook implementations ———
struct AbortHook {}

///|
impl PipelineHook for AbortHook with on_stage(_self, stage) {
  match stage {
    Stage::BeforeTool(_) => Err(HookError::Aborted("blocked by policy"))
    _ => Ok(stage)
  }
}

///|
struct LogHook {
  seen : Array[Stage]
}

///|
impl PipelineHook for LogHook with on_stage(self, stage) {
  self.seen.push(stage)
  Ok(stage)
}

///|
/// ——— Custom Compressor implementations ———
struct NewThreadCompressor {}

///|
impl Compressor for NewThreadCompressor with compress(_self, messages, _ctx) {
  CompressAction::NewThread(
    messages~,
    new_session_id="session_2",
    messages_before=messages.length(),
    messages_after=messages.length(),
  )
}

///|
struct ReplaceCompressor {}

///|
impl Compressor for ReplaceCompressor with compress(_self, messages, _ctx) {
  if messages.length() > 0 {
    CompressAction::Replace([messages[0]])
  } else {
    CompressAction::Replace([])
  }
}

///|
/// ——— Helper functions ———
fn make_config() -> AgentConfig {
  AgentConfig::{
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    thinking: None,
    model_context_window: None,
  }
}

///|
fn user_msg(text : String) -> Message {
  Message::{
    role: Role::User,
    content: [Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
fn assistant_msg(text : String) -> Message {
  Message::{
    role: Role::Assistant,
    content: [Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: Some("assistant"),
  }
}

///|
fn stop_response(text : String) -> ModelResponse {
  ModelResponse::{
    message: assistant_msg(text),
    tool_calls: [],
    finish_reason: FinishReason::Stop,
    usage: None,
    reasoning_summary: None,
  }
}

///|
fn tool_response(tool_calls : Array[ToolCall]) -> ModelResponse {
  ModelResponse::{
    message: Message::{
      role: Role::Assistant,
      content: [],
      tool_calls,
      tool_call_id: None,
      name: None,
    },
    tool_calls,
    finish_reason: FinishReason::ToolCalls,
    usage: None,
    reasoning_summary: None,
  }
}

///|
fn make_tool_call(id : String, name : String) -> ToolCall {
  ToolCall::{ id, name, arguments: Json::null() }
}

///|
/// ——— Test 1: Simple turn without tools ———
test "simple_turn_no_tools" {
  let model = MockModelPort::{
    responses: [stop_response("hi there")],
    index: 0,
  }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.final_session_id, "session_1")
      assert_true(turn_result.tool_results.is_empty())
    }
    Err(e) => fail("expected Ok, got: \{e}")
  }
}

///|
/// ——— Test 2: Turn with a single tool call ———
test "turn_with_single_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      ToolDef::{
        name: "bash",
        description: "run a cmd",
        input_schema: Json::null(),
      },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      (
        "bash",
        Ok(ToolResult::{ content: "ok", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("run ls"), "session_1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.tool_results.length(), 1)
      assert_eq(turn_result.tool_results[0].content, "ok")
    }
    Err(e) => fail("expected Ok, got: \{e}")
  }
}

///|
/// ——— Test 3: Tool failure is non-fatal ———
test "tool_failure_non_fatal" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("error handled")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      ToolDef::{ name: "bash", description: "", input_schema: Json::null() },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      ("bash", Err(RuntimeError::InvocationFailed("boom"))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("do it"), "session_1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.tool_results.length(), 1)
      assert_true(turn_result.tool_results[0].is_error)
    }
    Err(_) => fail("tool failure should not abort the turn")
  }
}

///|
/// ——— Test 4: Model error aborts the turn ———
test "model_error_aborts_turn" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("ping"), "session_1")

  match result {
    Err(AgentError::Model(_)) => ()
    _ => fail("expected Model error")
  }
}

///|
/// ——— Test 5: PipelineHook aborts before tool ———
test "hook_aborts_before_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("should not reach")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      ToolDef::{ name: "bash", description: "", input_schema: Json::null() },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      (
        "bash",
        Ok(ToolResult::{ content: "ok", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()
  let abort_hook = AbortHook::{  }

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    Some(abort_hook),
    config,
  )
  let result = agent.run_turn(user_msg("danger"), "session_1")

  match result {
    Err(AgentError::HookAborted(msg)) =>
      assert_true(msg.contains("blocked by policy"))
    _ => fail("expected HookAborted error")
  }
}

///|
/// ——— Test 6: Compression creates a new thread ———
test "compression_new_thread" {
  let model = MockModelPort::{
    responses: [stop_response("compressed")],
    index: 0,
  }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let compressor = NewThreadCompressor::{  }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    compressor,
    None,
    config,
  )
  let result = agent.run_turn(user_msg("long context"), "session_1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.final_session_id, "session_2")

      let mut has_redirect = false
      for event in observer.events {
        if event is SessionRedirect(..) {
          has_redirect = true
        }
      }
      assert_true(has_redirect)

      if store.store.contains("session_2") {
        ignore(store.store["session_2"])
      } else {
        fail("new session not saved in store")
      }
    }
    Err(e) => fail("expected Ok, got: \{e}")
  }
}

///|
/// ——— Test 7: Compression replaces messages ———
test "compression_replace" {
  let model = MockModelPort::{
    responses: [stop_response("replaced")],
    index: 0,
  }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{
    store: Map::from_array([
      (
        "session_1",
        Session::{
          messages: [user_msg("old msg")],
          metadata: Map::from_array([]),
        },
      ),
    ]),
  }
  let observer = MockObserver::{ events: [] }
  let compressor = ReplaceCompressor::{  }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    compressor,
    None,
    config,
  )
  let result = agent.run_turn(user_msg("new msg"), "session_1")

  match result {
    Ok(turn_result) => {
      assert_eq(turn_result.final_session_id, "session_1")

      if store.store.contains("session_1") {
        let session = store.store["session_1"]
        assert_true(session.messages.length() >= 2)
      } else {
        fail("session not saved")
      }
    }
    Err(e) => fail("expected Ok, got: \{e}")
  }
}

///|
/// ——— Test 8: Tool loop exceeded ———
test "tool_loop_exceeded" {
  let tc = make_tool_call("call_1", "bash")
  let tool_resp = tool_response([tc])
  let model = MockModelPort::{
    responses: [tool_resp, tool_resp, tool_resp],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      ToolDef::{ name: "bash", description: "", input_schema: Json::null() },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      (
        "bash",
        Ok(ToolResult::{ content: "ok", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = AgentConfig::{
    max_tool_rounds: 2,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    thinking: None,
    model_context_window: None,
  }

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("loop"), "session_1")

  match result {
    Err(AgentError::ToolLoopExceeded) => ()
    _ => fail("expected ToolLoopExceeded")
  }
}

///|
/// ——— Test 9: HookChain composition ———
test "hook_chain_composition" {
  let hook1 = LogHook::{ seen: [] }
  let hook2 = NoopHook::{  }
  let chain = HookChain::{ hooks: [hook1, hook2] }

  match chain.on_stage(Stage::BeforeTurn) {
    Ok(Stage::BeforeTurn) => assert_eq(hook1.seen.length(), 1)
    _ => fail("expected BeforeTurn to pass through")
  }

  let tc = ToolCall::{ id: "call_a", name: "test", arguments: Json::null() }
  match chain.on_stage(Stage::BeforeTool(tc)) {
    Ok(Stage::BeforeTool(_)) => assert_eq(hook1.seen.length(), 2)
    _ => fail("expected BeforeTool to pass through")
  }

  let abort = AbortHook::{  }
  let fail_chain = HookChain::{ hooks: [abort] }
  let tc2 = ToolCall::{ id: "call_b", name: "fail", arguments: Json::null() }
  match fail_chain.on_stage(Stage::BeforeTool(tc2)) {
    Err(HookError::Aborted(msg)) => assert_true(msg.contains("blocked"))
    _ => fail("expected abort")
  }
}

///|
/// ——— Test 10: NoopCompressor always returns None ———
test "noop_compressor_always_none" {
  let comp = NoopCompressor::{  }
  let ctx = CompressContext::{ session_id: "test", model_context_window: None }

  let action1 = comp.compress([], ctx)
  assert_true(action1 is CompressAction::None)

  let msgs : Array[Message] = [user_msg("a"), user_msg("b")]
  let ctx2 = CompressContext::{
    session_id: "test2",
    model_context_window: None,
  }
  let action2 = comp.compress(msgs, ctx2)
  assert_true(action2 is CompressAction::None)
}

///|
/// ——— Test 11: Observer event sequence ———
test "observer_event_sequence" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("sequence done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      ToolDef::{ name: "bash", description: "", input_schema: Json::null() },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      (
        "bash",
        Ok(ToolResult::{ content: "seq", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("sequence"), "session_1")
  assert_true(result is Ok(_))

  let events = observer.events
  assert_true(events.length() >= 4)

  match events[0] {
    TurnStarted => ()
    _ => fail("first event should be TurnStarted")
  }

  match events[events.length() - 1] {
    TurnCompleted => ()
    _ => fail("last event should be TurnCompleted")
  }

  let mut has_pending = false
  let mut has_result = false
  for event in events {
    if event is ToolCallPending(_) {
      has_pending = true
    }
    if event is ToolCallResult(..) {
      has_result = true
    }
  }
  assert_true(has_pending)
  assert_true(has_result)
}

///|
/// ——— Test 12: Session persistence ———
test "session_persistence" {
  let model = MockModelPort::{ responses: [stop_response("saved")], index: 0 }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    None,
    config,
  )
  let result = agent.run_turn(user_msg("persist me"), "session_1")

  match result {
    Ok(turn_result) => {
      if store.store.contains("session_1") {
        let session = store.store["session_1"]
        assert_true(session.messages.length() >= 2)
        assert_true(session.messages[0].role == Role::User)
        assert_true(
          session.messages[session.messages.length() - 1].role ==
          Role::Assistant,
        )
      } else {
        fail("session not saved in store")
      }
      assert_eq(turn_result.final_session_id, "session_1")
    }
    Err(e) => fail("expected Ok, got: \{e}")
  }
}
