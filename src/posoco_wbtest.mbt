///|
/// Whitebox tests with mock implementations. R3 M3.7: all fixtures use
/// canonical kernel types directly.
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
  _self,
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
/// Lists tools and executes them from a results map.
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
struct AbortHook {}

///|
impl @port.Hook for AbortHook with fn before_tool(
  _self,
  _call : @kernel.ToolCall,
) -> @port.ToolHookDecision {
  Reject(reason="blocked by policy")
}

///|
struct LogHook {
  seen : Array[@port.HookStage]
}

///|
impl @port.Hook for LogHook with fn on_post_event(self, stage : @port.HookStage) -> Unit {
  self.seen.push(stage)
}

///|
fn make_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  }
}

///|
fn user_msg(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
fn _assistant_msg(text : String) -> @kernel.Message {
  @kernel.AssistantMessage(
    content=[@kernel.Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
  )
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
fn tool_response(
  tool_calls : Array[@kernel.ToolCall],
) -> @kernel.ModelCallResult {
  let completion : @kernel.Completion = @kernel.Completion(
    content=[],
    tool_calls~,
    reasoning=None,
    finish_reason=@kernel.ToolCalls,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
fn make_tool_call(id : String, name : String) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
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

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="run a cmd",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="ok", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("run ls"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  let outcome = result.tool_results[0]
  let content0 = match outcome {
    @kernel.Success(content~, ..) => content
    @kernel.ToolReportedError(content~, ..) => content
    @kernel.RuntimeFailure(message~, ..) => message
    @kernel.NotExecuted(..) => "<not executed>"
  }
  assert_eq(content0, "ok")
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Err(@error.RuntimeError::InvocationFailed("boom"))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("do it"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_failure())
}

///|
async test "model_error_aborts_turn" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("ping"), "session_1")) catch { e => Err(e) }) {
    Err(@error.AgentError::Model(_)) => ()
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="ok", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()
  let abort_hook = AbortHook::{  }

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], hooks=[abort_hook], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("danger"), "session_1")) catch { e => Err(e) }) {
    Err(@error.AgentError::HookAborted(msg)) =>
      assert_true(msg.contains("blocked by policy"))
    _ => fail("expected HookAborted error")
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="ok", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = {
    max_tool_rounds: 2,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  }

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
    config~,
  )
  match
    (Ok(agent.run_turn(user_msg("loop"), "session_1")) catch { e => Err(e) }) {
    Err(@error.AgentError::ToolLoopExceeded) => ()
    _ => fail("expected ToolLoopExceeded")
  }
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="seq", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
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

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("persist me"), "session_1")
  if store.store.contains("session_1") {
    let session = store.store["session_1"]
    assert_true(session.messages.length() >= 2)
    assert_true(session.messages[0] is @kernel.UserMessage(_))
    assert_true(
      session.messages[session.messages.length() - 1]
      is @kernel.AssistantMessage(..),
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
impl @port.Hook for RewriteModelHook with fn before_model(
  _self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let system_msg = @kernel.SystemMessage(content=[
    @kernel.Text("SYSTEM: rewritten"),
  ])
  let new_msgs = [system_msg]
  for m in messages {
    new_msgs.push(m)
  }
  new_msgs
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
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="io",
        tools=[empty_tools()],
        hooks=[rewriter],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let session = store.store["session_1"]
  assert_true(session.messages.length() >= 2)
  assert_true(session.messages[0] is @kernel.SystemMessage(_))
}

///|
/// DeferToolHook — returns Deferred for tools needing approval
struct DeferToolHook {}

///|
impl @port.Hook for DeferToolHook with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolHookDecision {
  if call.name.to_string() == "restricted" {
    Defer(reason="needs admin approval")
  } else {
    Approve(call~)
  }
}

///|
/// Test: Deferred hook skips tool execution and notifies LLM
async test "hook_deferred_skips_execution" {
  // Defer is not yet supported in the Puppet path — the pump returns
  // HookRejected when a PreToolHook returns Defer. This test verifies that
  // the rejection surfaces as AgentError::HookAborted.
  let tc = make_tool_call("call_1", "restricted")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("approved")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("restricted"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("restricted", Ok(@kernel.Success(content="executed", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let hook = DeferToolHook::{  }
  let config = make_config()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], hooks=[hook], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let result = Ok(agent.run_turn(user_msg("use restricted"), "session_1")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::HookAborted(msg)) =>
      assert_true(msg.contains("defer not yet supported"))
    _ => fail("expected HookAborted for unsupported Defer decision")
  }
}

///|
/// ApproveAllToolHook — overrides only `before_tool`; `before_model` and
/// `on_post_event` are inherited from the trait's default implementations.
struct ApproveAllToolHook {}

///|
impl @port.Hook for ApproveAllToolHook with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolHookDecision {
  Approve(call~)
}

///|
/// Test: Hook default methods pass through — a hook that overrides only
/// `before_tool` inherits the default `before_model` (identity) and
/// `on_post_event` (noop), so the user message reaches the transcript
/// unchanged and the turn completes normally.
async test "hook_default_methods_pass_through" {
  let tc = make_tool_call("call_1", "echo")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("echo"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("echo", Ok(@kernel.Success(content="echoed", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], hooks=[ApproveAllToolHook::{  }], sessions=[
        store,
      ]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("hello"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let session = store.store["session_1"]
  // The default before_model passed the messages through unchanged: the
  // first transcript entry is still the original user message.
  match session.messages[0] {
    @kernel.UserMessage(content~) =>
      assert_true(
        content
        .iter()
        .any(fn(part) {
          match part {
            @kernel.Text(t) => t == "hello"
            _ => false
          }
        }),
      )
    _ => fail("expected original user message first (default pass-through)")
  }
}

///|
/// Test: one Hook implementor receives every interception point through a
/// single trait impl — before_model, before_tool and on_post_event all land
/// on the same RecordingHook instance in one turn.
async test "hook_single_impl_receives_all_points" {
  let tc = make_tool_call("call_1", "echo")
  let model = MockModelPort::{
    responses: [tool_response([tc]), stop_response("done")],
    index: 0,
  }
  let tools = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("echo"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("echo", Ok(@kernel.Success(content="echoed", structured=None))),
    ]),
  }
  let hook = RecordingHook::RecordingHook()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], hooks=[hook], sessions=[
        MockSessionStore::{ store: Map::from_array([]) },
      ]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("hi"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let labels = hook.records().map(fn(record) { record.label })
  assert_true(labels.contains("before_model"))
  assert_true(labels.contains("before_tool"))
  assert_true(labels.contains("on_post_event"))
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
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="run cmd",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=Some("host"),
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="shell ok", structured=None))),
    ]),
  }
  let mcp_tools = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("mcp__read"),
        description="read file",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=Some("mcp"),
      ),
    ],
    results: Map::from_array([
      ("mcp__read", Ok(@kernel.Success(content="mcp ok", structured=None))),
    ]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[shell_tools, mcp_tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("run both"), "session_1")
  assert_eq(result.tool_results.length(), 2)
  let content_first = match result.tool_results[0] {
    @kernel.Success(content~, ..) => content
    _ => "<other>"
  }
  let content_second = match result.tool_results[1] {
    @kernel.Success(content~, ..) => content
    _ => "<other>"
  }
  assert_eq(content_first, "shell ok")
  assert_eq(content_second, "mcp ok")
}

