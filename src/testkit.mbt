///|
/// Conformance testkit for Posoco (M0-T04).
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details. Distinct from the minimal Mock* types used by the
/// blackbox tests: the testkit records call order, arguments, and metadata
/// snapshots, and fails loudly when a script is exhausted.
///
/// The testkit is a test/support layer only — it never enters the production
/// Agent dependency direction.

///|
fn testkit_snapshot_json(value : Json) -> Json {
  match value {
    Null => Json::null()
    True => Json::boolean(true)
    False => Json::boolean(false)
    Number(number, repr~) => Json::number(number, repr?)
    String(text) => Json::string(text)
    Array(values) => Json::array(values.map(testkit_snapshot_json))
    Object(values) => {
      let copied : Map[String, Json] = Map::from_array([])
      for key in values.keys() {
        copied[key] = testkit_snapshot_json(values[key])
      }
      Json::object(copied)
    }
  }
}

///|
fn testkit_snapshot_tool_call(call : @types.ToolCall) -> @types.ToolCall {
  {
    id: call.id,
    name: call.name,
    arguments: testkit_snapshot_json(call.arguments),
  }
}

///|
fn testkit_snapshot_tool_def(tool : @types.ToolDef) -> @types.ToolDef {
  {
    name: tool.name,
    description: tool.description,
    input_schema: testkit_snapshot_json(tool.input_schema),
    metadata: match tool.metadata {
      Some(value) => Some(testkit_snapshot_json(value))
      None => None
    },
    source: tool.source,
  }
}

///|
fn testkit_snapshot_message(message : @types.Message) -> @types.Message {
  {
    role: message.role,
    content: message.content.copy(),
    tool_calls: message.tool_calls.map(testkit_snapshot_tool_call),
    tool_call_id: message.tool_call_id,
    name: message.name,
    reasoning_content: message.reasoning_content,
  }
}

///|
fn testkit_snapshot_messages(
  messages : Array[@types.Message],
) -> Array[@types.Message] {
  messages.map(testkit_snapshot_message)
}

///|
fn testkit_snapshot_tool_result(
  result : @types.ToolResult,
) -> @types.ToolResult {
  {
    content: result.content,
    structured: match result.structured {
      Some(value) => Some(testkit_snapshot_json(value))
      None => None
    },
    is_error: result.is_error,
  }
}

///|
fn testkit_snapshot_tool_outcome(
  outcome : ScriptedToolOutcome,
) -> ScriptedToolOutcome {
  match outcome {
    OutcomeOk(result) => OutcomeOk(testkit_snapshot_tool_result(result))
    OutcomeErr(error) => OutcomeErr(error)
  }
}

///|
fn testkit_snapshot_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let copied : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    copied[key] = testkit_snapshot_json(metadata[key])
  }
  copied
}

///|
fn testkit_snapshot_session(session : @types.Session) -> @types.Session {
  {
    messages: testkit_snapshot_messages(session.messages),
    metadata: testkit_snapshot_metadata(session.metadata),
  }
}

///|
fn testkit_snapshot_response(
  response : @types.ModelResponse,
) -> @types.ModelResponse {
  {
    message: testkit_snapshot_message(response.message),
    tool_calls: response.tool_calls.map(testkit_snapshot_tool_call),
    finish_reason: response.finish_reason,
    usage: response.usage,
    reasoning_content: response.reasoning_content,
  }
}

///|
fn testkit_snapshot_turn_result(
  result : @types.TurnResult,
) -> @types.TurnResult {
  {
    message: testkit_snapshot_message(result.message),
    tool_results: result.tool_results.map(testkit_snapshot_tool_result),
    final_session_id: result.final_session_id,
  }
}

