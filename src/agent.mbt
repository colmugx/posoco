///|
/// Agent-level runtime config: provider-agnostic tuning and run budget.
/// `max_tool_rounds` bounds the tool rounds of one turn: `Some(n)` allows n
/// full rounds and rejects the (n+1)-th batch atomically; `Some(0)` forbids
/// tool execution; `None` is unbounded (the recommended product default —
/// the human abort and compaction govern loop length, matching peer coding
/// agents).
pub(all) struct AgentConfig {
  max_tool_rounds : Int?
  temperature : Double?
  max_output_tokens : Int?
  model_context_window : Int?
  /// Host override for the auto-compact trigger point as a fraction of the
  /// context window, in (0, 1]. `None` defers to the active modelport's
  /// reported `compact_threshold`, falling back to the core default (0.88).
  compact_threshold : Double?
}

///|
/// Encode the provider-agnostic chat options for `RunPolicy.call_options`.
/// Provider-specific configuration belongs to the ModelPort extension and
/// never crosses the canonical HostRuntime seam.
fn AgentConfig::to_chat_options_to_json(self : AgentConfig) -> Json {
  let fields : Map[String, Json] = Map::from_array([])
  match self.temperature {
    Some(t) => fields["temperature"] = Json::number(t)
    None => ()
  }
  match self.max_output_tokens {
    Some(n) => fields["max_output_tokens"] = Json::number(n.to_double())
    None => ()
  }
  Json::object(fields)
}

///|
/// Internal routing table: tool name → owning provider. Built during Agent::new.
priv struct ToolRouting {
  tool_map : Map[String, &@port.ToolProvider]
  providers : Array[&@port.ToolProvider]
}

///|
fn safe_error_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}

///|
fn agent_snapshot_json(value : Json) -> Json {
  match value {
    Json::Array(items) => Json::array(items.map(agent_snapshot_json))
    Json::Object(fields) => {
      let snapshot : Map[String, Json] = Map::from_array([])
      for key in fields.keys() {
        snapshot[key] = agent_snapshot_json(fields[key])
      }
      Json::object(snapshot)
    }
    scalar => scalar
  }
}

///|
fn agent_snapshot_tool_call(call : @kernel.ToolCall) -> @kernel.ToolCall {
  {
    call_id: call.call_id,
    name: call.name,
    arguments: agent_snapshot_json(call.arguments),
  }
}

///|
fn agent_snapshot_content(content : @kernel.Content) -> @kernel.Content {
  match content {
    @kernel.Text(text) => @kernel.Text(text)
    @kernel.Image(media_type~, data~) => @kernel.Image(media_type~, data~)
  }
}

///|
fn agent_snapshot_message(message : @kernel.Message) -> @kernel.Message {
  match message {
    @kernel.SystemMessage(content~) =>
      @kernel.SystemMessage(content=content.map(agent_snapshot_content))
    @kernel.UserMessage(content~) =>
      @kernel.UserMessage(content=content.map(agent_snapshot_content))
    @kernel.AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) =>
      @kernel.AssistantMessage(
        content=content.map(agent_snapshot_content),
        tool_calls=tool_calls.map(agent_snapshot_tool_call),
        reasoning~,
        finish_reason~,
      )
    @kernel.ToolMessage(call_id~, tool_name~, outcome~) =>
      @kernel.ToolMessage(call_id~, tool_name~, outcome~)
  }
}

///|
fn agent_snapshot_messages(
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  messages.map(agent_snapshot_message)
}

///|
fn agent_snapshot_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let snapshot : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    snapshot[key] = agent_snapshot_json(metadata[key])
  }
  snapshot
}

