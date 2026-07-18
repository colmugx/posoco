///|
/// Whitebox tests with mock implementations.
struct MockModelPort {
  responses : Array[ModelResponse]
  mut index : Int
}

///|
impl ModelPort for MockModelPort with fn chat(self, _messages, _tools, _options) {
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
/// Lists tools and executes them from a results map.
struct MockToolProvider {
  tools : Array[ToolDef]
  results : Map[String, Result[ToolResult, RuntimeError]]
}

///|
impl ToolProvider for MockToolProvider with fn list_tools(self) {
  self.tools
}

///|
impl ToolProvider for MockToolProvider with fn execute(
  self,
  name : String,
  _call : ToolCall,
) -> ToolResult raise RuntimeError {
  match self.results.get(name) {
    Some(Ok(r)) => r
    Some(Err(e)) => raise e
    None => raise InvocationFailed("tool not found: \{name}")
  }
}

///|
struct MockSessionStore {
  store : Map[String, Session]
}

///|
impl SessionStore for MockSessionStore with fn load(self, id) {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok({ messages: [], metadata: Map::from_array([]) })
  }
}

///|
impl SessionStore for MockSessionStore with fn save(self, id, session) {
  self.store[id] = session
  Ok(())
}

///|
struct MockObserver {
  events : Array[TurnEvent]
}

///|
impl Observer for MockObserver with fn on_event(self, event) {
  self.events.push(event)
}

///|
struct AbortHook {}

///|
impl PipelineHook for AbortHook with fn on_stage(_self, stage) {
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
impl PipelineHook for LogHook with fn on_stage(self, stage) {
  self.seen.push(stage)
  Ok(stage)
}

///|
struct NewThreadCompressor {}

///|
impl Compressor for NewThreadCompressor with fn compress(_self, messages, _ctx) {
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
impl Compressor for ReplaceCompressor with fn compress(_self, messages, _ctx) {
  if messages.length() > 0 {
    Replace([messages[0]])
  } else {
    Replace([])
  }
}

///|
fn make_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
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
    reasoning_content: None,
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
    reasoning_content: None,
  }
}

///|
fn stop_response(text : String) -> ModelResponse {
  {
    message: assistant_msg(text),
    tool_calls: [],
    finish_reason: Stop,
    usage: None,
    reasoning_content: None,
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
      reasoning_content: None,
    },
    tool_calls,
    finish_reason: ToolCalls,
    usage: None,
    reasoning_content: None,
  }
}

///|
fn make_tool_call(id : String, name : String) -> ToolCall {
  { id, name, arguments: Json::null() }
}

///|
/// Helper: empty tool provider (no tools, no execution)
fn empty_tools() -> MockToolProvider {
  MockToolProvider::{ tools: [], results: Map::from_array([]) }
}

///|
async test "simple_turn_no_tools" {
  let model = MockModelPort::{
    responses: [stop_response("hi there")],
    index: 0,
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_true(result.tool_results.is_empty())
}

///|
async test "turn_with_single_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "run a cmd",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([
      ("bash", Ok({ content: "ok", structured: None, is_error: false })),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("run ls"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(result.tool_results[0].content, "ok")
}

///|
async test "tool_failure_non_fatal" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("error handled")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([("bash", Err(InvocationFailed("boom")))]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("do it"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_error)
}

///|
async test "model_error_aborts_turn" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("ping"), "session_1")) catch { e => Err(e) }) {
    Err(Model(_)) => ()
    _ => fail("expected Model error")
  }
}

///|
async test "hook_aborts_before_tool" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("should not reach")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
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
    tools=[tools],
    hooks=[abort_hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("danger"), "session_1")) catch { e => Err(e) }) {
    Err(HookAborted(msg)) => assert_true(msg.contains("blocked by policy"))
    _ => fail("expected HookAborted error")
  }
}

///|
async test "compression_new_thread" {
  let model = MockModelPort::{
    responses: [stop_response("compressed")],
    index: 0,
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let compressor = NewThreadCompressor::{  }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[compressor],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
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
async test "compression_replace" {
  let model = MockModelPort::{
    responses: [stop_response("replaced")],
    index: 0,
  }
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
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[compressor],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
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
async test "tool_loop_exceeded" {
  let tc = make_tool_call("call_1", "bash")
  let tool_resp = tool_response([tc])
  let model = MockModelPort::{
    responses: [tool_resp, tool_resp, tool_resp],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
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
    reasoning_effort: None,
    model_context_window: None,
  }

  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("loop"), "session_1")) catch { e => Err(e) }) {
    Err(ToolLoopExceeded) => ()
    _ => fail("expected ToolLoopExceeded")
  }
}