///|
fn testkit_snapshot_stage(stage : @port.Stage) -> @port.Stage {
  match stage {
    @port.BeforeTurn => @port.BeforeTurn
    @port.BeforeModel(messages) =>
      @port.BeforeModel(testkit_snapshot_messages(messages))
    @port.AfterModel(response) =>
      @port.AfterModel(testkit_snapshot_response(response))
    @port.ModelError(reason) => @port.ModelError(reason)
    @port.BeforeTool(call) => @port.BeforeTool(testkit_snapshot_tool_call(call))
    @port.AfterTool(call, result) =>
      @port.AfterTool(
        testkit_snapshot_tool_call(call),
        testkit_snapshot_tool_result(result),
      )
    @port.ToolError(call, error) =>
      @port.ToolError(testkit_snapshot_tool_call(call), error)
    @port.AfterTurn(result) =>
      @port.AfterTurn(testkit_snapshot_turn_result(result))
    @port.TurnError(error) => @port.TurnError(error)
  }
}

///|
fn testkit_snapshot_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    @types.TurnStarted => @types.TurnStarted
    @types.ToolCallPending(call) =>
      @types.ToolCallPending(testkit_snapshot_tool_call(call))
    @types.ToolCallResult(call~, result~, is_error~) =>
      @types.ToolCallResult(
        call=testkit_snapshot_tool_call(call),
        result=testkit_snapshot_tool_result(result),
        is_error~,
      )
    @types.ModelResponseReceived(message~, usage~, reasoning_content~) =>
      @types.ModelResponseReceived(
        message=testkit_snapshot_message(message),
        usage~,
        reasoning_content~,
      )
    @types.SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      @types.SessionRedirect(from~, to~, messages_before~, messages_after~)
    @types.TurnCompleted => @types.TurnCompleted
    @types.TurnFailed(reason) => @types.TurnFailed(reason)
    @types.ToolCallDeferred(call~, reason~) =>
      @types.ToolCallDeferred(call=testkit_snapshot_tool_call(call), reason~)
    @types.StreamChunkReceived(chunk~) => @types.StreamChunkReceived(chunk~)
    @types.Custom(source~, label~, data~) =>
      @types.Custom(source~, label~, data=testkit_snapshot_json(data))
  }
}

// ---------------------------------------------------------------------------
// ScriptedModel — returns responses/errors/stream chunks by call sequence.
// ---------------------------------------------------------------------------

///|
/// A single scripted model interaction: a response, an exact stream transcript,
/// or a typed error. `Stream` never synthesizes chunks from the final response.
pub(all) enum ScriptedModelStep {
  Respond(@types.ModelResponse)
  Stream(chunks~ : Array[@types.StreamChunk], response~ : @types.ModelResponse)
  Fail(@error.ModelError)
}

///|
fn testkit_snapshot_model_step(step : ScriptedModelStep) -> ScriptedModelStep {
  match step {
    Respond(response) => Respond(testkit_snapshot_response(response))
    Stream(chunks~, response~) =>
      Stream(chunks=chunks.copy(), response=testkit_snapshot_response(response))
    Fail(error) => Fail(error)
  }
}

///|
/// ModelPort fake that plays a fixed script. Each `chat` call consumes one
/// step in order. When the script is exhausted the next call fails with
/// `ModelError::Transport("scripted_model_exhausted at call <N>")` — it never
/// silently repeats the last response.
pub(all) struct ScriptedModel {
  steps : Array[ScriptedModelStep]
  mut index : Int
  mut calls : Int
  received_messages : Array[Array[@types.Message]]
  received_tools : Array[Array[@types.ToolDef]]
  received_options : Array[@types.ChatOptions]
  received_chunks : Array[@types.StreamChunk]
}

///|
pub fn ScriptedModel::new(steps : Array[ScriptedModelStep]) -> ScriptedModel {
  {
    steps: steps.map(testkit_snapshot_model_step),
    index: 0,
    calls: 0,
    received_messages: [],
    received_tools: [],
    received_options: [],
    received_chunks: [],
  }
}

///|
/// Number of chat/chat_streaming calls observed so far.
pub fn ScriptedModel::call_count(self : ScriptedModel) -> Int {
  self.calls
}