///|
fn agent_snapshot_session(
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> @types.Session {
  {
    messages: agent_snapshot_messages(messages),
    metadata: agent_snapshot_metadata(metadata),
  }
}

///|
fn agent_snapshot_tool_outcome(
  outcome : @kernel.ToolOutcome,
) -> @kernel.ToolOutcome {
  match outcome {
    @kernel.Success(content~, structured~) =>
      @kernel.Success(
        content~,
        structured=match structured {
          Some(j) => Some(agent_snapshot_json(j))
          None => None
        },
      )
    @kernel.ToolReportedError(content~, structured~) =>
      @kernel.ToolReportedError(
        content~,
        structured=match structured {
          Some(j) => Some(agent_snapshot_json(j))
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
fn tool_provenance(tool : @kernel.ToolDef) -> String {
  match tool.provenance {
    Some(source) if source != "" =>
      "ToolDef.provenance='\{safe_error_label(source)}'"
    _ =>
      "unlabeled provider declaring '\{safe_error_label(tool.name.to_string())}' (set ToolDef.provenance to a stable provider id)"
  }
}

///|
/// Build the tool routing table. Raises CompositionError::ToolCollision on
/// the FIRST name collision (fail-fast), rather than last-wins. The
/// collision message identifies the tool name and a provenance hint for each
/// conflicting provider (ToolDef.provenance if present, else an actionable marker).
fn build_tool_routing(
  tools : Array[&@port.ToolProvider],
) -> ToolRouting raise @error.CompositionError {
  let tool_map : Map[String, &@port.ToolProvider] = Map::from_array([])
  let owner_source : Map[String, String] = Map::from_array([])
  for provider in tools {
    let tool_defs = provider.list_tools()
    for tool in tool_defs {
      let name = tool.name.to_string()
      let provenance = tool_provenance(tool)
      if tool_map.contains(name) {
        // T06-B: fail-fast on collision. The error names the tool and both
        // sources so the caller can locate the conflict without guessing.
        let prev_source = match owner_source.get(name) {
          Some(s) => s
          None => "(unknown)"
        }
        raise @error.CompositionError::ToolCollision(
          safe_error_label(name),
          "tool collision; first declaration: \{prev_source}; conflicting declaration: \{provenance}",
          manifests=[],
        )
      }
      tool_map[name] = provider
      owner_source[name] = provenance
    }
  }
  { tool_map, providers: tools }
}

///|
/// Private mutable implementation owned by the Agent facade.
priv struct AgentRuntime {
  puppet : @puppetry.Puppet
  /// The aggregated ModelPort, queried per turn for the active model's
  /// self-reported context window / compact threshold. Reference equality
  /// with the port the Puppet executes through — no second composition path.
  model : &@port.ModelPort
  observers : Array[&@port.Observer]
  /// The composed hook chain in interception order — the same array the
  /// Puppet executes — retained for Agent-level dispatch points that fire
  /// outside the pump (`PipelineHook::on_turn_end`).
  hooks : Array[&@port.PipelineHook]
  sessions : Array[&@port.SessionStore]
  lifecycle : Array[&@port.Lifecycle]
  commands : Array[&@port.CommandPort]
  builtin_command_port : BuiltinCommandPort
  control : @runtime.RuntimeControl
  config : AgentConfig
  /// Host-owned versioned catalog (experimental runtime seam). `None` keeps
  /// the static composition-time snapshot for the Agent's lifetime.
  catalog_source : &@runtime.CatalogSource?
  /// The source revision last read (0 = no source / not yet read).
  mut last_catalog_revision : Int
  /// Next monotonic catalog version to assign on a successful refresh.
  /// Composition builds version 1; refreshes hand out 2, 3, ...
  mut next_catalog_version : Int
  mut next_run_seq : Int
  mut shutdown_started : Bool
  mut shutdown_complete : Bool
  mut next_lifecycle_shutdown : Int
  /// Whether lifecycle contributors have received their once-per-Agent
  /// `on_start` notification. Fired inside the first `run_single_turn`,
  /// after the shutdown guard and before the first `TurnStarted`.
  mut start_notified : Bool
  /// Per-turn chunk dispatcher handle. The callback installed in the Puppet
  /// reads this reference to route `StreamChunk` events to the active turn's
  /// buffered queue; `run_turn_via_puppet` creates and swaps the dispatcher
  /// for each turn.
  chunk_dispatcher : Ref[ChunkDispatcher?]
  /// Per-session cursor tracking how many leading messages are already
  /// persisted. Reset to the loaded session length on load and advanced to
  /// the final transcript length on every successful save.
  session_cursors : Map[String, Int]
}

///|
/// Public deep module for agent developers. The runtime representation is a
/// private handle so canonical execution machinery never enters the interface.
pub struct Agent {
  priv runtime : AgentRuntime
}

///|
/// Shared composition path for both public constructors. `host_override`
/// is `Some(shimmed runtime)` for `Agent::with_runtime`; `None` builds the
/// default `PortRuntime` over the aggregated ports and shims it through the
/// same path — there is exactly one way to assemble an Agent.
///
/// `catalog_source` (experimental runtime seam): when `Some`, the tool
/// catalog is owned by the source — built from its definitions at
/// composition and rebuilt at prompt boundaries when its revision changes.
/// When `None`, the catalog is the static snapshot of the aggregated
/// `ToolProvider` declarations.
fn AgentRuntime::compose(
  agg : AggregatedPorts,
  config : AgentConfig,
  ui_projection : Bool,
  host_override : &@kernel_exec.HostRuntime?,
  catalog_source : &@runtime.CatalogSource?,
) -> Agent raise @error.CompositionError {
  match config.max_tool_rounds {
    Some(value) if value < 0 =>
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="agent.config",
        detail="max_tool_rounds must be non-negative",
      )
    _ => ()
  }
  match config.model_context_window {
    Some(value) if value <= 0 =>
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="agent.config",
        detail="model_context_window must be positive",
      )
    _ => ()
  }
  match config.compact_threshold {
    Some(value) if value <= 0.0 || value > 1.0 =>
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="agent.config",
        detail="compact_threshold must be in (0, 1]",
      )
    _ => ()
  }
  if agg.sessions.is_empty() {
    raise @error.CompositionError::EmptyPort("SessionStore")
  }
  let tool_routing = build_tool_routing(agg.tools)
  // A wired CatalogSource owns the catalog from the start: the initial
  // snapshot comes from its definitions (version 1), and the composition
  // fails fast if those definitions are invalid. Otherwise the catalog is
  // the static port-derived snapshot.
  let (catalog, initial_catalog_revision) = match catalog_source {
    Some(source) =>
      (
        build_catalog_from_defs(source.tools(), @kernel.CatalogVersion(1)),
        source.revision(),
      )
    None => (build_agent_catalog(tool_routing.providers), 0)
  }
  // One composed hook chain, in interception order: system-prompt
  // projection first, memory retrieval second, extension-registered hooks
  // next, UI rendering last (opt-in, so extensions see events before the
  // renderer).
  let composed_hooks : Array[&@port.PipelineHook] = []
  // 1. System prompt projection (if any contributors are configured).
  if !agg.prompt_contributors.is_empty() {
    let sections : Array[SystemPromptSection] = []
    for pair in agg.prompt_contributors {
      let (mid, contributor) = pair
      sections.push(
        SystemPromptSection::SystemPromptSection(id=mid, contributor~),
      )
    }
    let sys_hook = SystemPromptHook::SystemPromptHook(
      base_prompt="", // base comes from a contributor if desired
      contributors=sections,
    )
    composed_hooks.push(sys_hook as &@port.PipelineHook)
  }

  if !agg.memory.is_empty() {
    let observers = agg.observers
    let mem_hook = MemoryRetrievalHook::MemoryRetrievalHook(
      memories=agg.memory,
      on_failure=fn(reason) {
        emit_secondary_failure(observers, "memory_retrieval", reason)
      },
    )
    composed_hooks.push(mem_hook as &@port.PipelineHook)
  }

  for h in agg.hooks {
    composed_hooks.push(h)
  }

  // UI projection is opt-in (BR-5): the built-in render policy is installed
  // only when the host asks for it via `ui_projection=true`.
  if ui_projection {
    let ui_hook = UiRenderHook::UiRenderHook(ui=agg.ui)
    composed_hooks.push(ui_hook as &@port.PipelineHook)
  }

  let mailbox = @puppetry.ControlMailbox::ControlMailbox()
  let mailbox_ref : &@puppetry.Mailbox = mailbox as &@puppetry.Mailbox
  let builtin_command_port = BuiltinCommandPort(mailbox_ref)
  let command_ports = compose_agent_commands(agg.commands, builtin_command_port)
  let host : &@kernel_exec.HostRuntime = match host_override {
    Some(h) => h
    None => {
      let port_runtime = @runtime.PortRuntime(
        model=agg.model,
        tools=tool_routing.tool_map.copy(),
      )
      RuntimeHostShim(port_runtime as &@runtime.Runtime)
      as &@kernel_exec.HostRuntime
    }
  }
  let journal = @puppetry.InMemoryJournal::InMemoryJournal()
  let chunk_dispatcher_ref : Ref[ChunkDispatcher?] = Ref::Ref(None)
  let event_subscriber = AgentEventSubscriber(
    agg.observers,
    chunk_dispatcher_ref,
  )
  let session_store : &@port.SessionStore? = match agg.sessions {
    [first, ..] => Some(first)
    [] => None
  }
  let puppet_config : @puppetry.PuppetConfig = {
    host,
    catalog,
    journal: journal as &@puppetry.RunJournal,
    contributors: [],
    subscribers: [event_subscriber as &@puppetry.EventSubscriber],
    stream_chunks: create_agent_stream_callback(
      agg.observers,
      chunk_dispatcher_ref,
    ),
    hooks: composed_hooks,
    max_iterations: match config.max_tool_rounds {
      // The pump burns 2 iterations per tool round (AwaitingModel +
      // AwaitingTools) plus one terminal iteration. Size the backstop so
      // the kernel budget is always the limit that fires first; with an
      // unbounded budget there is no pump cap either.
      Some(rounds) => Some(2 * rounds + 1)
      None => None
    },
    commands: command_ports,
    session_store,
    mailbox: mailbox_ref,
  }
  // Deliver composed capabilities to lifecycle contributors, in
  // registration order. Every composition gate has passed by this point
  // (config checks, session presence, collision checks, atomic catalog), so
  // the view carries the final composed ports. An extension raising here
  // (e.g. CompositionError::ExtensionComposeFailed for an undeclared
  // capability) fails the composition loudly; no partial Agent is produced.
  for entry in agg.lifecycle {
    let view = @port.CompositionView::resolve(
      requires=entry.requires,
      model=agg.model,
      ui=agg.ui,
    )
    entry.port.on_compose(view)
  }
  let runtime : AgentRuntime = {
    puppet: @puppetry.Puppet(puppet_config),
    model: agg.model,
    observers: agg.observers,
    hooks: composed_hooks,
    sessions: agg.sessions,
    lifecycle: agg.lifecycle.map(fn(entry) { entry.port }),
    commands: agg.commands,
    builtin_command_port,
    control: @runtime.RuntimeControl(mailbox_ref),
    config,
    catalog_source,
    last_catalog_revision: initial_catalog_revision,
    next_catalog_version: 2,
    next_run_seq: 1,
    shutdown_started: false,
    shutdown_complete: false,
    next_lifecycle_shutdown: agg.lifecycle.length() - 1,
    start_notified: false,
    chunk_dispatcher: chunk_dispatcher_ref,
    session_cursors: Map::from_array([]),
  }
  { runtime, }
}

///|
/// Construct an Agent from an array of extensions.
/// Aggregation order is the array order; collisions fail-fast.
/// At least one extension must contribute a `ModelPort`.
///
/// `ui_projection` (default `false`, BR-5): when `true`, Posoco's built-in
/// render policy (`UiRenderHook` over the aggregated `UiPort`) is appended
/// to the hook chain. Hosts with their own UI policy leave it off and
/// register their own `PipelineHook` instead.
pub fn Agent::Agent(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  ui_projection? : Bool = false,
) -> Agent raise @error.CompositionError {
  let agg = aggregate_extensions(exts)
  AgentRuntime::compose(agg, config, ui_projection, None, None)
}

///|
/// Advanced constructor (experimental runtime seam): same Agent, same
/// default assembly, but the caller supplies the effect-execution runtime.
/// `runtime` is typically a wrapper around `@runtime.PortRuntime` that
/// overrides only the methods it needs (e.g. `execute_tool` +
/// `cancel_effects` for cancellation propagation). Plain extension authors
/// do not need this — see `docs/RUNTIME.md`.
///
/// `catalog_source` (optional): when supplied, the source owns the tool
/// catalog — Posoco reads it at construction and re-reads it at each prompt
/// boundary whose `revision()` changed, swapping the refreshed snapshot in
/// for subsequent runs while in-flight runs keep their version. Definitions
/// are taken verbatim (owner/policy respected). Without it, the catalog is
/// the static snapshot of the aggregated `ToolProvider` declarations.
pub fn Agent::with_runtime(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  runtime~ : &@runtime.Runtime,
  ui_projection? : Bool = false,
  catalog_source? : &@runtime.CatalogSource,
) -> Agent raise @error.CompositionError {
  let agg = aggregate_extensions(exts)
  AgentRuntime::compose(
    agg,
    config,
    ui_projection,
    Some(RuntimeHostShim(runtime) as &@kernel_exec.HostRuntime),
    catalog_source,
  )
}

///|
async fn AgentRuntime::shutdown(self : AgentRuntime) -> Unit {
  if self.shutdown_complete {
    return
  }
  self.shutdown_started = true
  self.puppet.shutdown() catch {
    error =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet shutdown: " + safe_error_label(error.to_string()),
        ),
      )
  }
  while self.next_lifecycle_shutdown >= 0 {
    // Advance the cursor only after successful cleanup. If an extension
    // shutdown fails, the error remains loud and a retry resumes at the
    // failing extension instead of skipping it or repeating completed ones.
    self.lifecycle[self.next_lifecycle_shutdown].on_shutdown()
    self.next_lifecycle_shutdown = self.next_lifecycle_shutdown - 1
  }
  self.shutdown_complete = true
}

