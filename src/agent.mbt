///|
/// Agent-level runtime config: provider-agnostic tuning and run budget.
pub struct AgentConfig {
  max_tool_rounds : Int32?
  max_tool_calls : Int32?
  max_tool_depth : Int32?
  temperature : Double?
  max_output_tokens : Int32?
  model_context_window : Int32?
  /// Host override for the auto-compact trigger point as a fraction of the
  /// context window, in (0, 1]. `None` defers to the active modelport's
  /// reported `compact_threshold`, falling back to the core default (0.88).
  compact_threshold : Double?
  /// Optional base system prompt. When non-empty, or when any extension
  /// registers `SystemPromptContributor`s, Posoco prepends one stable
  /// SystemMessage assembled from this base plus contributor sections.
  system_prompt : String?
  /// Optional per-provider cap for the session-opening `MemoryPort::inbound`
  /// read, in milliseconds. `None` means no timeout.
  memory_inbound_timeout_ms : Int32?
}

///|
/// Construct an `AgentConfig` naming only the knobs you set; every omitted
/// knob is `None`.
pub fn agent_config(
  max_tool_rounds~ : Int32? = None,
  max_tool_calls~ : Int32? = None,
  max_tool_depth~ : Int32? = None,
  temperature~ : Double? = None,
  max_output_tokens~ : Int32? = None,
  model_context_window~ : Int32? = None,
  compact_threshold~ : Double? = None,
  system_prompt~ : String? = None,
  memory_inbound_timeout_ms~ : Int32? = None,
) -> AgentConfig {
  {
    max_tool_rounds,
    max_tool_calls,
    max_tool_depth,
    temperature,
    max_output_tokens,
    model_context_window,
    compact_threshold,
    system_prompt,
    memory_inbound_timeout_ms,
  }
}

///|
fn AgentConfig::to_runtime_config(
  self : AgentConfig,
) -> @agent_runtime.RuntimeConfig {
  {
    max_tool_rounds: self.max_tool_rounds,
    max_tool_calls: self.max_tool_calls,
    max_tool_depth: self.max_tool_depth,
    temperature: self.temperature,
    max_output_tokens: self.max_output_tokens,
    model_context_window: self.model_context_window,
    compact_threshold: self.compact_threshold,
    system_prompt: self.system_prompt,
    memory_inbound_timeout_ms: self.memory_inbound_timeout_ms,
  }
}

///|
/// Public deep module for agent developers.
pub struct Agent {
  priv runtime : @agent_runtime.AgentRuntime
}

///|
/// Construct an Agent from an array of extensions.
/// Aggregation order is the array order; collisions fail-fast.
/// At least one extension must contribute a `ModelPort`.
/// `events` transfers one host-created EventSystem to this Agent exclusively.
pub fn Agent::Agent(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  events~ : EventSystem,
  ui_projection~ : Bool = false,
) -> Agent raise @error.CompositionError {
  let event_runtime = events.claim()
  errdefer event_runtime.close()
  let runtime = @agent_runtime.AgentRuntime::compose(
    exts~,
    config=config.to_runtime_config(),
    events=event_runtime,
    ui_projection~,
  )
  { runtime, }
}

///|
/// Advanced constructor (experimental runtime seam): same Agent, same
/// default assembly, but the caller supplies the effect-execution runtime.
pub fn Agent::with_runtime(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  events~ : EventSystem,
  runtime~ : &@runtime.Runtime,
  ui_projection~ : Bool = false,
) -> Agent raise @error.CompositionError {
  let event_runtime = events.claim()
  errdefer event_runtime.close()
  let agent_runtime = @agent_runtime.AgentRuntime::compose(
    exts~,
    config=config.to_runtime_config(),
    events=event_runtime,
    ui_projection~,
    host_override=Some(runtime),
  )
  { runtime: agent_runtime, }
}

///|
/// Own an Agent and all of its managed work for one structured lifetime.
pub async fn[X] Agent::run_scoped(self : Agent, body : async (Agent) -> X) -> X {
  self.runtime.run_scoped_with(async fn() { body(self) })
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
/// Resume an interrupted turn from its persisted transcript.
pub async fn Agent::resume_turn(
  self : Agent,
  session_id : String,
  continuation~ : String = "continue",
) -> @types.TurnResult raise @error.AgentError {
  self.runtime.resume_turn(session_id, continuation~)
}

///|
pub async fn Agent::compact_session(
  self : Agent,
  session_id : String,
) -> @types.CompactOutcome raise @error.AgentError {
  self.runtime.compact_session(session_id)
}

///|
pub async fn Agent::context_state(
  self : Agent,
  session_id : String,
) -> @types.ContextState? {
  self.runtime.context_state(session_id)
}

///|
pub async fn Agent::shutdown(self : Agent) -> Unit {
  self.runtime.shutdown()
}

///|
/// Bind the host's currently active window session (`None` clears the binding).
pub fn Agent::set_active_session(self : Agent, session_id : String?) -> Unit {
  self.runtime.set_active_session(session_id)
}

///|
/// Host entry to the UI resource protocol.
pub fn Agent::ui_host(self : Agent) -> @port.UiHost {
  self.runtime.ui_host()
}

///|
/// The Agent's control handle (experimental runtime seam).
pub fn Agent::control(self : Agent) -> AgentControl {
  { core: self.runtime.control(), }
}

///|
/// Listen to this Agent's notifications without acquiring publication rights.
pub fn Agent::subscribe_events(
  self : Agent,
  handler : (@events.EventEnvelope) -> Unit,
  namespace_~ : @events.EventNamespace? = None,
) -> Result[@events.Subscription, @events.EventError] {
  self.runtime.subscribe_events(handler, namespace_~)
}

///|
pub fn Agent::commands(self : Agent) -> Array[&@port.CommandPort] {
  self.runtime.commands()
}