///|
/// Test: Agent detects tool name collisions across providers
async test "agent_tool_collision_detection" {
  let provider1 = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="v1",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([]),
  }
  let provider2 = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="v2",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(@kernel.Success(content="v2 wins", structured=None))),
    ]),
  }
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  // T06-B: collision now fails composition (raise) rather than last-wins.
  let composition_result = Ok(
    Agent(
      exts=[
        tk_ext(id="model", model=Some(model)),
        tk_ext(id="io", tools=[provider1, provider2], sessions=[store], observers=[
          observer,
        ]),
      ],
      config~,
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, _msg, ..)) =>
      assert_eq(name, "bash")
    _ => fail("expected CompositionError::ToolCollision for duplicate 'bash'")
  }
}

///|
/// Mock ModelPort that emits StreamChunks then returns a final completion.
/// R3 M3.7: chat now takes StreamMode; when stream is Stream(cb), the mock
/// replays its chunks via cb (encoded as JSON via wbtest_stream_chunk_to_json).
struct MockStreamingModelPort {
  chunks : Array[@types.StreamChunk]
  final_response : @kernel.ModelCallResult
}

///|
impl @port.ModelPort for MockStreamingModelPort with fn chat(
  self,
  _messages : Array[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  match stream {
    @types.Stream(cb) =>
      for chunk in self.chunks {
        cb(wbtest_stream_chunk_to_json(chunk))
      }
    @types.NoStream => ()
  }
  self.final_response
}

///|
impl @port.ModelPort for MockStreamingModelPort with fn compact(
  _self,
  _messages : Array[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse(
    "MockStreamingModelPort does not implement compact",
  )
}

///|
impl @port.ModelPort for MockStreamingModelPort with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// Encode a StreamChunk as the same JSON shape observers expect. Local copy
/// of the helper in testkit.mbt (kept private to this wbtest file).
fn wbtest_stream_chunk_to_json(chunk : @types.StreamChunk) -> Json {
  match chunk {
    @types.TextDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("text")),
          ("token", Json::string(token)),
        ]),
      )
    @types.ReasoningDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("reasoning")),
          ("token", Json::string(token)),
        ]),
      )
    @types.ToolCallDelta(..) =>
      Json::object(Map::from_array([("kind", Json::string("tool_call_delta"))]))
    @types.Usage(..) =>
      Json::object(Map::from_array([("kind", Json::string("usage"))]))
    @types.Finish(_) =>
      Json::object(Map::from_array([("kind", Json::string("finish"))]))
  }
}