///|
fn agent_error_category(error : Error) -> String {
  match error {
    @error.AgentError::Model(_) => "AgentError::Model"
    @error.AgentError::Session(_) => "AgentError::Session"
    @error.AgentError::Runtime(_) => "AgentError::Runtime"
    @error.AgentError::ToolLoopExceeded(..) => "AgentError::ToolLoopExceeded"
    @error.AgentError::PipelineAborted(_) => "AgentError::PipelineAborted"
    _ => "Unclassified"
  }
}

///|
fn session_error_category(error : @error.SessionError) -> String {
  match error {
    Load(_) => "SessionError::Load"
    Save(_) => "SessionError::Save"
  }
}

///|
fn contextualize_session_error(
  error : @error.SessionError,
  session_id : String,
  operation : String,
) -> @error.AgentError {
  let context = "session_id='\{safe_error_label(session_id)}', operation='\{operation}', category='\{session_error_category(error)}', cause='\{safe_error_label(error.to_string())}'"
  @error.AgentError::Session(
    match error {
      Load(_) => @error.SessionError::Load(context)
      Save(_) => @error.SessionError::Save(context)
    },
  )
}

///|
/// Contextualize a generic `Error` raised by a parallel session-save wave as a
/// `SessionError::Save`. The thunks themselves return `Result[Unit,
/// SessionError]`, so this path only handles async-runtime/cancellation errors
/// that escape `@async.all` itself.
fn save_error_context(
  error : Error,
  session_id : String,
  operation : String,
) -> @error.AgentError {
  let context = "session_id='\{safe_error_label(session_id)}', operation='\{operation}', category='SessionError::Save', cause='\{safe_error_label(error.to_string())}'"
  @error.AgentError::Session(@error.SessionError::Save(context))
}