///|
/// Direct (non-trait) chat entry point for testkit self-tests.
/// Trait methods on concrete types must be dispatched through a `&ModelPort`
/// reference; this wrapper lets tests call chat without an Agent.
pub async fn ScriptedModel::chat_direct(
  self : ScriptedModel,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
) -> @types.ModelResponse raise @error.ModelError {
  (self as &@port.ModelPort).chat(messages, tools, options)
}

///|
/// Direct streaming entry point for testkit self-tests.
pub async fn ScriptedModel::chat_streaming_direct(
  self : ScriptedModel,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
  on_chunk : (@types.StreamChunk) -> Unit,
) -> @types.ModelResponse raise @error.ModelError {
  (self as &@port.ModelPort).chat_streaming(messages, tools, options, on_chunk)
}

///|
/// Snapshot of all chat options received, in call order.
pub fn ScriptedModel::options_received(
  self : ScriptedModel,
) -> Array[@types.ChatOptions] {
  self.received_options.copy()
}

///|
fn ScriptedModel::take_step(
  self : ScriptedModel,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
) -> ScriptedModelStep raise @error.ModelError {
  self.calls = self.calls + 1
  self.received_messages.push(testkit_snapshot_messages(messages))
  self.received_tools.push(tools.map(testkit_snapshot_tool_def))
  self.received_options.push(options)
  if self.index < self.steps.length() {
    let step = self.steps[self.index]
    self.index = self.index + 1
    step
  } else {
    raise @error.ModelError::Transport(
      "scripted_model_exhausted at call \{self.calls} (script had \{self.steps.length()} steps)",
    )
  }
}

///|
pub impl @port.ModelPort for ScriptedModel with fn chat(
  self,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
) -> @types.ModelResponse raise @error.ModelError {
  match self.take_step(messages, tools, options) {
    Respond(resp) => testkit_snapshot_response(resp)
    Stream(response~, ..) => testkit_snapshot_response(response)
    Fail(e) => raise e
  }
}

///|
/// Streaming variant replays exactly the configured chunks, in order.
pub impl @port.ModelPort for ScriptedModel with fn chat_streaming(
  self,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
  on_chunk : (@types.StreamChunk) -> Unit,
) -> @types.ModelResponse raise @error.ModelError {
  match self.take_step(messages, tools, options) {
    Stream(chunks~, response~) => {
      for chunk in chunks {
        self.received_chunks.push(chunk)
        on_chunk(chunk)
      }
      testkit_snapshot_response(response)
    }
    Respond(response) => testkit_snapshot_response(response)
    Fail(e) => raise e
  }
}

// ---------------------------------------------------------------------------
// RecordingToolProvider — records list/execute order and configurable outcomes.
// ---------------------------------------------------------------------------

///|
/// Configurable outcome for a tool call: success result, or raised runtime error.
/// Constructors are prefixed with `Outcome` to avoid ambiguity with
/// `Result::Ok`/`Result::Err` at unqualified call sites.
pub(all) enum ScriptedToolOutcome {
  OutcomeOk(@types.ToolResult)
  OutcomeErr(@error.RuntimeError)
}

///|
/// A recorded tool execution: call id, tool name, and outcome category.
pub(all) struct ToolExecRecord {
  requested_name : String
  call_id : String
  tool_name : String
  arguments : Json
  outcome : ScriptedToolOutcome
}

///|
/// Unified provider operation trace, preserving list/execute interleaving.
pub(all) enum ToolProviderOp {
  ListTools
  ExecuteTool(requested_name~ : String, call~ : @types.ToolCall)
}

///|
/// ToolProvider fake that declares a fixed tool list and routes execute() by
/// tool name through a configurable outcome map. Unknown tools raise
/// `RuntimeError::UnknownTool`. Every execute is recorded with its call id.
pub(all) struct RecordingToolProvider {
  tool_defs : Array[@types.ToolDef]
  outcomes : Map[String, ScriptedToolOutcome]
  mut list_calls : Int
  mut exec_records : Array[ToolExecRecord]
  mut ops : Array[ToolProviderOp]
}