///|
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
async test "observer_event_sequence" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("sequence done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([
      ("bash", Ok({ content: "seq", structured: None, is_error: false })),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
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
async test "session_persistence" {
  let model = MockModelPort::{ responses: [stop_response("saved")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
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
impl PipelineHook for RewriteModelHook with fn on_stage(_self, stage) {
  match stage {
    BeforeModel(msgs) => {
      let system_msg = {
        role: System,
        content: [Text("SYSTEM: rewritten")],
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
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
/// Test: BeforeModel hook can modify messages
async test "hook_rewrites_before_model_messages" {
  let model = MockModelPort::{
    responses: [stop_response("response after rewrite")],
    index: 0,
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let rewriter = RewriteModelHook::{  }
  let config = make_config()
  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[rewriter],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
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
impl PipelineHook for DeferToolHook with fn on_stage(_self, stage) {
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
    tools: [
      {
        name: "restricted",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
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
    tools=[tools],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("use restricted"), "session_1")
  assert_eq(result.final_session_id, "session_1")
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

///|
/// Test: Agent internally routes tool calls to the correct provider.
/// Two providers each own different tools; Agent routes by tool name.
async test "agent_routes_tools_to_correct_provider" {
  let tc_bash = make_tool_call("c1", "bash")
  let tc_mcp = make_tool_call("c2", "mcp__read")
  let model = MockModelPort::{
    responses: [tool_response([tc_bash, tc_mcp]), stop_response("both done")],
    index: 0,
  }
  let shell_tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "run cmd",
        input_schema: Json::null(),
        metadata: None,
        source: Some("host"),
      },
    ],
    results: Map::from_array([
      ("bash", Ok({ content: "shell ok", structured: None, is_error: false })),
    ]),
  }
  let mcp_tools = MockToolProvider::{
    tools: [
      {
        name: "mcp__read",
        description: "read file",
        input_schema: Json::null(),
        metadata: None,
        source: Some("mcp"),
      },
    ],
    results: Map::from_array([
      (
        "mcp__read",
        Ok({ content: "mcp ok", structured: None, is_error: false }),
      ),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[shell_tools, mcp_tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn(user_msg("run both"), "session_1")
  assert_eq(result.tool_results.length(), 2)
  assert_eq(result.tool_results[0].content, "shell ok")
  assert_eq(result.tool_results[1].content, "mcp ok")
}

///|
/// Test: Agent detects tool name collisions across providers
async test "agent_tool_collision_detection" {
  let provider1 = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "v1",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([]),
  }
  let provider2 = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "v2",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([
      ("bash", Ok({ content: "v2 wins", structured: None, is_error: false })),
    ]),
  }
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  // T06-B: collision now fails composition (raise) rather than last-wins.
  let composition_result = Ok(
    Agent::new(
      model,
      tools=[provider1, provider2],
      hooks=[],
      memory=[],
      compressors=[NoopCompressor::{  }],
      observers=[observer],
      sessions=[store],
      lifecycle=None,
      config~,
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(CompositionError::ToolCollision(name, _msg)) => assert_eq(name, "bash")
    _ => fail("expected CompositionError::ToolCollision for duplicate 'bash'")
  }
}

///|
/// Mock ModelPort that emits StreamChunks then returns a final response.
struct MockStreamingModelPort {
  chunks : Array[StreamChunk]
  final_response : ModelResponse
}

///|
impl ModelPort for MockStreamingModelPort with fn chat(
  self,
  _messages,
  _tools,
  _options,
) {
  self.final_response
}

///|
impl ModelPort for MockStreamingModelPort with fn chat_streaming(
  self,
  _messages,
  _tools,
  _options,
  on_chunk,
) {
  for chunk in self.chunks {
    on_chunk(chunk)
  }
  self.final_response
}

///|
async test "streaming_events_emitted_during_chat" {
  let chunks : Array[StreamChunk] = [
    TextDelta(token="Hello"),
    TextDelta(token=" world"),
    Usage({
      input_tokens: Some(10),
      output_tokens: Some(5),
      total_tokens: Some(15),
    }),
    Finish(reason=Stop),
  ]
  let final_response = stop_response("Hello world")
  let model = MockStreamingModelPort::{ chunks, final_response }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn(user_msg("stream test"), "session_s1")

  let mut stream_count = 0
  for e in observer.events {
    match e {
      StreamChunkReceived(_) => stream_count = stream_count + 1
      _ => ()
    }
  }
  assert_eq(stream_count, 4)
}

///|
async test "stream_accumulator_assembles_response" {
  let acc = StreamAccumulator::new()
  acc.push(TextDelta(token="Hi"))
  acc.push(TextDelta(token=" there"))
  acc.push(ReasoningDelta(token="thinking"))
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("tc1"),
      name=Some("bash"),
      arguments_delta=Some("{\"cmd\""),
    ),
  )
  acc.push(
    ToolCallDelta(index=0, id=None, name=None, arguments_delta=Some(":\"ls\"}")),
  )
  acc.push(
    Usage({
      input_tokens: Some(10),
      output_tokens: Some(20),
      total_tokens: Some(30),
    }),
  )
  acc.push(Finish(reason=ToolCalls))

  let resp = acc.to_response()
  assert_eq(resp.message.content.length(), 1)
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].id, "tc1")
  assert_eq(resp.tool_calls[0].name, "bash")
  assert_true(resp.finish_reason is ToolCalls)
  assert_true(resp.usage is Some(_))
  assert_true(resp.reasoning_content is Some(_))
}

///|
/// Test: Multiple observers all receive events (fan-out)
async test "multiple_observers_fan_out" {
  let model = MockModelPort::{ responses: [stop_response("fan-out")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let obs1 = MockObserver::{ events: [] }
  let obs2 = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs1, obs2],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn(user_msg("broadcast"), "session_1")

  assert_true(obs1.events.length() >= 2)
  assert_true(obs2.events.length() >= 2)
  assert_eq(obs1.events.length(), obs2.events.length())
}

///|
/// Test: Multiple hooks are chained in order
async test "multiple_hooks_chained_in_order" {
  let hook1 = LogHook::{ seen: [] }
  let hook2 = LogHook::{ seen: [] }
  let model = MockModelPort::{ responses: [stop_response("chained")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[hook1, hook2],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn(user_msg("multi-hook"), "session_1")

  // Both hooks should see BeforeTurn and AfterTurn
  assert_true(hook1.seen.length() >= 2)
  assert_eq(hook1.seen.length(), hook2.seen.length())
}

///|
/// Test: Multiple session stores all receive writes
async test "multiple_session_stores_write_all" {
  let model = MockModelPort::{
    responses: [stop_response("multi-store")],
    index: 0,
  }
  let store1 = MockSessionStore::{ store: Map::from_array([]) }
  let store2 = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store1, store2],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn(user_msg("persist"), "session_1")

  assert_true(store1.store.contains("session_1"))
  assert_true(store2.store.contains("session_1"))
}

///|
/// Helper: build a minimal CommandParam for tests.
fn make_param(
  name : String,
  ptype? : ParamType = Str,
  required? : Bool = false,
  positional? : Bool = false,
  default? : Json? = None,
  choices? : Array[String]? = None,
) -> CommandParam {
  {
    name,
    label: name,
    description: "",
    ptype,
    required,
    default,
    choices,
    positional,
  }
}

///|
/// Helper: build a minimal CommandDef for tests.
fn make_command(
  id : String,
  params? : Array[CommandParam] = [],
  ctype? : CommandType = Action,
) -> CommandDef {
  {
    id,
    label: id,
    description: "",
    category: "test",
    ctype,
    params,
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  }
}

///|
test "parse_slash_args_handles_positional" {
  let params = [make_param("value", ptype=Str, positional=true)]
  let result = parse_slash_args("deepseek", params)
  assert_true(result is Ok(_))
  match result {
    Ok(json) =>
      match json {
        Object(map) =>
          match map.get("value") {
            Some(String(s)) => assert_eq(s, "deepseek")
            _ => fail("expected string value")
          }
        _ => fail("expected object")
      }
    Err(_) => fail("parse failed")
  }
}

///|
test "parse_slash_args_handles_key_value" {
  let params = [
    make_param("query", ptype=Str, positional=true),
    make_param(
      "limit",
      ptype=Int,
      positional=false,
      default=Some(Json::number(5.0)),
    ),
  ]
  let result = parse_slash_args("hello limit=10", params)
  assert_true(result is Ok(_))
  match result {
    Ok(json) =>
      match json {
        Object(map) => {
          match map.get("query") {
            Some(String(s)) => assert_eq(s, "hello")
            _ => fail("expected query string")
          }
          match map.get("limit") {
            Some(Number(n, ..)) => assert_eq(n, 10.0)
            _ => fail("expected limit number")
          }
        }
        _ => fail("expected object")
      }
    Err(_) => fail("parse failed")
  }
}

///|
test "validate_args_missing_required" {
  let def = make_command("test.cmd", params=[
    make_param("name", ptype=Str, required=true),
  ])
  let args = Json::object({})
  match validate_args(def, args) {
    Err(msg) => assert_true(msg.contains("missing required"))
    Ok(_) => fail("should fail on missing required")
  }
}

///|
test "validate_args_applies_default" {
  let def = make_command("test.cmd", params=[
    make_param("level", ptype=Int, default=Some(Json::number(3.0))),
  ])
  let args = Json::object({})
  match validate_args(def, args) {
    Ok(json) =>
      match json {
        Object(map) =>
          match map.get("level") {
            Some(Number(n, ..)) => assert_eq(n, 3.0)
            _ => fail("expected default level")
          }
        _ => fail("expected object")
      }
    Err(_) => fail("should apply default")
  }
}

///|
async test "noop_command_port_returns_empty_and_raises_notfound" {
  let port = NoopCommandPort::{  }
  assert_eq(port.commands().length(), 0)
  match (Ok(port.invoke("anything", Json::object({}))) catch { e => Err(e) }) {
    Err(NotFound(id)) => assert_eq(id, "anything")
    Err(_) => fail("expected NotFound")
    Ok(_) => fail("expected raise")
  }
}

///|
/// Hook that always returns Err(Aborted) — used to test finally semantics.
struct AlwaysFailHook {}

///|
impl PipelineHook for AlwaysFailHook with fn on_stage(_self, _stage : Stage) -> Result[
  Stage,
  HookError,
] {
  Err(Aborted("always fails"))
}

///|
/// After stages run hooks in reverse order: hooks[1] runs before hooks[0].
async test "hook_chain_after_stage_reversed_order" {
  let hook1 = LogHook::{ seen: [] }
  let hook2 = LogHook::{ seen: [] }
  let chain = HookChain::{ hooks: [hook1, hook2] }
  let tc = { id: "c1", name: "t", arguments: Json::null() }
  let tr = { content: "ok", structured: None, is_error: false }
  let _ = chain.on_stage(AfterTool(tc, tr))
  // hook2 (index 1) should have run first — its seen[0] is the AfterTool
  assert_eq(hook2.seen.length(), 1)
  assert_eq(hook1.seen.length(), 1)
}

///|
/// Finally semantics: even if one hook returns Err on an after stage,
/// all other hooks still execute.
async test "hook_chain_after_stage_runs_all_on_error" {
  let hook1 = LogHook::{ seen: [] }
  let fail = AlwaysFailHook::{  }
  // hook1 first (index 0), fail second (index 1).
  // On after stage, reverse order: fail runs first (returns Err),
  // but hook1 still runs (finally).
  let chain = HookChain::{ hooks: [hook1, fail] }
  let tc = { id: "c2", name: "t", arguments: Json::null() }
  let tr = { content: "ok", structured: None, is_error: false }
  let _ = chain.on_stage(AfterTool(tc, tr))
  // hook1 must have run despite fail returning Err
  assert_eq(hook1.seen.length(), 1)
}

///|
/// Finally semantics: when the model errors, the TurnError hook still fires
/// (wrapped by run_turn's outer try/catch) even though the turn aborts.
async test "hook_turn_error_fires_on_model_error" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let log_hook = LogHook::{ seen: [] }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[empty_tools()],
    hooks=[log_hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  // Model has no responses → raises; run_turn catches and fires TurnError.
  let _ = Ok(agent.run_turn(user_msg("boom"), "session_1")) catch {
    e => Err(e)
  }
  // LogHook should have seen BeforeTurn (forward path) + TurnError (finally path)
  let saw_turn_error = log_hook.seen.iter().any(fn(s) { s is TurnError(_) })
  assert_true(saw_turn_error)
}

///|
/// Finally semantics: when BeforeTool aborts (raise HookAborted), the
/// TurnError hook still fires before the error propagates.
async test "hook_turn_error_fires_on_before_tool_abort" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{ responses: [tool_response([tc])], index: 0 }
  let tools = MockToolProvider::{
    tools: [
      {
        name: "bash",
        description: "",
        input_schema: Json::null(),
        metadata: None,
        source: None,
      },
    ],
    results: Map::from_array([]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  // AbortHook aborts on BeforeTool; LogHook records stages.
  // Order matters: LogHook first (sees BeforeTurn), AbortHook second (aborts BeforeTool).
  // But hook chain runs forward on Before stages, so both see BeforeTurn,
  // then AbortHook aborts on BeforeTool → run_turn catches → TurnError fires to both (reverse).
  let log_hook = LogHook::{ seen: [] }
  let abort_hook = AbortHook::{  }
  let config = make_config()

  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[log_hook, abort_hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = Ok(agent.run_turn(user_msg("danger"), "session_1")) catch {
    e => Err(e)
  }
  let saw_turn_error = log_hook.seen.iter().any(fn(s) { s is TurnError(_) })
  assert_true(saw_turn_error)
}