///|
fn @types.TurnEvent::tool_call_result(
  call : @kernel.ToolCall,
  result : @kernel.ToolOutcome,
) -> @types.TurnEvent {
  ToolCallResult(call~, result~, is_error=result.is_failure())
}

///|
fn agent_snapshot_turn_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    TurnStarted => TurnStarted
    ToolCallPending(call) => ToolCallPending(agent_snapshot_tool_call(call))
    ToolCallResult(call~, result~, ..) =>
      @types.TurnEvent::tool_call_result(
        agent_snapshot_tool_call(call),
        agent_snapshot_tool_outcome(result),
      )
    ModelResponseReceived(message~, usage~) =>
      ModelResponseReceived(message=agent_snapshot_message(message), usage~)
    SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      SessionRedirect(from~, to~, messages_before~, messages_after~)
    TurnCompleted => TurnCompleted
    TurnFailed(reason) => TurnFailed(reason)
    ToolCallDeferred(call~, reason~) =>
      ToolCallDeferred(call=agent_snapshot_tool_call(call), reason~)
    StreamChunkReceived(chunk~) => StreamChunkReceived(chunk~)
    StreamChunksDropped(count~) => StreamChunksDropped(count~)
    ConfigWarning(field~, value~, reason~) =>
      ConfigWarning(field~, value~, reason~)
    ConfigChanged(field~, old_value~, new_value~) =>
      ConfigChanged(field~, old_value~, new_value~)
    Custom(source~, label~, data~) =>
      Custom(source~, label~, data=agent_snapshot_json(data))
  }
}