///|
pub fn RecordingToolProvider::new(
  tool_defs : Array[@types.ToolDef],
  outcomes : Map[String, ScriptedToolOutcome],
) -> RecordingToolProvider {
  let copied_outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([])
  for key in outcomes.keys() {
    copied_outcomes[key] = testkit_snapshot_tool_outcome(outcomes[key])
  }
  {
    tool_defs: tool_defs.map(testkit_snapshot_tool_def),
    outcomes: copied_outcomes,
    list_calls: 0,
    exec_records: [],
    ops: [],
  }
}

///|
/// Number of times list_tools was called.
pub fn RecordingToolProvider::list_call_count(
  self : RecordingToolProvider,
) -> Int {
  self.list_calls
}

///|
/// Snapshot of recorded executions (call id, tool name, outcome).
pub fn RecordingToolProvider::exec_records(
  self : RecordingToolProvider,
) -> Array[ToolExecRecord] {
  self.exec_records.map(fn(record) {
    {
      requested_name: record.requested_name,
      call_id: record.call_id,
      tool_name: record.tool_name,
      arguments: testkit_snapshot_json(record.arguments),
      outcome: testkit_snapshot_tool_outcome(record.outcome),
    }
  })
}

///|
/// Snapshot of list/execute operations in their exact observed order.
pub fn RecordingToolProvider::ops(
  self : RecordingToolProvider,
) -> Array[ToolProviderOp] {
  self.ops.map(fn(op) {
    match op {
      ListTools => ListTools
      ExecuteTool(requested_name~, call~) =>
        ExecuteTool(requested_name~, call=testkit_snapshot_tool_call(call))
    }
  })
}

///|
/// Direct (non-trait) execute entry point for testkit self-tests.
pub async fn RecordingToolProvider::execute_direct(
  self : RecordingToolProvider,
  name : String,
  call : @types.ToolCall,
) -> @types.ToolResult raise @error.RuntimeError {
  (self as &@port.ToolProvider).execute(name, call)
}

///|
pub impl @port.ToolProvider for RecordingToolProvider with fn list_tools(self) {
  self.list_calls = self.list_calls + 1
  self.ops.push(ListTools)
  self.tool_defs.map(testkit_snapshot_tool_def)
}

///|
pub impl @port.ToolProvider for RecordingToolProvider with fn execute(
  self,
  name : String,
  call : @types.ToolCall,
) -> @types.ToolResult raise @error.RuntimeError {
  let lookup = self.outcomes.get(call.name)
  let outcome = match lookup {
    Some(o) => o
    None =>
      OutcomeErr(
        @error.RuntimeError::UnknownTool(
          "recording_tool: no outcome configured for '\{call.name}'",
        ),
      )
  }
  self.ops.push(
    ExecuteTool(requested_name=name, call=testkit_snapshot_tool_call(call)),
  )
  self.exec_records.push({
    requested_name: name,
    call_id: call.id,
    tool_name: call.name,
    arguments: testkit_snapshot_json(call.arguments),
    outcome: testkit_snapshot_tool_outcome(outcome),
  })
  match outcome {
    OutcomeOk(r) => testkit_snapshot_tool_result(r)
    OutcomeErr(e) => raise e
  }
}

// ---------------------------------------------------------------------------
// RecordingSessionStore — load/save history with metadata snapshots.
// ---------------------------------------------------------------------------

///|
/// A recorded session operation. Constructors are prefixed with `Op` to avoid
/// ambiguity with `SessionError::Load`/`SessionError::Save`.
pub(all) enum SessionOp {
  OpLoad(id~ : String, result~ : Result[@types.Session, @error.SessionError])
  OpSave(
    id~ : String,
    metadata~ : Map[String, Json],
    result~ : Result[Unit, @error.SessionError]
  )
}

///|
/// SessionStore fake that keeps an in-memory map and records every load/save
/// with the metadata snapshot at save time. Load/save failures are
/// configurable per id.
pub(all) struct RecordingSessionStore {
  store : Map[String, @types.Session]
  mut load_failures : Map[String, @error.SessionError]
  mut save_failures : Array[String]
  mut ops : Array[SessionOp]
}

