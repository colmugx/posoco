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
    resp
  } else {
    raise Transport("no more responses")
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
    match self.results[name] {
      Ok(r) => r
      Err(e) => raise e
    }
  } else {
    raise InvocationFailed("tool not found")
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
    Ok({ messages: [], metadata: Map::from_array([]) })
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
    BeforeTool(_) => Err(Aborted("blocked by policy"))
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
  NewThread(
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
    Replace([messages[0]])
  } else {
    Replace([])
  }
}

///|
/// ——— Helper functions ———
fn make_config() -> AgentConfig {
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
fn user_msg(text : String) -> Message {
  {
    role: User,
    content: [Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
fn assistant_msg(text : String) -> Message {
  {
    role: Assistant,
    content: [Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: Some("assistant"),
  }
}

///|
fn stop_response(text : String) -> ModelResponse {
  {
    message: assistant_msg(text),
    tool_calls: [],
    finish_reason: Stop,
    usage: None,
    reasoning_summary: None,
  }
}

///|
fn tool_response(tool_calls : Array[ToolCall]) -> ModelResponse {
  {
    message: {
      role: Assistant,
      content: [],
      tool_calls,
      tool_call_id: None,
      name: None,
    },
    tool_calls,
    finish_reason: ToolCalls,
    usage: None,
    reasoning_summary: None,
  }
}

///|
fn make_tool_call(id : String, name : String) -> ToolCall {
  { id, name, arguments: Json::null() }
}

///|
/// ——— Test 1: Simple turn without tools ———
async test "simple_turn_no_tools" {
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_true(result.tool_results.is_empty())
}

///|
/// ——— Test 2: Turn with a single tool call ———
async test "turn_with_single_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      { name: "bash", description: "run a cmd", input_schema: Json::null() },
    ],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      ("bash", Ok({ content: "ok", structured: None, is_error: false })),
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("run ls"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(result.tool_results[0].content, "ok")
}

///|
/// ——— Test 3: Tool failure is non-fatal ———
async test "tool_failure_non_fatal" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("error handled")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [{ name: "bash", description: "", input_schema: Json::null() }],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([("bash", Err(InvocationFailed("boom")))]),
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("do it"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_error)
}

///|
/// ——— Test 4: Model error aborts the turn ———
async test "model_error_aborts_turn" {
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
    None,
    config,
  )
  match
    (Ok(agent.run_turn(user_msg("ping"), "session_1")) catch { e => Err(e) }) {
    Err(Model(_)) => ()
    _ => fail("expected Model error")
  }
}

///|
/// ——— Test 5: PipelineHook aborts before tool ———
async test "hook_aborts_before_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("should not reach")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [{ name: "bash", description: "", input_schema: Json::null() }],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      ("bash", Ok({ content: "ok", structured: None, is_error: false })),
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
    None,
    config,
  )
  match
    (Ok(agent.run_turn(user_msg("danger"), "session_1")) catch { e => Err(e) }) {
    Err(HookAborted(msg)) => assert_true(msg.contains("blocked by policy"))
    _ => fail("expected HookAborted error")
  }
}

///|
/// ——— Test 6: Compression creates a new thread ———
async test "compression_new_thread" {
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("long context"), "session_1")
  assert_eq(result.final_session_id, "session_2")

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

///|
/// ——— Test 7: Compression replaces messages ———
async test "compression_replace" {
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
        { messages: [user_msg("old msg")], metadata: Map::from_array([]) },
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("new msg"), "session_1")
  assert_eq(result.final_session_id, "session_1")

  if store.store.contains("session_1") {
    let session = store.store["session_1"]
    assert_true(session.messages.length() >= 2)
  } else {
    fail("session not saved")
  }
}