///|
fn AgentRuntime::emit_turn_event(
  self : AgentRuntime,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  for observer in self.observers {
    observer.on_event_at(scope, agent_snapshot_turn_event(event))
  }
}

///|
/// Dispatch `PipelineHook::on_turn_begin` in registration order, after the
/// `TurnStarted` observer projection and before the pump's first
/// `before_model`. Symmetric with `dispatch_on_turn_end`: pre-turn failures
/// (the shutdown guard, a lifecycle `on_start` raise) dispatch nothing — the
/// turn never began. A raise is a secondary failure: observers get a
/// `secondary_failure` event, the turn still proceeds, and later hooks still
/// run. A cancellation error is not a defect and is not reported.
async fn AgentRuntime::dispatch_on_turn_begin(
  self : AgentRuntime,
) -> Unit noraise {
  for hook in self.hooks {
    hook.on_turn_begin() catch {
      error =>
        if !@async.is_cancellation_error(error) {
          emit_secondary_failure(
            self.observers,
            "on_turn_begin",
            error.to_string(),
          )
        }
    }
  }
}

///|
/// Dispatch `PipelineHook::on_turn_end` in registration order, after the terminal
/// observer projection and just before `run_single_turn` returns. Dispatched
/// on both the completed and the failed path. The terminal outcome is not a
/// payload — hooks read it from the Observer channel (`TurnCompleted` /
/// `TurnFailed`), which fires first. A raise
/// is a secondary failure: observers get a `secondary_failure` event, the
/// turn's primary outcome is never replaced, and later hooks still run. A
/// cancellation error is not a defect and is not reported.
async fn AgentRuntime::dispatch_on_turn_end(
  self : AgentRuntime,
) -> Unit noraise {
  for hook in self.hooks {
    hook.on_turn_end() catch {
      error =>
        if !@async.is_cancellation_error(error) {
          emit_secondary_failure(
            self.observers,
            "on_turn_end",
            error.to_string(),
          )
        }
    }
  }
}

