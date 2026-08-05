///|
/// Conformance testkit for Posoco (M0-T04).
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details. Distinct from the minimal Mock* types used by the
/// blackbox tests: the testkit records call order, arguments, and metadata
/// snapshots, and fails loudly when a script is exhausted.
///
/// R3 M3.7: all fixtures use canonical kernel types directly. There is no
/// legacy `@types.Message` / `ModelResponse` / `ToolResult` surface any more.
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
/// Deep-copy a `@kernel.ToolCall`. The `arguments` Json is recursively copied
/// so callers cannot mutate the recorded arguments after the fact.
fn testkit_snapshot_tool_call(call : @kernel.ToolCall) -> @kernel.ToolCall {
  {
    call_id: call.call_id,
    name: call.name,
    arguments: testkit_snapshot_json(call.arguments),
  }
}

///|
/// Deep-copy a `@kernel.ToolDef`.
fn testkit_snapshot_tool_def(tool : @kernel.ToolDef) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=tool.name,
    description=tool.description,
    input_schema=testkit_snapshot_json(tool.input_schema),
    owner=tool.owner,
    policy=tool.policy,
    provenance=tool.provenance,
  )
}

///|
/// Deep-copy a `@kernel.Message`.
fn testkit_snapshot_message(message : @kernel.Message) -> @kernel.Message {
  match message {
    @kernel.SystemMessage(content~) =>
      @kernel.SystemMessage(content=content.map(testkit_snapshot_content))
    @kernel.UserMessage(content~) =>
      @kernel.UserMessage(content=content.map(testkit_snapshot_content))
    @kernel.AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) =>
      @kernel.AssistantMessage(
        content=content.map(testkit_snapshot_content),
        tool_calls=tool_calls.map(testkit_snapshot_tool_call),
        reasoning~,
        finish_reason~,
      )
    @kernel.ToolMessage(call_id~, tool_name~, outcome~) =>
      @kernel.ToolMessage(call_id~, tool_name~, outcome~)
  }
}

///|
fn testkit_snapshot_content(content : @kernel.Content) -> @kernel.Content {
  match content {
    @kernel.Text(text) => @kernel.Text(text)
    @kernel.Image(media_type~, data~) => @kernel.Image(media_type~, data~)
  }
}

///|
fn testkit_snapshot_messages(
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  messages.map(testkit_snapshot_message)
}

