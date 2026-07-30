///|
/// Agent-level runtime config: model, tuning knobs, and budget.
/// Config changes propagate via setters that emit `TurnEvent` for observers.
pub(all) struct AgentConfig {
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  mut tool_choice : String?
  mut reasoning_effort : String?
  model_context_window : Int?
  /// Active model name. Read from `call_options` by the ModelPort on next `chat()`.
  mut model : String?
}

///|
pub fn AgentConfig::to_chat_options(self : AgentConfig) -> @types.ChatOptions {
  { temperature: self.temperature, max_output_tokens: self.max_output_tokens }
}

///|
/// Encode the chat options as an opaque JSON blob for the Puppet's
/// `call_options` field. The PortHostAdapter passes this blob through to the
/// modelport; the modelport decodes whatever fields it understands.
pub fn AgentConfig::to_chat_options_to_json(self : AgentConfig) -> Json {
  let fields : Map[String, Json] = Map::from_array([])
  match self.temperature {
    Some(t) => fields["temperature"] = Json::number(t)
    None => ()
  }
  match self.max_output_tokens {
    Some(n) => fields["max_output_tokens"] = Json::number(n.to_double())
    None => ()
  }
  match self.tool_choice {
    Some(s) => fields["tool_choice"] = Json::string(s)
    None => ()
  }
  match self.reasoning_effort {
    Some(s) => fields["reasoning_effort"] = Json::string(s)
    None => ()
  }
  match self.model {
    Some(s) => fields["model"] = Json::string(s)
    None => ()
  }
  Json::object(fields)
}

///|
/// Internal routing table: tool name → owning provider. Built during Agent::new.
struct ToolRouting {
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
/// Agent — composed from extensions. Routes tools by name, hooks array-based,
/// observers fan-out, sessions write-all/read-first. `config` is mutable for
/// runtime setting changes; `model_port` is immutable.
pub(all) struct Agent {
  model_port : &@port.ModelPort
  tool_routing : ToolRouting
  pre_model_hooks : Array[&@port.PreModelHook]
  pre_tool_hooks : Array[&@port.PreToolHook]
  post_event_hooks : Array[&@port.PostEventHook]
  observers : Array[&@port.Observer]
  memories : Array[&@port.MemoryPort]
  sessions : Array[&@port.SessionStore]
  lifecycle : &@port.Lifecycle?
  commands : Array[&@port.CommandPort]
  builtin_command_port : BuiltinCommandPort
  mailbox : @puppetry.ControlMailbox
  mut config : AgentConfig
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
  let tool_routing = build_tool_routing(agg.tools)
  let lifecycle : &@port.Lifecycle? = match agg.lifecycle.length() {
    0 => None
    _ => Some(agg.lifecycle[0])
  }
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
  {
    model_port: agg.model,
    tool_routing,
    pre_model_hooks: composed_pre_model,
    pre_tool_hooks: agg.pre_tool_hooks,
    post_event_hooks: composed_post_event,
    observers: agg.observers,
    memories: agg.memory,
    sessions: agg.sessions,
    lifecycle,
    commands: agg.commands,
    builtin_command_port,
    mailbox,
    config,
  }
}

///|
pub async fn Agent::shutdown(self : Agent) -> Unit {
  match self.lifecycle {
    // Lifecycle has no typed error channel today. Do not catch runtime
    // failures here: cleanup failure must remain loud to the caller.
    Some(lc) => lc.on_shutdown()
    None => ()
  }
}

///|
/// Switch the active model by name at runtime. Updates `config.model`,
/// emits `ConfigChanged`, and re-validates `reasoning_effort`.
pub fn Agent::update_model(self : Agent, name : String) -> Unit {
  let old = self.config.model
  self.config.model = Some(name)
  // Emit ConfigChanged so subscribers (persistence, UI) update.
  let change : @types.TurnEvent = @types.ConfigChanged(
    field="model",
    old_value=match old {
      Some(s) => s
      None => ""
    },
    new_value=name,
  )
  self.emit_turn_event(change)
  // Re-validate reasoning_effort: the router may now route to a provider
  // whose accepted values differ. Use the ModelPort's current
  // `ProviderConfig` as a hint; in production, a router ModelPort would
  // re-evaluate this per chat() call anyway, but warning early is better UX.
  self.validate_reasoning_effort_after_change()
}

///|
/// Update `reasoning_effort` at runtime. Validates against the ModelPort's
/// `ProviderConfig`; emits `ConfigWarning` on invalid value.
pub fn Agent::update_reasoning_effort(self : Agent, value : String) -> Unit {
  let provider_config = self.model_port.provider_config()
  if provider_config.reasoning_effort_values.contains(value) {
    let old = self.config.reasoning_effort
    self.config.reasoning_effort = Some(value)
    let change : @types.TurnEvent = @types.ConfigChanged(
      field="reasoning_effort",
      old_value=match old {
        Some(s) => s
        None => ""
      },
      new_value=value,
    )
    self.emit_turn_event(change)
  } else {
    // Reject and warn. The field stays at its prior value.
    let accepted = provider_config.reasoning_effort_values.copy().join(", ")
    let warning : @types.TurnEvent = @types.ConfigWarning(
      field="reasoning_effort",
      value~,
      reason="active modelport does not accept this value (accepted: [\{accepted}])",
    )
    self.emit_turn_event(warning)
  }
}

///|
/// Check `reasoning_effort` is still valid after a config change; reset if not.
fn Agent::validate_reasoning_effort_after_change(self : Agent) -> Unit {
  match self.config.reasoning_effort {
    Some(value) => {
      let provider_config = self.model_port.provider_config()
      if !provider_config.reasoning_effort_values.contains(value) {
        let accepted = provider_config.reasoning_effort_values.copy().join(", ")
        let warning : @types.TurnEvent = @types.ConfigWarning(
          field="reasoning_effort",
          value~,
          reason="current modelport does not support this value (accepted: [\{accepted}]); reset to None",
        )
        self.emit_turn_event(warning)
        // Reset and broadcast the auto-correction.
        self.config.reasoning_effort = None
        let reset : @types.TurnEvent = @types.ConfigChanged(
          field="reasoning_effort",
          old_value=value,
          new_value="",
        )
        self.emit_turn_event(reset)
      }
    }
    None => ()
  }
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
fn Agent::emit_turn_event(self : Agent, event : @types.TurnEvent) -> Unit {
  for observer in self.observers {
    observer.on_event(agent_snapshot_turn_event(event))
  }
}

///|
/// Run one agent turn. Delegates to Puppet; emits start/end events for observers.
pub async fn Agent::run_turn(
  self : Agent,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
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