///|
/// Emit a sanitized secondary-failure diagnostic to every observer's
/// session-level channel. Secondary failures never replace the primary
/// outcome; the payload carries only a bounded category label, never the
/// failing component's raw payload. (`Observer::on_event` is non-raising
/// by contract — a violating observer aborts loudly, which the ADR's
/// error-transparency rules intentionally preserve.)
fn emit_secondary_failure(
  observers : Array[&@port.Observer],
  hook_point : String,
  detail : String,
) -> Unit {
  let event : @types.TurnEvent = Custom(
    source="posoco.core",
    label="secondary_failure",
    data=Json::object(
      Map::from_array([
        ("hook_point", Json::string(hook_point)),
        ("error", Json::string(safe_error_label(detail))),
      ]),
    ),
  )
  for observer in observers {
    // Secondary failures are emitted from hook closures and refresh paths
    // that hold no run identity — scope is None by design (v1).
    observer.on_event_at(None, agent_snapshot_turn_event(event))
  }
}

///|
fn AgentRuntime::ensure_agent_running(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if self.shutdown_started {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("agent is shut down"),
    )
  }
}

///|
/// Cap on follow-up turns drained within a single `run_turn` call, aligned
/// with the control queue bound. Prevents an unbounded follow-up chain from
/// monopolising one call; leftovers stay queued for the next call.
let follow_up_drain_limit : Int = 64

