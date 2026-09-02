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
/// a concrete array (not Optional), the default `@runtime.PortRuntime` is
/// responsible for filling it with the input messages when the modelport did
/// not preprocess. Tests that drive ScriptedModel directly through the agent
/// pipeline go through `PortRuntime`, which substitutes the actual input
/// messages when `processed_messages` is empty. See
/// `PortRuntime::call_model` for the substitution logic.
pub fn tk_stop_response(text : String) -> @kernel.ModelCallResult {
  let completion : @kernel.Completion = Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
  { completion, processed_messages: [], }
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
  let completion : @kernel.Completion = Completion(
    content=[],
    tool_calls=[call],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  { completion, processed_messages: [], }
}

///|
/// Build a user message.
pub fn tk_user_msg(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
/// Build a system message.
pub fn tk_system_msg(text : String) -> @kernel.Message {
  SystemMessage(content=[Text(text)])
}

///|
/// Build a ToolDef with an empty object schema. Owner is a placeholder —
/// `Agent::build_catalog` derives the catalog owner at composition time.
/// Policy is `Parallel` (the declared default; composition honors it
/// as-is). Provenance is `None`.
pub fn tk_tool_def(name : String, description : String) -> @kernel.ToolDef {
  ToolDef(
    name=@kernel.ToolName::unchecked(name),
    description~,
    input_schema=Json::object(Map::from_array([])),
    owner=@kernel.OwnerId::unchecked("placeholder"),
    policy=Parallel,
    provenance=None,
  )
}

///|
/// Build a successful ToolOutcome.
pub fn tk_ok_result(content : String) -> @kernel.ToolOutcome {
  Success(content~, structured=None)
}

///|
/// Build a business-error ToolOutcome (provider reports a tool-level failure
/// the model should see, but the run continues).
pub fn tk_error_result(content : String) -> @kernel.ToolOutcome {
  ToolReportedError(content~, structured=None)
}

///|
/// Build a default universal AgentConfig for scripted tests.
pub fn tk_config() -> AgentConfig {
  agent_config(max_tool_rounds=Some(10))
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
  { cached: manifest, }
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
/// Scripted `MemoryPort` for agent-level tests of the port contract.
/// Inbound side: `inbounds` entries are returned in call order as the full
/// inbound body (a `None` entry plays an empty read); once the script is
/// exhausted every later call returns `None`. Core calls `inbound` at most
/// once per session lifetime per process and ONLY on the session's first
/// turn, so one entry per session is the natural scripting granularity —
/// `call_count`, `received_sessions`, and `received_requests` are the
/// assertion surface for the once-per-session, first-turn-only, and
/// request-text guarantees.
/// Storage side: `store` records `(content, metadata)` and hands back
/// synthetic tickets (`scripted-0`, `scripted-1`, ...); `delete` records
/// the id; `search_script` entries are returned in call order (a `None`
/// entry plays a no-hit search; exhausted -> `None`) and every call records
/// its `(query, top_k)` — `received_stores`, `received_deletes`, and
/// `received_searches` are the write/read assertion surfaces.
pub(all) struct ScriptedMemoryPort {
  inbounds : Array[String?]
  mut index : Int
  mut calls : Int
  mut sessions : Array[String]
  mut requests : Array[String]
  mut stored : Array[(String, Map[String, Json])]
  mut deleted : Array[String]
  search_script : Array[String?]
  mut search_index : Int
  mut searches : Array[(String, Int?)]
  mut next_ticket : Int
}

///|
pub fn ScriptedMemoryPort::ScriptedMemoryPort(
  inbounds~ : Array[String?],
  search_script? : Array[String?] = [],
) -> ScriptedMemoryPort {
  {
    inbounds,
    index: 0,
    calls: 0,
    sessions: [],
    requests: [],
    stored: [],
    deleted: [],
    search_script,
    search_index: 0,
    searches: [],
    next_ticket: 0,
  }
}

///|
/// Number of `inbound` calls observed so far.
pub fn ScriptedMemoryPort::call_count(self : ScriptedMemoryPort) -> Int {
  self.calls
}

///|
/// Session ids `inbound` was called with, in call order.
pub fn ScriptedMemoryPort::received_sessions(
  self : ScriptedMemoryPort,
) -> Array[String] {
  self.sessions.copy()
}

///|
/// Request texts `inbound` was called with, in call order.
pub fn ScriptedMemoryPort::received_requests(
  self : ScriptedMemoryPort,
) -> Array[String] {
  self.requests.copy()
}

///|
/// (content, metadata) pairs `store` was called with, in call order.
pub fn ScriptedMemoryPort::received_stores(
  self : ScriptedMemoryPort,
) -> Array[(String, Map[String, Json])] {
  self.stored.copy()
}

///|
/// Ids `delete` was called with, in call order.
pub fn ScriptedMemoryPort::received_deletes(
  self : ScriptedMemoryPort,
) -> Array[String] {
  self.deleted.copy()
}

///|
/// (query, top_k) pairs `search` was called with, in call order.
pub fn ScriptedMemoryPort::received_searches(
  self : ScriptedMemoryPort,
) -> Array[(String, Int?)] {
  self.searches.copy()
}

///|
pub impl @port.MemoryPort for ScriptedMemoryPort with fn inbound(
  self : ScriptedMemoryPort,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  self.calls = self.calls + 1
  self.sessions.push(session_id)
  self.requests.push(request)
  if self.index < self.inbounds.length() {
    let value = self.inbounds[self.index]
    self.index = self.index + 1
    value
  } else {
    None
  }
}

///|
pub impl @port.MemoryPort for ScriptedMemoryPort with fn store(
  self : ScriptedMemoryPort,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  let ticket = "scripted-\{self.next_ticket}"
  self.next_ticket = self.next_ticket + 1
  self.stored.push((content, metadata))
  ticket
}

///|
pub impl @port.MemoryPort for ScriptedMemoryPort with fn search(
  self : ScriptedMemoryPort,
  query~ : String,
  top_k? : Int,
) -> String? raise @error.MemoryError {
  self.searches.push((query, top_k))
  if self.search_index < self.search_script.length() {
    let value = self.search_script[self.search_index]
    self.search_index = self.search_index + 1
    value
  } else {
    None
  }
}

///|
pub impl @port.MemoryPort for ScriptedMemoryPort with fn delete(
  self : ScriptedMemoryPort,
  id : String,
) -> Unit raise @error.MemoryError {
  self.deleted.push(id)
}

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
  hooks? : Array[&@port.PipelineHook] = [],
  memory? : Array[&@port.MemoryPort] = [],
  lifecycle? : Array[&@port.Lifecycle] = [],
  commands? : Array[&@port.CommandPort] = [],
  ui? : Array[&@port.UiPort] = [],
  prompt_contributors? : Array[&@port.SystemPromptContributor] = [],
  requires? : Array[@port.Capability] = [],
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
    requires,
  })
}