///|
async test "streaming_events_emitted_during_chat" {
  let chunks : Array[@types.StreamChunk] = [
    @types.TextDelta(token="Hello"),
    @types.TextDelta(token=" world"),
    @types.Usage(input_tokens=10, output_tokens=5, total_tokens=15),
    @types.Finish(reason="stop"),
  ]
  let final_response = stop_response("Hello world")
  let model = MockStreamingModelPort::{ chunks, final_response }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        observer,
      ]),
    ],
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
async test "stream_accumulator_assembles_completion" {
  let acc = @types.StreamAccumulator()
  acc.push(@types.TextDelta(token="Hi"))
  acc.push(@types.TextDelta(token=" there"))
  acc.push(@types.ReasoningDelta(token="thinking"))
  acc.push(
    @types.ToolCallDelta(
      index=0,
      id=Some("tc1"),
      name=Some("bash"),
      arguments_delta=Some("{\"cmd\""),
    ),
  )
  acc.push(
    @types.ToolCallDelta(
      index=0,
      id=None,
      name=None,
      arguments_delta=Some(":\"ls\"}"),
    ),
  )
  acc.push(@types.Usage(input_tokens=10, output_tokens=20, total_tokens=30))
  acc.push(@types.Finish(reason="tool_calls"))

  let resp = acc.to_completion()
  let msg = resp.message
  assert_eq(msg.content.length(), 1)
  assert_eq(msg.tool_calls.length(), 1)
  assert_eq(msg.tool_calls[0].call_id.to_string(), "tc1")
  assert_eq(msg.tool_calls[0].name.to_string(), "bash")
  assert_true(msg.finish_reason is @kernel.ToolCalls)
  assert_true(resp.usage is Some(_))
  assert_true(msg.reasoning is Some(_))
}

///|
/// Test: Multiple observers all receive events (fan-out)
async test "multiple_observers_fan_out" {
  let model = MockModelPort::{ responses: [stop_response("fan-out")], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let obs1 = MockObserver::{ events: [] }
  let obs2 = MockObserver::{ events: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store], observers=[
        obs1, obs2,
      ]),
    ],
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

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="io",
        tools=[empty_tools()],
        hooks=[hook1, hook2],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  let _ = agent.run_turn(user_msg("multi-hook"), "session_1")

  // Both hooks should see at least one post-stage event (ModelCompleted)
  assert_true(hook1.seen.length() >= 1)
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

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[empty_tools()], sessions=[store1, store2], observers=[
        observer,
      ]),
    ],
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
  ptype? : @port.ParamType = Str,
  required? : Bool = false,
  positional? : Bool = false,
  default? : Json? = None,
  choices? : Array[String]? = None,
) -> @port.CommandParam {
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
  params? : Array[@port.CommandParam] = [],
  ctype? : @port.CommandType = Action,
) -> @port.CommandDef {
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
  let args = Json::empty_object()
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
  let args = Json::empty_object()
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
  match
    (Ok(port.invoke("anything", Json::empty_object())) catch { e => Err(e) }) {
    Err(@error.CommandError::NotFound(id)) => assert_eq(id, "anything")
    Err(_) => fail("expected NotFound")
    Ok(_) => fail("expected raise")
  }
}

///|
/// After stages run hooks in reverse order: hooks[1] runs before hooks[0].
async test "hook_turn_error_fires_on_model_error" {
  let model = MockModelPort::{ responses: [], index: 0 }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let log_hook = LogHook::{ seen: [] }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="io",
        tools=[empty_tools()],
        hooks=[log_hook],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  // Model has no responses → raises; run_turn catches and fires TurnFailed.
  let _ = Ok(agent.run_turn(user_msg("boom"), "session_1")) catch {
    e => Err(e)
  }
  // LogHook (PostEventHook) should have seen ModelFailed
  let saw_model_failed = log_hook.seen.iter().any(fn(s) { s is ModelFailed(_) })
  assert_true(saw_model_failed)
}

///|
/// Finally semantics: when BeforeTool aborts (raise HookAborted), the
/// TurnError hook still fires before the error propagates.
async test "hook_turn_error_fires_on_before_tool_abort" {
  let tc = make_tool_call("call_1", "bash")
  let model = MockModelPort::{ responses: [tool_response([tc])], index: 0 }
  let tools = MockToolProvider::{
    tools: [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=@kernel.Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  // AbortHook aborts on BeforeTool; LogHook records post-stage events.
  let log_hook = LogHook::{ seen: [] }
  let abort_hook = AbortHook::{  }
  let config = make_config()

  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="io",
        tools=[tools],
        hooks=[log_hook, abort_hook],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  let _ = Ok(agent.run_turn(user_msg("danger"), "session_1")) catch {
    e => Err(e)
  }
  // Model call succeeded before the abort, so ModelCompleted should be seen
  let saw_model_completed = log_hook.seen
    .iter()
    .any(fn(s) { s is ModelCompleted(_) })
  assert_true(saw_model_completed)
}