///|
/// Run one agent turn, then drain any follow-ups submitted while it (or a
/// drained follow-up turn) was in flight. Each drained follow-up drives its
/// own full turn on the same session — same boundaries, same observer
/// events — and the last turn's `TurnResult` is returned.
async fn AgentRuntime::run_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  let mut result = self.run_single_turn(input, session_id)
  let mut drained = 0
  while drained < follow_up_drain_limit {
    match self.control.take_follow_up() {
      Some(message) => {
        drained = drained + 1
        result = self.run_single_turn(message, session_id)
      }
      None => break
    }
  }
  result
}

///|
/// Run exactly one turn: delegate to Puppet; emit start/end events for
/// observers.
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_single_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  self.ensure_agent_running()
  if !self.start_notified {
    // Once-per-Agent boot notification, in registration order, before the
    // first TurnStarted is projected. A raised error is wrapped loud and the
    // turn fails before any terminal event (consistent with pre-TurnStarted
    // failures emitting neither TurnStarted nor TurnFailed).
    for lc in self.lifecycle {
      lc.on_start() catch {
        error =>
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "lifecycle on_start: " + safe_error_label(error.to_string()),
            ),
          )
      }
    }
    self.start_notified = true
  }
  // Mint run/turn identity up front so even TurnStarted carries attribution
  // scope; the same identity drives the Puppet request below.
  let identity = self.mint_turn_identity(session_id)
  self.emit_turn_event(Some(identity.scope()), TurnStarted)
  // Turn-begin hooks fire after the TurnStarted projection and before the
  // pump's first before_model. Pre-turn failures above dispatch nothing —
  // symmetric with on_turn_end's terminal-position semantics.
  self.dispatch_on_turn_begin()

  let result = self.run_turn_via_puppet(input, session_id, identity) catch {
    primary => {
      let safe_reason = "turn failed: " + agent_error_category(primary)
      self.emit_turn_event(Some(identity.scope()), TurnFailed(safe_reason))
      self.dispatch_on_turn_end()
      raise primary
    }
  }

  self.emit_turn_event(Some(identity.scope()), TurnCompleted)
  self.dispatch_on_turn_end()
  result
}

///|
pub async fn Agent::run_turn(
  self : Agent,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  self.runtime.run_turn(input, session_id)
}

///|
pub async fn Agent::shutdown(self : Agent) -> Unit {
  self.runtime.shutdown()
}

///|
/// The Agent's control handle (experimental runtime seam). Advanced hosts
/// use it to abort the active run or to submit follow-up messages that the
/// Agent consumes at turn boundaries. The handle is identity-guarded:
/// submissions against a stale or absent run are rejected at enqueue time.
pub fn Agent::control(self : Agent) -> @runtime.RuntimeControl {
  self.runtime.control
}