///|
pub fn RecordingSessionStore::new() -> RecordingSessionStore {
  {
    store: Map::from_array([]),
    load_failures: Map::from_array([]),
    save_failures: [],
    ops: [],
  }
}

///|
/// Seed a session id with an existing session (including metadata).
pub fn RecordingSessionStore::seed(
  self : RecordingSessionStore,
  id : String,
  session : @types.Session,
) -> Unit {
  self.store[id] = testkit_snapshot_session(session)
}

///|
/// Configure load to fail for a given id.
pub fn RecordingSessionStore::fail_load(
  self : RecordingSessionStore,
  id : String,
  err : @error.SessionError,
) -> Unit {
  self.load_failures[id] = err
}

///|
/// Configure save to fail for a given id (all subsequent saves to that id).
pub fn RecordingSessionStore::fail_save(
  self : RecordingSessionStore,
  id : String,
) -> Unit {
  self.save_failures.push(id)
}

///|
/// Recorded operations in order.
pub fn RecordingSessionStore::ops(
  self : RecordingSessionStore,
) -> Array[SessionOp] {
  self.ops.map(fn(op) {
    match op {
      OpLoad(id~, result~) =>
        OpLoad(
          id~,
          result=match result {
            Ok(session) => Ok(testkit_snapshot_session(session))
            Err(error) => Err(error)
          },
        )
      OpSave(id~, metadata~, result~) =>
        OpSave(id~, metadata=testkit_snapshot_metadata(metadata), result~)
    }
  })
}