///|
/// Build a `CompositionView` for unit-testing `Lifecycle::on_compose`
/// implementations: `requires` plays the role of the fake manifest's
/// declaration, and the composed ports stand in for what the composition
/// would have delivered.
pub fn tk_view(
  requires~ : Array[@port.Capability],
  model~ : &@port.ModelPort,
  ui~ : &@port.UiPort,
) -> @port.CompositionView {
  @port.CompositionView::resolve(requires~, model~, ui~)
}

///|
/// RecordingLifecycle — records `Lifecycle` phase invocations for post-hoc
/// assertions. Log entries are `"<id>:compose(model=<Bool>,ui=<Bool>)"`,
/// `"<id>:start"`, `"<id>:shutdown"` in call order. Share one
/// `Array[String]` across several fakes (and other recorders writing the
/// same log) to assert interleaving and ordering.
pub(all) struct RecordingLifecycle {
  id : String
  log : Array[String]
  mut seen_model : Bool
  mut seen_ui : Bool
}

///|
pub fn RecordingLifecycle::RecordingLifecycle(
  id~ : String,
  log~ : Array[String],
) -> RecordingLifecycle {
  { id, log, seen_model: false, seen_ui: false, }
}

///|
pub impl @port.Lifecycle for RecordingLifecycle with fn on_compose(self, ctx) {
  self.seen_model = ctx.model() is Some(_)
  self.seen_ui = ctx.ui() is Some(_)
  self.log.push(
    "\{self.id}:compose(model=\{self.seen_model},ui=\{self.seen_ui})",
  )
}

///|
pub impl @port.Lifecycle for RecordingLifecycle with fn on_start(self) {
  self.log.push("\{self.id}:start")
}

///|
pub impl @port.Lifecycle for RecordingLifecycle with fn on_shutdown(self) {
  self.log.push("\{self.id}:shutdown")
}

///|
/// Expose Lifecycle methods on RecordingLifecycle for dot-syntax callers.
pub extend RecordingLifecycle with @port.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}