///|
/// ——— Test 8: Tool loop exceeded ———
async test "tool_loop_exceeded" {
  let tc = make_tool_call("call_1", "bash")
  let tool_resp = tool_response([tc])
  let model = MockModelPort::{
    responses: [tool_resp, tool_resp, tool_resp],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [{ name: "bash", description: "", input_schema: Json::null() }],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      ("bash", Ok({ content: "ok", structured: None, is_error: false })),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = {
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
    None,
    config,
  )
  match
    (Ok(agent.run_turn(user_msg("loop"), "session_1")) catch { e => Err(e) }) {
    Err(ToolLoopExceeded) => ()
    _ => fail("expected ToolLoopExceeded")
  }
}

///|
/// ——— Test 9: HookChain composition ———
async test "hook_chain_composition" {
  let hook1 = LogHook::{ seen: [] }
  let hook2 = NoopHook::{  }
  let chain = HookChain::{ hooks: [hook1, hook2] }

  match chain.on_stage(BeforeTurn) {
    Ok(BeforeTurn) => assert_eq(hook1.seen.length(), 1)
    _ => fail("expected BeforeTurn to pass through")
  }

  let tc = { id: "call_a", name: "test", arguments: Json::null() }
  match chain.on_stage(BeforeTool(tc)) {
    Ok(BeforeTool(_)) => assert_eq(hook1.seen.length(), 2)
    _ => fail("expected BeforeTool to pass through")
  }

  let abort = AbortHook::{  }
  let fail_chain = HookChain::{ hooks: [abort] }
  let tc2 = { id: "call_b", name: "fail", arguments: Json::null() }
  match fail_chain.on_stage(BeforeTool(tc2)) {
    Err(Aborted(msg)) => assert_true(msg.contains("blocked"))
    _ => fail("expected abort")
  }
}

///|
/// ——— Test 10: NoopCompressor always returns None ———
async test "noop_compressor_always_none" {
  let comp = NoopCompressor::{  }
  let ctx = { session_id: "test", model_context_window: None }

  let action1 = comp.compress([], ctx)
  assert_true(action1 is None)

  let msgs : Array[Message] = [user_msg("a"), user_msg("b")]
  let ctx2 = { session_id: "test2", model_context_window: None }
  let action2 = comp.compress(msgs, ctx2)
  assert_true(action2 is None)
}

///|
/// ——— Test 11: Observer event sequence ———
async test "observer_event_sequence" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("sequence done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [{ name: "bash", description: "", input_schema: Json::null() }],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      ("bash", Ok({ content: "seq", structured: None, is_error: false })),
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
    None,
    config,
  )
  let _ = agent.run_turn(user_msg("sequence"), "session_1")

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
async test "session_persistence" {
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
    None,
    config,
  )
  let result = agent.run_turn(user_msg("persist me"), "session_1")
  if store.store.contains("session_1") {
    let session = store.store["session_1"]
    assert_true(session.messages.length() >= 2)
    assert_true(session.messages[0].role == User)
    assert_true(
      session.messages[session.messages.length() - 1].role == Assistant,
    )
  } else {
    fail("session not saved in store")
  }
  assert_eq(result.final_session_id, "session_1")
}

///|
/// RewriteModelHook — rewrites BeforeModel messages with a system prefix
struct RewriteModelHook {}

///|
impl PipelineHook for RewriteModelHook with on_stage(_self, stage) {
  match stage {
    BeforeModel(msgs) => {
      let system_msg = {
        role: System,
        content: [Text("SYSTEM: rewritten")],
        tool_calls: [],
        tool_call_id: None,
        name: None,
      }
      let new_msgs = [system_msg]
      for m in msgs {
        new_msgs.push(m)
      }
      Ok(BeforeModel(new_msgs))
    }
    _ => Ok(stage)
  }
}

///|
/// Test: BeforeModel hook can modify messages (Phase 0 fix verification)
async test "hook_rewrites_before_model_messages" {
  let model = MockModelPort::{
    responses: [stop_response("response after rewrite")],
    index: 0,
  }
  let tools = MockToolProvider::{ tools: [] }
  let runtime = MockToolRuntime::{ results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let rewriter = RewriteModelHook::{  }
  let config = make_config()
  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    Some(rewriter),
    None,
    config,
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let session = store.store["session_1"]
  assert_true(session.messages.length() >= 2)
  assert_true(session.messages[0].role == System)
}

///|
/// DeferToolHook — returns Deferred for tools needing approval
struct DeferToolHook {}

///|
impl PipelineHook for DeferToolHook with on_stage(_self, stage) {
  match stage {
    BeforeTool(call) if call.name == "restricted" =>
      Err(Deferred(reason="needs admin approval"))
    _ => Ok(stage)
  }
}

///|
/// Test: Deferred hook skips tool execution and notifies LLM
async test "hook_deferred_skips_execution" {
  let tc = make_tool_call("call_1", "restricted")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("approved")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [{ name: "restricted", description: "", input_schema: Json::null() }],
  }
  let runtime = MockToolRuntime::{
    results: Map::from_array([
      (
        "restricted",
        Ok({ content: "executed", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let hook = DeferToolHook::{  }
  let config = make_config()
  let agent = Agent::new(
    model,
    tools,
    runtime,
    store,
    observer,
    NoopCompressor::{  },
    Some(hook),
    None,
    config,
  )
  let result = agent.run_turn(user_msg("use restricted"), "session_1")
  // Turn should succeed (not abort)
  assert_eq(result.final_session_id, "session_1")
  // Should have ToolCallDeferred event
  let mut deferred_seen = false
  for e in observer.events {
    match e {
      ToolCallDeferred(..) => deferred_seen = true
      _ => ()
    }
  }
  assert_true(deferred_seen)
  // Deferred tool should exit with is_error=true (LLM must respond to user)
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_error)
  assert_true(result.tool_results[0].content.contains("rejected"))
}