///|
/// All save operations, in order, as (id, metadata_snapshot) pairs.
pub fn RecordingSessionStore::save_snapshots(
  self : RecordingSessionStore,
) -> Array[(String, Map[String, Json])] {
  let out : Array[(String, Map[String, Json])] = []
  for op in self.ops {
    match op {
      OpSave(id~, metadata~, ..) =>
        out.push((id, testkit_snapshot_metadata(metadata)))
      _ => ()
    }
  }
  out
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn load(
  self,
  id : String,
) -> Result[@types.Session, @error.SessionError] {
  let result : Result[@types.Session, @error.SessionError] = match
    self.load_failures.get(id) {
    Some(e) => Err(e)
    None =>
      match self.store.get(id) {
        Some(s) => Ok(testkit_snapshot_session(s))
        None => Ok({ messages: [], metadata: Map::from_array([]) })
      }
  }
  let recorded_result = match result {
    Ok(session) => Ok(testkit_snapshot_session(session))
    Err(error) => Err(error)
  }
  self.ops.push(OpLoad(id~, result=recorded_result))
  result
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Result[Unit, @error.SessionError] {
  let meta_copy = testkit_snapshot_metadata(session.metadata)
  let result : Result[Unit, @error.SessionError] = if self.save_failures.contains(
      id,
    ) {
    Err(@error.SessionError::Save("configured save failure for '\{id}'"))
  } else {
    self.store[id] = testkit_snapshot_session(session)
    Ok(())
  }
  self.ops.push(OpSave(id~, metadata=meta_copy, result~))
  result
}

// ---------------------------------------------------------------------------
// RecordingObserver — preserves full event order.
// ---------------------------------------------------------------------------

///|
/// Observer fake that records every TurnEvent in arrival order.
/// Unlike a counter, it keeps the full sequence for trace assertions.
pub(all) struct RecordingObserver {
  mut events : Array[@types.TurnEvent]
}

///|
pub fn RecordingObserver::new() -> RecordingObserver {
  { events: [] }
}

///|
/// Snapshot of all recorded events in order.
pub fn RecordingObserver::events(
  self : RecordingObserver,
) -> Array[@types.TurnEvent] {
  self.events.map(testkit_snapshot_event)
}

///|
pub impl @port.Observer for RecordingObserver with fn on_event(self, event) {
  self.events.push(testkit_snapshot_event(event))
}

// ---------------------------------------------------------------------------
// RecordingHook — records stage inputs and outcomes.
// ---------------------------------------------------------------------------

///|
/// The exact decision made by a RecordingHook invocation.
pub(all) enum RecordedHookOutcome {
  Returned(@port.Stage)
  AbortedWith(String)
  DeferredWith(String)
}

///|
fn testkit_snapshot_hook_outcome(
  outcome : RecordedHookOutcome,
) -> RecordedHookOutcome {
  match outcome {
    Returned(stage) => Returned(testkit_snapshot_stage(stage))
    AbortedWith(message) => AbortedWith(message)
    DeferredWith(reason) => DeferredWith(reason)
  }
}

///|
/// A recorded hook invocation: the stage received and its exact decision.
pub(all) struct HookRecord {
  stage_in : @port.Stage
  outcome : RecordedHookOutcome
}

///|
/// PipelineHook fake with configurable per-stage behavior. By default it is
/// a pass-through (returns the stage unchanged). Records every call.
pub(all) struct RecordingHook {
  mut records : Array[HookRecord]
  abort_on : Map[String, String]
  defer_on : Map[String, String]
}

///|
pub fn RecordingHook::new() -> RecordingHook {
  { records: [], abort_on: Map::from_array([]), defer_on: Map::from_array([]) }
}

///|
/// Configure the hook to abort (HookError::Aborted) when it sees a stage
/// whose debug string contains `trigger`.
pub fn RecordingHook::abort_when(
  self : RecordingHook,
  trigger : String,
  msg : String,
) -> Unit {
  self.abort_on[trigger] = msg
}

///|
/// Configure the hook to defer when it sees a stage whose label contains
/// `trigger`.
pub fn RecordingHook::defer_when(
  self : RecordingHook,
  trigger : String,
  reason : String,
) -> Unit {
  self.defer_on[trigger] = reason
}

///|
pub fn RecordingHook::records(self : RecordingHook) -> Array[HookRecord] {
  self.records.map(fn(record) {
    {
      stage_in: testkit_snapshot_stage(record.stage_in),
      outcome: testkit_snapshot_hook_outcome(record.outcome),
    }
  })
}

///|
pub impl @port.PipelineHook for RecordingHook with fn on_stage(self, stage) {
  let dbg = stage_to_label(stage)
  for trigger in self.abort_on.keys() {
    if dbg.contains(trigger) {
      let message = self.abort_on[trigger]
      self.records.push({
        stage_in: testkit_snapshot_stage(stage),
        outcome: AbortedWith(message),
      })
      return Err(@port.HookError::Aborted(message))
    }
  }
  for trigger in self.defer_on.keys() {
    if dbg.contains(trigger) {
      let reason = self.defer_on[trigger]
      self.records.push({
        stage_in: testkit_snapshot_stage(stage),
        outcome: DeferredWith(reason),
      })
      return Err(@port.HookError::Deferred(reason~))
    }
  }
  self.records.push({
    stage_in: testkit_snapshot_stage(stage),
    outcome: Returned(testkit_snapshot_stage(stage)),
  })
  Ok(stage)
}

///|
/// Minimal label for a Stage variant, used for abort matching.
fn stage_to_label(stage : @port.Stage) -> String {
  match stage {
    @port.BeforeTurn => "BeforeTurn"
    @port.BeforeModel(_) => "BeforeModel"
    @port.AfterModel(_) => "AfterModel"
    @port.ModelError(_) => "ModelError"
    @port.BeforeTool(_) => "BeforeTool"
    @port.AfterTool(_, _) => "AfterTool"
    @port.ToolError(_, _) => "ToolError"
    @port.AfterTurn(_) => "AfterTurn"
    @port.TurnError(_) => "TurnError"
  }
}

// ---------------------------------------------------------------------------
// Trace assertions — structured helpers that report the first differing index.
// ---------------------------------------------------------------------------

///|
/// Return the first structural trace mismatch. Kept pure so conformance tests
/// can prove missing, duplicate, and out-of-order detection without catching
/// an assertion panic.
pub fn event_trace_mismatch(
  expected : Array[@types.TurnEvent],
  actual : Array[@types.TurnEvent],
) -> String? {
  let n = if expected.length() < actual.length() {
    expected.length()
  } else {
    actual.length()
  }
  for i = 0; i < n; i = i + 1 {
    if expected[i] != actual[i] {
      return Some(
        "event_trace_mismatch at index \{i}: expected \{expected[i].to_string()}, got \{actual[i].to_string()}",
      )
    }
  }
  if expected.length() != actual.length() {
    let index = n
    if expected.length() > actual.length() {
      return Some(
        "event_trace_mismatch at index \{index}: expected \{expected[index].to_string()}, got <end> (expected \{expected.length()} events, actual \{actual.length()})",
      )
    } else {
      return Some(
        "event_trace_mismatch at index \{index}: expected <end>, got \{actual[index].to_string()} (expected \{expected.length()} events, actual \{actual.length()})",
      )
    }
  }
  None
}

///|
/// Assert two event traces are equal, reporting the first differing index,
/// the expected and actual event, when they diverge.
pub fn assert_events_eq(
  expected : Array[@types.TurnEvent],
  actual : Array[@types.TurnEvent],
) -> Unit {
  match event_trace_mismatch(expected, actual) {
    Some(message) => abort(message)
    None => ()
  }
}

///|
/// Assert the recorded events contain a sub-sequence matching `needle`, in
/// order. Reports the first needle event that could not be matched.
pub fn assert_events_contain(
  haystack : Array[@types.TurnEvent],
  needle : Array[@types.TurnEvent],
) -> Unit {
  if needle.is_empty() {
    return
  }
  let mut hi = 0
  for ni = 0; ni < needle.length(); ni = ni + 1 {
    let mut found = false
    while hi < haystack.length() {
      if haystack[hi] == needle[ni] {
        found = true
        hi = hi + 1
        break
      }
      hi = hi + 1
    }
    if !found {
      abort(
        "event_not_found_in_order: needle[\{ni}] = \{needle[ni].to_string()} not matched after haystack index \{hi}",
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Testkit constructors — small helpers mirroring the blackbox test helpers.
// ---------------------------------------------------------------------------

///|
/// Build a minimal stop response (no tool calls) for scripted tests.
pub fn tk_stop_response(text : String) -> @types.ModelResponse {
  {
    message: {
      role: @types.Assistant,
      content: [@types.Text(text)],
      tool_calls: [],
      tool_call_id: None,
      name: Some("assistant"),
      reasoning_content: None,
    },
    tool_calls: [],
    finish_reason: @types.Stop,
    usage: None,
    reasoning_content: None,
  }
}

///|
/// Build a response that requests a single tool call.
pub fn tk_tool_call_response(
  tool_name : String,
  call_id : String,
  args : Json,
) -> @types.ModelResponse {
  {
    message: {
      role: @types.Assistant,
      content: [],
      tool_calls: [{ id: call_id, name: tool_name, arguments: args }],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    tool_calls: [{ id: call_id, name: tool_name, arguments: args }],
    finish_reason: @types.ToolCalls,
    usage: None,
    reasoning_content: None,
  }
}

///|
/// Build a user message.
pub fn tk_user_msg(text : String) -> @types.Message {
  {
    role: @types.User,
    content: [@types.Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
}

///|
/// Build a ToolDef with an empty object schema.
pub fn tk_tool_def(name : String, description : String) -> @types.ToolDef {
  {
    name,
    description,
    input_schema: Json::object(Map::from_array([])),
    metadata: None,
    source: None,
  }
}

///|
/// Build a successful ToolResult.
pub fn tk_ok_result(content : String) -> @types.ToolResult {
  { content, structured: None, is_error: false }
}

///|
/// Build a business-error ToolResult (provider returns Ok but is_error=true).
pub fn tk_error_result(content : String) -> @types.ToolResult {
  { content, structured: None, is_error: true }
}

///|
/// Build a default AgentConfig for scripted tests.
pub fn tk_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
}
