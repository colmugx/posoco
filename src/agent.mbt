///|
pub(all) struct AgentConfig {
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : @types.ToolChoice?
  reasoning_effort : @types.ReasoningEffort?
  model_context_window : Int?
}

///|
pub fn AgentConfig::to_chat_options(self : AgentConfig) -> @types.ChatOptions {
  {
    temperature: self.temperature,
    max_output_tokens: self.max_output_tokens,
    tool_choice: self.tool_choice,
    reasoning_effort: self.reasoning_effort,
  }
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
fn agent_snapshot_tool_call(call : @types.ToolCall) -> @types.ToolCall {
  {
    id: call.id,
    name: call.name,
    arguments: agent_snapshot_json(call.arguments),
  }
}

///|
fn agent_snapshot_message(message : @types.Message) -> @types.Message {
  {
    role: message.role,
    content: message.content.copy(),
    tool_calls: message.tool_calls.map(agent_snapshot_tool_call),
    tool_call_id: message.tool_call_id,
    name: message.name,
    reasoning_content: message.reasoning_content,
  }
}

///|
fn agent_snapshot_messages(
  messages : Array[@types.Message],
) -> Array[@types.Message] {
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
  messages : Array[@types.Message],
  metadata : Map[String, Json],
) -> @types.Session {
  {
    messages: agent_snapshot_messages(messages),
    metadata: agent_snapshot_metadata(metadata),
  }
}

///|
fn agent_snapshot_tool_result(result : @types.ToolResult) -> @types.ToolResult {
  {
    content: result.content,
    structured: match result.structured {
      Some(value) => Some(agent_snapshot_json(value))
      None => None
    },
    is_error: result.is_error,
  }
}

///|
fn agent_snapshot_tool_def(tool : @types.ToolDef) -> @types.ToolDef {
  {
    name: tool.name,
    description: tool.description,
    input_schema: agent_snapshot_json(tool.input_schema),
    metadata: match tool.metadata {
      Some(value) => Some(agent_snapshot_json(value))
      None => None
    },
    source: tool.source,
  }
}

///|
fn agent_snapshot_model_response(
  response : @types.ModelResponse,
) -> @types.ModelResponse {
  {
    message: agent_snapshot_message(response.message),
    tool_calls: response.tool_calls.map(agent_snapshot_tool_call),
    finish_reason: response.finish_reason,
    usage: response.usage,
    reasoning_content: response.reasoning_content,
  }
}

///|
fn agent_snapshot_turn_result(result : @types.TurnResult) -> @types.TurnResult {
  {
    message: agent_snapshot_message(result.message),
    tool_results: result.tool_results.map(agent_snapshot_tool_result),
    final_session_id: result.final_session_id,
  }
}

///|
fn tool_provenance(tool : @types.ToolDef) -> String {
  match tool.source {
    Some(source) if source != "" =>
      "ToolDef.source='\{safe_error_label(source)}'"
    _ =>
      "unlabeled provider declaring '\{safe_error_label(tool.name)}' (set ToolDef.source to a stable provider id)"
  }
}

///|
/// Build the tool routing table. Raises CompositionError::ToolCollision on
/// the FIRST name collision (fail-fast), rather than last-wins. The
/// collision message identifies the tool name and a provenance hint for each
/// conflicting provider (ToolDef.source if present, else an actionable marker).
fn build_tool_routing(
  tools : Array[&@port.ToolProvider],
) -> ToolRouting raise @error.CompositionError {
  let tool_map : Map[String, &@port.ToolProvider] = Map::from_array([])
  let owner_source : Map[String, String] = Map::from_array([])
  for provider in tools {
    let tool_defs = provider.list_tools()
    for tool in tool_defs {
      let provenance = tool_provenance(tool)
      if tool_map.contains(tool.name) {
        // T06-B: fail-fast on collision. The error names the tool and both
        // sources so the caller can locate the conflict without guessing.
        let prev_source = match owner_source.get(tool.name) {
          Some(s) => s
          None => "(unknown)"
        }
        raise @error.CompositionError::ToolCollision(
          safe_error_label(tool.name),
          "tool collision; first declaration: \{prev_source}; conflicting declaration: \{provenance}",
        )
      }
      tool_map[tool.name] = provider
      owner_source[tool.name] = provenance
    }
  }
  { tool_map, providers: tools }
}

///|
/// Agent — array-based composition: tools routed by name, hooks chained,
/// observers fan-out, compressors first-wins, sessions write-all/read-first.
pub(all) struct Agent {
  model_port : &@port.ModelPort
  tool_routing : ToolRouting
  pipeline_hook : &@port.PipelineHook?
  compressors : Array[&@port.Compressor]
  observers : Array[&@port.Observer]
  memories : Array[&@port.MemoryPort]
  sessions : Array[&@port.SessionStore]
  lifecycle : &@port.Lifecycle?
  config : AgentConfig
}

///|
/// Construct an Agent with array-based composition.
///
/// - `tools`: routed by tool name; a name collision RAISES
///   `CompositionError::ToolCollision` (fail-fast, not last-wins)
/// - `hooks`: chained in order (first runs first)
/// - `memory`: fan-out store/search
/// - `compressors`: first non-None wins
/// - `observers`: all receive every event
/// - `sessions`: write-all, read-first
pub fn Agent::new(
  model_port : &@port.ModelPort,
  tools~ : Array[&@port.ToolProvider],
  hooks~ : Array[&@port.PipelineHook],
  memory~ : Array[&@port.MemoryPort],
  compressors~ : Array[&@port.Compressor],
  observers~ : Array[&@port.Observer],
  sessions~ : Array[&@port.SessionStore],
  lifecycle~ : &@port.Lifecycle?,
  config~ : AgentConfig,
) -> Agent raise @error.CompositionError {
  let tool_routing = build_tool_routing(tools)
  let pipeline_hook : &@port.PipelineHook? = match hooks.length() {
    0 => None
    1 => Some(hooks[0])
    _ => Some(HookChain::{ hooks, })
  }
  {
    model_port,
    tool_routing,
    pipeline_hook,
    compressors,
    observers,
    memories: memory,
    sessions,
    lifecycle,
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
async fn call_hook(
  hook : &@port.PipelineHook,
  stage : @port.Stage,
) -> Result[@port.Stage, @port.HookError] raise @error.AgentError {
  hook.on_stage(stage) catch {
    e => raise @error.AgentError::HookAborted(safe_error_label(e.to_string()))
  }
}

///|
fn hook_error_category(error : @port.HookError) -> String {
  match error {
    Aborted(_) => "HookError::Aborted"
    Deferred(..) => "HookError::Deferred"
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
fn secondary_failure_event(
  stage : String,
  operation : String,
  error_category : String,
) -> @types.TurnEvent {
  Custom(
    source="posoco.core",
    label="secondary_failure",
    data=Json::object(
      Map::from_array([
        ("stage", Json::string(stage)),
        ("operation", Json::string(operation)),
        ("error_category", Json::string(error_category)),
      ]),
    ),
  )
}

///|
fn Agent::record_secondary_failure(
  self : Agent,
  stage : String,
  operation : String,
  error_category : String,
) -> Unit {
  let event = secondary_failure_event(stage, operation, error_category)
  self.emit_turn_event(event)
}

///|
async fn Agent::record_secondary_hook(
  self : Agent,
  hook : &@port.PipelineHook,
  stage : @port.Stage,
  stage_name : String,
) -> Unit {
  let error_category : String? = try {
    match hook.on_stage(stage) {
      Ok(_) => None
      Err(error) => Some(hook_error_category(error))
    }
  } catch {
    _ => Some("UnhandledHookError")
  }
  match error_category {
    Some(category) =>
      self.record_secondary_failure(
        stage_name, "PipelineHook.on_stage", category,
      )
    None => ()
  }
}

///|
fn @types.TurnEvent::tool_call_result(
  call : @types.ToolCall,
  result : @types.ToolResult,
) -> @types.TurnEvent {
  ToolCallResult(call~, result~, is_error=result.is_error)
}

///|
fn agent_snapshot_turn_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    TurnStarted => TurnStarted
    ToolCallPending(call) => ToolCallPending(agent_snapshot_tool_call(call))
    ToolCallResult(call~, result~, ..) =>
      @types.TurnEvent::tool_call_result(
        agent_snapshot_tool_call(call),
        agent_snapshot_tool_result(result),
      )
    ModelResponseReceived(message~, usage~, reasoning_content~) =>
      ModelResponseReceived(
        message=agent_snapshot_message(message),
        usage~,
        reasoning_content~,
      )
    SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      SessionRedirect(from~, to~, messages_before~, messages_after~)
    TurnCompleted => TurnCompleted
    TurnFailed(reason) => TurnFailed(reason)
    ToolCallDeferred(call~, reason~) =>
      ToolCallDeferred(call=agent_snapshot_tool_call(call), reason~)
    StreamChunkReceived(chunk~) => StreamChunkReceived(chunk~)
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
/// Run one full agent turn. Tool calls execute in parallel via @async.all.
pub async fn Agent::run_turn(
  self : Agent,
  input : @types.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  match self.pipeline_hook {
    Some(hook) =>
      match call_hook(hook, BeforeTurn) {
        Ok(_) => ()
        Err(error) => {
          let primary = @error.AgentError::HookAborted(error.to_string())
          self.record_secondary_hook(hook, TurnError(primary), "TurnError") catch {
            _ =>
              self.record_secondary_failure(
                "TurnError", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
              )
          }
          raise primary
        }
      }
    None => ()
  }

  self.emit_turn_event(TurnStarted)

  let result = self.run_turn_inner(input, session_id) catch {
    primary => {
      match self.pipeline_hook {
        Some(hook) =>
          self.record_secondary_hook(hook, TurnError(primary), "TurnError") catch {
            _ =>
              self.record_secondary_failure(
                "TurnError", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
              )
          }
        None => ()
      }
      let safe_reason = "turn failed: " + agent_error_category(primary)
      self.emit_turn_event(TurnFailed(safe_reason))
      raise primary
    }
  }

  match self.pipeline_hook {
    Some(hook) =>
      self.record_secondary_hook(
        hook,
        AfterTurn(agent_snapshot_turn_result(result)),
        "AfterTurn",
      ) catch {
        _ =>
          self.record_secondary_failure(
            "AfterTurn", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
          )
      }
    None => ()
  }

  self.emit_turn_event(TurnCompleted)
  result
}

///|
async fn Agent::run_turn_inner(
  self : Agent,
  input : @types.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  let session = match self.sessions {
    [first, ..] =>
      match first.load(session_id) {
        Ok(s) => s
        Err(error) =>
          raise contextualize_session_error(error, session_id, "load")
      }
    [] =>
      raise contextualize_session_error(
        @error.SessionError::Load("no session store configured"),
        session_id,
        "load",
      )
  }

  let mut current_session_id = session_id
  let mut messages = agent_snapshot_messages(session.messages)
  messages.push(agent_snapshot_message(input))

  // T05 data-fidelity: carry loaded session metadata through the turn so the
  // final save preserves unknown (user-owned) keys. Framework lineage keys
  // (e.g. parent_session_id) are added by compression and must not be
  // overwritten by the final save either.
  let mut current_metadata = agent_snapshot_metadata(session.metadata)

  let tools : Array[@types.ToolDef] = []
  for provider in self.tool_routing.providers {
    let provider_tools = provider.list_tools()
    for t in provider_tools {
      tools.push(agent_snapshot_tool_def(t))
    }
  }
  let mut tool_round = 0
  let all_results : Array[@types.ToolResult] = []
  let mut resolution_required = false
  let initial_msg : @types.Message = {
    role: Assistant,
    content: [],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let mut response : @types.ModelResponse = {
    message: initial_msg,
    tool_calls: [],
    finish_reason: Stop,
    usage: None,
    reasoning_content: None,
  }

  while true {
    let ctx : @port.CompressContext = {
      session_id: current_session_id,
      model_context_window: self.config.model_context_window,
    }
    let mut compress_done = false
    for comp in self.compressors {
      if compress_done {
        break
      }
      let action = comp.compress(agent_snapshot_messages(messages), ctx)
      match action {
        NewThread(
          messages=msgs,
          new_session_id=new_sid,
          messages_before=before,
          messages_after=after
        ) => {
          let parent_id = current_session_id
          let new_metadata = Map::from_array([
            ("parent_session_id", Json::string(parent_id)),
          ])
          for store in self.sessions {
            match
              store.save(new_sid, agent_snapshot_session(msgs, new_metadata)) {
              Ok(_) => ()
              Err(error) =>
                raise contextualize_session_error(
                  error, new_sid, "compression_new_thread_save",
                )
            }
          }
          self.emit_turn_event(
            SessionRedirect(
              from=parent_id,
              to=new_sid,
              messages_before=before,
              messages_after=after,
            ),
          )
          current_session_id = new_sid
          messages = agent_snapshot_messages(msgs)
          // T05 lineage: the new thread starts with only the lineage key;
          // user-owned metadata does not carry across a thread boundary
          // (it belongs to the parent thread's persistence). The lineage
          // key points to the parent, preserved through the final save.
          current_metadata = agent_snapshot_metadata(new_metadata)
          compress_done = true
        }
        Replace(msgs) => {
          messages = agent_snapshot_messages(msgs)
          compress_done = true
        }
        None => ()
      }
    }

    match self.pipeline_hook {
      Some(hook) =>
        match call_hook(hook, BeforeModel(agent_snapshot_messages(messages))) {
          Ok(BeforeModel(msgs)) => messages = agent_snapshot_messages(msgs)
          Ok(_) => ()
          Err(e) => raise @error.AgentError::HookAborted(e.to_string())
        }
      None => ()
    }

    response = self.model_port.chat_streaming(
      agent_snapshot_messages(messages),
      tools.map(agent_snapshot_tool_def),
      self.config.to_chat_options(),
      fn(chunk : @types.StreamChunk) {
        self.emit_turn_event(StreamChunkReceived(chunk~))
      },
    ) catch {
      e => {
        let reason = e.to_string()
        match self.pipeline_hook {
          Some(hook) =>
            self.record_secondary_hook(hook, ModelError(reason), "ModelError") catch {
              _ =>
                self.record_secondary_failure(
                  "ModelError", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
                )
            }
          None => ()
        }
        raise @error.AgentError::Model(reason)
      }
    }
    response = agent_snapshot_model_response(response)

    self.emit_turn_event(
      ModelResponseReceived(
        message=response.message,
        usage=response.usage,
        reasoning_content=response.reasoning_content,
      ),
    )

    match self.pipeline_hook {
      Some(hook) =>
        self.record_secondary_hook(
          hook,
          AfterModel(agent_snapshot_model_response(response)),
          "AfterModel",
        ) catch {
          _ =>
            self.record_secondary_failure(
              "AfterModel", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
            )
        }
      None => ()
    }

    messages.push(response.message)

    if response.tool_calls.is_empty() {
      break
    }

    tool_round = tool_round + 1
    if tool_round > self.config.max_tool_rounds {
      raise @error.AgentError::ToolLoopExceeded
    }

    let approved_calls : Array[@types.ToolCall] = []
    for tool_call in response.tool_calls {
      self.emit_turn_event(ToolCallPending(tool_call))

      let mut effective_call = tool_call
      let mut skip_tool = false
      match self.pipeline_hook {
        Some(hook) =>
          match
            call_hook(
              hook,
              BeforeTool(agent_snapshot_tool_call(effective_call)),
            ) {
            Ok(BeforeTool(tc)) => effective_call = agent_snapshot_tool_call(tc)
            Ok(_) => ()
            Err(Deferred(reason~)) => {
              self.emit_turn_event(
                ToolCallDeferred(call=effective_call, reason~),
              )
              let rejection = @types.ToolResult::{
                content: "Tool rejected (needs approval): " + reason,
                structured: None,
                is_error: true,
              }
              all_results.push(rejection)
              messages.push(
                build_tool_result_message(effective_call, rejection),
              )
              skip_tool = true
              resolution_required = true
            }
            Err(Aborted(msg)) => raise @error.AgentError::HookAborted(msg)
          }
        None => ()
      }
      if skip_tool == false {
        approved_calls.push(effective_call)
      }
    }

    let mut exec_results : Array[Result[@types.ToolResult, @error.RuntimeError]] = []
    if !approved_calls.is_empty() {
      exec_results = @async.all(
        approved_calls.map(fn(call) {
          async fn() -> Result[@types.ToolResult, @error.RuntimeError] {
            match self.tool_routing.tool_map.get(call.name) {
              Some(provider) =>
                Ok(
                  agent_snapshot_tool_result(
                    provider.execute(call.name, agent_snapshot_tool_call(call)),
                  ),
                ) catch {
                  e => Err(e)
                }
              None =>
                Err(
                  @error.RuntimeError::UnknownTool(
                    "No provider for tool '\{call.name}'",
                  ),
                )
            }
          }
        }),
      ) catch {
        e =>
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "parallel tool execution failed: \{safe_error_label(e.to_string())}",
            ),
          )
      }
    }

    for i = 0; i < approved_calls.length(); i = i + 1 {
      let call = approved_calls[i]
      match exec_results[i] {
        Ok(result) => {
          // T06-A: the event's is_error MUST be derived from the ToolResult,
          // not hardcoded. A provider may return Ok(is_error=true) to signal
          // a business-level failure; that status must propagate to observers
          // and match what is fed to the model.
          self.emit_turn_event(@types.TurnEvent::tool_call_result(call, result))
          match self.pipeline_hook {
            Some(hook) =>
              self.record_secondary_hook(
                hook,
                AfterTool(
                  agent_snapshot_tool_call(call),
                  agent_snapshot_tool_result(result),
                ),
                "AfterTool",
              ) catch {
                _ =>
                  self.record_secondary_failure(
                    "AfterTool", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
                  )
              }
            None => ()
          }
          all_results.push(result)
          messages.push(build_tool_result_message(call, result))
        }
        Err(e) => {
          let error_result : @types.ToolResult = {
            content: e.to_string(),
            structured: None,
            is_error: true,
          }
          self.emit_turn_event(
            @types.TurnEvent::tool_call_result(call, error_result),
          )
          match self.pipeline_hook {
            Some(hook) =>
              self.record_secondary_hook(
                hook,
                ToolError(agent_snapshot_tool_call(call), e),
                "ToolError",
              ) catch {
                _ =>
                  self.record_secondary_failure(
                    "ToolError", "PipelineHook.on_stage", "AsyncHookDiagnosticError",
                  )
              }
            None => ()
          }
          all_results.push(error_result)
          messages.push(build_tool_result_message(call, error_result))
        }
      }
    }

    if resolution_required {
      break
    }
  }

  // T05: final save uses the carried metadata, not a freshly-empty Map.
  for store in self.sessions {
    match
      store.save(
        current_session_id,
        agent_snapshot_session(messages, current_metadata),
      ) {
      Ok(_) => ()
      Err(error) =>
        raise contextualize_session_error(
          error, current_session_id, "final_save",
        )
    }
  }

  let result : @types.TurnResult = {
    message: response.message,
    tool_results: all_results,
    final_session_id: current_session_id,
  }

  result
}
