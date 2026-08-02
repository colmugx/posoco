///|
/// Agent-level runtime config: provider-agnostic tuning and run budget.
pub(all) struct AgentConfig {
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  model_context_window : Int?
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
  observers : Array[&@port.Observer]
  sessions : Array[&@port.SessionStore]
  lifecycle : Array[&@port.Lifecycle]
  commands : Array[&@port.CommandPort]
  builtin_command_port : BuiltinCommandPort
  config : AgentConfig
  mut next_run_seq : Int
  mut puppet_started : Bool
  mut shutdown_started : Bool
  mut shutdown_complete : Bool
  mut next_lifecycle_shutdown : Int
}

///|
/// Public deep module for agent developers. The runtime representation is a
/// private handle so canonical execution machinery never enters the interface.
pub struct Agent {
  priv runtime : AgentRuntime
}

///|
/// Construct an Agent from an array of extensions.
/// Aggregation order is the array order; collisions fail-fast.
/// At least one extension must contribute a `ModelPort`.
pub fn Agent::Agent(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
) -> Agent raise @error.CompositionError {
  let agg = aggregate_extensions(exts)
  if config.max_tool_rounds < 0 {
    raise @error.CompositionError::ManifestSchemaError(
      manifest_id="agent.config",
      detail="max_tool_rounds must be non-negative",
    )
  }
  match config.model_context_window {
    Some(value) if value <= 0 =>
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="agent.config",
        detail="model_context_window must be positive",
      )
    _ => ()
  }
  if agg.sessions.is_empty() {
    raise @error.CompositionError::EmptyPort("SessionStore")
  }
  let tool_routing = build_tool_routing(agg.tools)
  let catalog = build_agent_catalog(tool_routing.providers)
  let composed_pre_model : Array[&@port.PreModelHook] = []
  // 1. System prompt projection (if any contributors are configured).
  if !agg.prompt_contributors.is_empty() {
    let sections : Array[@port.SystemPromptSection] = []
    let mut idx = 0
    for c in agg.prompt_contributors {
      sections.push(
        @port.SystemPromptSection::SystemPromptSection(
          id="section_\{idx}",
          contributor=c,
        ),
      )
      idx = idx + 1
    }
    let sys_hook = @port.SystemPromptHook::SystemPromptHook(
      base_prompt="", // base comes from a contributor if desired
      contributors=sections,
    )
    composed_pre_model.push(sys_hook as &@port.PreModelHook)
  }

  if !agg.memory.is_empty() {
    let mem_hook = @port.MemoryRetrievalHook::MemoryRetrievalHook(
      memories=agg.memory,
    )
    composed_pre_model.push(mem_hook as &@port.PreModelHook)
  }

  for h in agg.pre_model_hooks {
    composed_pre_model.push(h)
  }

  let composed_post_event : Array[&@port.PostEventHook] = []
  for h in agg.post_event_hooks {
    composed_post_event.push(h)
  }
  let ui_hook = @port.UiRenderHook::UiRenderHook(ui=agg.ui)
  composed_post_event.push(ui_hook as &@port.PostEventHook)

  let mailbox = @puppetry.ControlMailbox::ControlMailbox()
  let mailbox_ref : &@puppetry.Mailbox = mailbox as &@puppetry.Mailbox
  let builtin_command_port = BuiltinCommandPort(mailbox_ref)
  let command_ports = compose_agent_commands(agg.commands, builtin_command_port)
  let host_adapter = PortHostAdapter::new(
    model=agg.model,
    tools=tool_routing.tool_map.copy(),
  )
  let journal = @puppetry.InMemoryJournal::InMemoryJournal()
  let event_subscriber = AgentEventSubscriber(agg.observers)
  let session_store : &@port.SessionStore? = match agg.sessions {
    [first, ..] => Some(first)
    [] => None
  }
  let puppet_config : @puppetry.PuppetConfig = {
    host: host_adapter as &@kernel.HostRuntime,
    catalog,
    journal: journal as &@puppetry.RunJournal,
    contributors: [],
    subscribers: [event_subscriber as &@puppetry.EventSubscriber],
    observers: agg.observers,
    lifecycle_nodes: [],
    stream_chunks: create_agent_stream_callback(agg.observers),
    pre_model_hooks: composed_pre_model,
    pre_tool_hooks: agg.pre_tool_hooks,
    post_event_hooks: composed_post_event,
    max_iterations: config.max_tool_rounds + 1,
    commands: command_ports,
    session_store,
    mailbox: mailbox_ref,
  }
  let runtime : AgentRuntime = {
    puppet: @puppetry.Puppet(puppet_config),
    observers: agg.observers,
    sessions: agg.sessions,
    lifecycle: agg.lifecycle,
    commands: agg.commands,
    builtin_command_port,
    config,
    next_run_seq: 1,
    puppet_started: false,
    shutdown_started: false,
    shutdown_complete: false,
    next_lifecycle_shutdown: agg.lifecycle.length() - 1,
  }
  { runtime, }
}

///|
async fn AgentRuntime::shutdown(self : AgentRuntime) -> Unit {
  if self.shutdown_complete {
    return
  }
  self.shutdown_started = true
  if self.puppet_started {
    self.puppet.shutdown() catch {
      error =>
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(
            "puppet shutdown: " + safe_error_label(error.to_string()),
          ),
        )
    }
    self.puppet_started = false
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
fn agent_error_category(error : @error.AgentError) -> String {
  match error {
    Model(_) => "AgentError::Model"
    Session(_) => "AgentError::Session"
    Runtime(_) => "AgentError::Runtime"
    ToolLoopExceeded => "AgentError::ToolLoopExceeded"
    HookAborted(_) => "AgentError::HookAborted"
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
  event : @types.TurnEvent,
) -> Unit {
  for observer in self.observers {
    observer.on_event(agent_snapshot_turn_event(event))
  }
}

///|
async fn AgentRuntime::ensure_puppet_started(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if self.shutdown_started {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("agent is shut down"),
    )
  }
  if !self.puppet_started {
    self.puppet.startup() catch {
      error =>
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(
            "puppet startup: " + safe_error_label(error.to_string()),
          ),
        )
    }
    self.puppet_started = true
  }
}

///|
/// Run one agent turn. Delegates to Puppet; emits start/end events for observers.
async fn AgentRuntime::run_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  self.ensure_puppet_started()
  self.emit_turn_event(TurnStarted)

  let result = self.run_turn_via_puppet(input, session_id) catch {
    primary => {
      let safe_reason = "turn failed: " + agent_error_category(primary)
      self.emit_turn_event(TurnFailed(safe_reason))
      raise primary
    }
  }

  self.emit_turn_event(TurnCompleted)
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