///|
/// Deep-copy a `@kernel.ToolOutcome`. Structurally equal to the input —
/// variants carry no caller-mutable references after the copy.
fn testkit_snapshot_tool_outcome_value(
  outcome : @kernel.ToolOutcome,
) -> @kernel.ToolOutcome {
  match outcome {
    @kernel.Success(content~, structured~) =>
      @kernel.Success(
        content~,
        structured=match structured {
          Some(j) => Some(testkit_snapshot_json(j))
          None => None
        },
      )
    @kernel.ToolReportedError(content~, structured~) =>
      @kernel.ToolReportedError(
        content~,
        structured=match structured {
          Some(j) => Some(testkit_snapshot_json(j))
          None => None
        },
      )
    @kernel.RuntimeFailure(error_category~, message~) =>
      @kernel.RuntimeFailure(error_category~, message~)
    @kernel.NotExecuted(reason~, original_call_id~) =>
      @kernel.NotExecuted(reason~, original_call_id~)
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
fn testkit_snapshot_completion(
  completion : @kernel.Completion,
) -> @kernel.Completion {
  let msg = completion.message
  @kernel.Completion(
    content=msg.content.map(testkit_snapshot_content),
    tool_calls=msg.tool_calls.map(testkit_snapshot_tool_call),
    reasoning=msg.reasoning,
    finish_reason=msg.finish_reason,
    usage=completion.usage,
  )
}

///|
fn testkit_snapshot_model_call_result(
  result : @kernel.ModelCallResult,
) -> @kernel.ModelCallResult {
  {
    completion: testkit_snapshot_completion(result.completion),
    processed_messages: testkit_snapshot_messages(result.processed_messages),
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
        result=testkit_snapshot_tool_outcome_value(result),
        is_error~,
      )
    @types.ModelResponseReceived(message~, usage~) =>
      @types.ModelResponseReceived(
        message=testkit_snapshot_message(message),
        usage~,
      )
    @types.SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      @types.SessionRedirect(from~, to~, messages_before~, messages_after~)
    @types.TurnCompleted => @types.TurnCompleted
    @types.TurnFailed(reason) => @types.TurnFailed(reason)
    @types.ToolCallDeferred(call~, reason~) =>
      @types.ToolCallDeferred(call=testkit_snapshot_tool_call(call), reason~)
    @types.StreamChunkReceived(chunk~) => @types.StreamChunkReceived(chunk~)
    @types.ConfigWarning(field~, value~, reason~) =>
      @types.ConfigWarning(field~, value~, reason~)
    @types.ConfigChanged(field~, old_value~, new_value~) =>
      @types.ConfigChanged(field~, old_value~, new_value~)
    @types.Custom(source~, label~, data~) =>
      @types.Custom(source~, label~, data=testkit_snapshot_json(data))
  }
}

// ---------------------------------------------------------------------------
// ScriptedModel — returns responses/errors/stream chunks by call sequence.
// ---------------------------------------------------------------------------

///|
/// A single scripted model interaction. R3 M3.7: each step produces a
/// `ModelCallResult` (the canonical chat return type) instead of the deleted
/// `ModelResponse`. `Stream` carries the chunk sequence plus the final
/// completion; chunks are emitted to the callback during the call.
pub(all) enum ScriptedModelStep {
  Respond(@kernel.ModelCallResult)
  Stream(
    chunks~ : Array[@types.StreamChunk],
    response~ : @kernel.ModelCallResult
  )
  Fail(@error.ModelError)
}

///|
fn testkit_snapshot_model_step(step : ScriptedModelStep) -> ScriptedModelStep {
  match step {
    Respond(result) => Respond(testkit_snapshot_model_call_result(result))
    Stream(chunks~, response~) =>
      Stream(
        chunks=chunks.copy(),
        response=testkit_snapshot_model_call_result(response),
      )
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
  received_messages : Array[Array[@kernel.Message]]
  received_tools : Array[Array[@kernel.ToolDef]]
  received_options : Array[@types.ChatOptions]
  received_chunks : Array[@types.StreamChunk]
}

///|
pub fn ScriptedModel::ScriptedModel(
  steps : Array[ScriptedModelStep],
) -> ScriptedModel {
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
/// Number of chat calls observed so far.
pub fn ScriptedModel::call_count(self : ScriptedModel) -> Int {
  self.calls
}

///|
/// Direct (non-trait) chat entry point for testkit self-tests.
/// Trait methods on concrete types must be dispatched through a `&ModelPort`
/// reference; this wrapper lets tests call chat without an Agent.
pub async fn ScriptedModel::chat_direct(
  self : ScriptedModel,
  messages : Array[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
) -> @kernel.ModelCallResult raise @error.ModelError {
  (self as &@port.ModelPort).chat(messages, tools, options, @types.NoStream)
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
  messages : Array[@kernel.Message],
  tools : Array[@kernel.ToolDef],
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
  messages : Array[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  match self.take_step(messages, tools, options) {
    Respond(result) => testkit_snapshot_model_call_result(result)
    Stream(chunks~, response~) => {
      match stream {
        @types.Stream(cb) =>
          for chunk in chunks {
            self.received_chunks.push(chunk)
            // Decode the chunk to a JSON telemetry payload. The HostChunkCallback
            // consumes raw JSON; we synthesise the same shape
            // PortHostAdapter used to produce so observers that decode JSON
            // chunks continue to work.
            cb(stream_chunk_to_json(chunk))
          }
        @types.NoStream => ()
      }
      testkit_snapshot_model_call_result(response)
    }
    Fail(e) => raise e
  }
}

///|
pub impl @port.ModelPort for ScriptedModel with fn compact(
  _self,
  _messages : Array[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse(
    "ScriptedModel does not implement compact",
  )
}

///|
/// ScriptedModel declares no supported reasoning_effort values. Tests that
/// need to exercise the ConfigWarning path on validation can construct a
/// custom model impl that returns a non-empty `ProviderConfig`.
pub impl @port.ModelPort for ScriptedModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// Encode a StreamChunk as the same JSON shape PortHostAdapter used to emit.
/// Used by ScriptedModel when the caller passes StreamMode::Stream.
fn stream_chunk_to_json(chunk : @types.StreamChunk) -> Json {
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
    @types.ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      let _ = index
      let _ = id
      let _ = name
      let args = match arguments_delta {
        Some(s) => s
        None => ""
      }
      Json::object(
        Map::from_array([
          ("kind", Json::string("tool_call_delta")),
          ("args", Json::string(args)),
        ]),
      )
    }
    @types.Usage(..) =>
      Json::object(Map::from_array([("kind", Json::string("usage"))]))
    @types.Finish(reason~) => {
      let _ = reason
      Json::object(Map::from_array([("kind", Json::string("finish"))]))
    }
  }
}

// ---------------------------------------------------------------------------
// RecordingToolProvider — records list/execute order and configurable outcomes.
// ---------------------------------------------------------------------------

///|
/// Configurable outcome for a tool call: success outcome, or raised runtime
/// error. Constructors are prefixed with `Outcome` to avoid ambiguity with
/// `Result::Ok`/`Result::Err` at unqualified call sites.
pub(all) enum ScriptedToolOutcome {
  OutcomeOk(@kernel.ToolOutcome)
  OutcomeErr(@error.RuntimeError)
}

///|
/// A recorded tool execution: call id, tool name, and outcome.
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
  ExecuteTool(requested_name~ : String, call~ : @kernel.ToolCall)
}

///|
/// ToolProvider fake that declares a fixed tool list and routes execute() by
/// tool name through a configurable outcome map. Unknown tools raise
/// `RuntimeError::UnknownTool`. Every execute is recorded with its call id.
pub(all) struct RecordingToolProvider {
  tool_defs : Array[@kernel.ToolDef]
  outcomes : Map[String, ScriptedToolOutcome]
  mut list_calls : Int
  mut exec_records : Array[ToolExecRecord]
  mut ops : Array[ToolProviderOp]
}

///|
pub fn RecordingToolProvider::RecordingToolProvider(
  tool_defs : Array[@kernel.ToolDef],
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
fn testkit_snapshot_tool_outcome(
  outcome : ScriptedToolOutcome,
) -> ScriptedToolOutcome {
  match outcome {
    OutcomeOk(value) => OutcomeOk(testkit_snapshot_tool_outcome_value(value))
    OutcomeErr(error) => OutcomeErr(error)
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
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
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
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let key = call.name.to_string()
  let outcome = match self.outcomes.get(key) {
    Some(o) => o
    None =>
      OutcomeErr(
        @error.RuntimeError::UnknownTool(
          "recording_tool: no outcome configured for '\{key}'",
        ),
      )
  }
  self.ops.push(
    ExecuteTool(requested_name=name, call=testkit_snapshot_tool_call(call)),
  )
  self.exec_records.push({
    requested_name: name,
    call_id: call.call_id.to_string(),
    tool_name: call.name.to_string(),
    arguments: testkit_snapshot_json(call.arguments),
    outcome: testkit_snapshot_tool_outcome(outcome),
  })
  match outcome {
    OutcomeOk(value) => testkit_snapshot_tool_outcome_value(value)
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
pub fn RecordingSessionStore::RecordingSessionStore() -> RecordingSessionStore {
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
) -> @types.Session raise @error.SessionError {
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
  match result {
    Ok(s) => s
    Err(e) => raise e
  }
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
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
  match result {
    Ok(_) => ()
    Err(e) => raise e
  }
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
pub fn RecordingObserver::RecordingObserver() -> RecordingObserver {
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
// RecordingHook — records hook invocations (native hook traits).
// ---------------------------------------------------------------------------

///|
/// The exact decision made by a RecordingHook invocation.
pub(all) enum RecordedHookOutcome2 {
  PassedThrough
  AbortedWith(String)
  DeferredWith(String)
}

///|
/// A recorded hook invocation: which hook function ran and its decision.
pub(all) struct HookRecord {
  label : String
  outcome : RecordedHookOutcome2
}

///|
/// Multi-hook fake that implements `Hook` at all three interception points.
/// By default it is a pass-through (returns messages unchanged, approves
/// tool calls). Records every call.
pub(all) struct RecordingHook {
  mut records : Array[HookRecord]
  abort_on : Map[String, String]
  defer_on : Map[String, String]
}

///|
pub fn RecordingHook::RecordingHook() -> RecordingHook {
  { records: [], abort_on: Map::from_array([]), defer_on: Map::from_array([]) }
}

///|
/// Configure the hook to abort/reject when the label contains `trigger`.
pub fn RecordingHook::abort_when(
  self : RecordingHook,
  trigger : String,
  msg : String,
) -> Unit {
  self.abort_on[trigger] = msg
}

///|
/// Configure the hook to defer when the label contains `trigger`.
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
    { label: record.label, outcome: record.outcome }
  })
}

///|
pub impl @port.Hook for RecordingHook with fn before_model(
  self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let label = "before_model"
  for trigger in self.abort_on.keys() {
    if label.contains(trigger) ||
      trigger.contains("BeforeModel") ||
      trigger.contains("BeforeTurn") {
      let message = self.abort_on[trigger]
      self.records.push({ label, outcome: AbortedWith(message) })
      raise @port.HookAbort::Aborted(reason=message)
    }
  }
  self.records.push({ label, outcome: PassedThrough })
  messages
}

///|
pub impl @port.Hook for RecordingHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolHookDecision {
  let label = "before_tool"
  let dbg = call.call_id.to_string()
  for trigger in self.abort_on.keys() {
    if dbg.contains(trigger) {
      let message = self.abort_on[trigger]
      self.records.push({ label, outcome: AbortedWith(message) })
      return Reject(reason=message)
    }
  }
  for trigger in self.defer_on.keys() {
    if dbg.contains(trigger) {
      let reason = self.defer_on[trigger]
      self.records.push({ label, outcome: DeferredWith(reason) })
      return Defer(reason~)
    }
  }
  self.records.push({ label, outcome: PassedThrough })
  Approve(call~)
}

///|
pub impl @port.Hook for RecordingHook with fn on_post_event(
  self,
  _stage : @port.HookStage,
) -> Unit {
  let label = "on_post_event"
  self.records.push({ label, outcome: PassedThrough })
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
/// Build a `ModelCallResult` whose completion is a stop-finish text response
/// with no tool calls. The processed_messages is `None`, signalling to the
/// pump that the modelport did no preprocessing and the transcript should be
/// left as-is.
///
/// **Important:** because ModelCallResult requires `processed_messages` to be
/// a concrete array (not Optional), the pump's PortHostAdapter is responsible
/// for filling it with the input messages when the modelport did not
/// preprocess. Tests that drive ScriptedModel directly through the agent
/// pipeline go through PortHostAdapter, which substitutes the actual input
/// messages when `processed_messages` is empty. See
/// `PortHostAdapter::call_model` for the substitution logic.
pub fn tk_stop_response(text : String) -> @kernel.ModelCallResult {
  let completion : @kernel.Completion = @kernel.Completion(
    content=[@kernel.Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
/// Build a `ModelCallResult` whose completion requests a single tool call.
pub fn tk_tool_call_response(
  tool_name : String,
  call_id : String,
  args : Json,
) -> @kernel.ModelCallResult {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked(call_id),
    name: @kernel.ToolName::unchecked(tool_name),
    arguments: args,
  }
  let completion : @kernel.Completion = @kernel.Completion(
    content=[],
    tool_calls=[call],
    reasoning=None,
    finish_reason=@kernel.ToolCalls,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
/// Build a user message.
pub fn tk_user_msg(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
/// Build a system message.
pub fn tk_system_msg(text : String) -> @kernel.Message {
  @kernel.SystemMessage(content=[@kernel.Text(text)])
}

///|
/// Build a ToolDef with an empty object schema. Owner/policy are placeholders
/// — Agent::build_catalog overwrites them at composition time. Provenance is
/// `None`.
pub fn tk_tool_def(name : String, description : String) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=@kernel.ToolName::unchecked(name),
    description~,
    input_schema=Json::object(Map::from_array([])),
    owner=@kernel.OwnerId::unchecked("placeholder"),
    policy=@kernel.Parallel,
    provenance=None,
  )
}

///|
/// Build a successful ToolOutcome.
pub fn tk_ok_result(content : String) -> @kernel.ToolOutcome {
  @kernel.Success(content~, structured=None)
}

///|
/// Build a business-error ToolOutcome (provider reports a tool-level failure
/// the model should see, but the run continues).
pub fn tk_error_result(content : String) -> @kernel.ToolOutcome {
  @kernel.ToolReportedError(content~, structured=None)
}

///|
/// Build a default universal AgentConfig for scripted tests.
pub fn tk_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  }
}

///|
/// Anonymous Extension wrapper around a pre-built `ExtensionManifest`.
///
/// Real extensions implement `Extension` directly on their struct (so the
/// compiler knows the concrete type satisfies every port it contributes).
/// But tests, prototypes, and one-off agents often want to compose ports
/// without defining a fresh named struct. `ManifestOnly` fills that role:
/// build a manifest with `tk_ext`, wrap it, and pass it to `Agent::new` as
/// a `&Extension`.
///
/// This is a testkit-only convenience. Production agents should expose a
/// typed `<ext>_extension()` factory that returns an `ExtensionManifest`
/// from a real struct, not use `ManifestOnly`.
pub(all) struct ManifestOnly {
  cached : @port.ExtensionManifest
}

///|
/// Construct an anonymous Extension from a pre-built manifest.
pub fn ManifestOnly::ManifestOnly(
  manifest : @port.ExtensionManifest,
) -> ManifestOnly {
  { cached: manifest }
}

///|
pub impl @port.Extension for ManifestOnly with fn extension_id(self) -> String {
  self.cached.id
}

///|
pub impl @port.Extension for ManifestOnly with fn manifest(self) -> @port.ExtensionManifest {
  self.cached
}

///|
/// Expose Extension methods on ManifestOnly for dot-syntax callers and so
/// `&ManifestOnly` can be coerced to `&Extension`.
pub extend ManifestOnly with @port.Extension::{extension_id, manifest}

///|
/// Build a `ManifestOnly` extension from labeled optional arguments.
///
/// Every port argument defaults to empty; pick the ones the test needs. The
/// `model` parameter is `&ModelPort?` because at most one model is allowed
/// per agent — `Some(m)` puts it in the manifest's `models` array, `None`
/// leaves models empty (use a different extension to contribute the model).
///
/// Example:
/// ```moonbit nocheck
/// let model = ScriptedModel(..)
/// let tools = RecordingToolProvider(..)
/// let store = RecordingSessionStore()
/// let observer = RecordingObserver()
/// let agent = Agent(
///   exts=[
///     tk_ext("model", model=Some(model)),
///     tk_ext("tools", tools=[tools]),
///     tk_ext("io", sessions=[store], observers=[observer]),
///   ],
///   config=tk_config(),
/// )
/// ```
pub fn tk_ext(
  id~ : String,
  model? : &@port.ModelPort? = None,
  tools? : Array[&@port.ToolProvider] = [],
  sessions? : Array[&@port.SessionStore] = [],
  observers? : Array[&@port.Observer] = [],
  hooks? : Array[&@port.Hook] = [],
  memory? : Array[&@port.MemoryPort] = [],
  lifecycle? : Array[&@port.Lifecycle] = [],
  commands? : Array[&@port.CommandPort] = [],
  ui? : Array[&@port.UiPort] = [],
  prompt_contributors? : Array[&@port.SystemPromptContributor] = [],
) -> ManifestOnly {
  let models : Array[&@port.ModelPort] = match model {
    Some(m) => [m]
    None => []
  }
  ManifestOnly({
    id,
    models,
    tools,
    sessions,
    observers,
    hooks,
    memory,
    lifecycle,
    commands,
    ui,
    prompt_contributors,
  })
}
