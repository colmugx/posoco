///|
/// agent.mbt — Agent struct, constructor, and run_turn loop.
///
/// Implements the core agent lifecycle: session load, context compression,
/// LLM chat, tool execution, and pipeline hooks.

///|
/// Agent configuration — controls model parameters and loop limits.
pub(all) struct AgentConfig {
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : ToolChoice?
  thinking : Bool?
  model_context_window : Int?
}

///|
pub fn AgentConfig::to_chat_options(self : AgentConfig) -> ChatOptions {
  {
    temperature: self.temperature,
    max_output_tokens: self.max_output_tokens,
    tool_choice: self.tool_choice,
    thinking: self.thinking,
  }
}

///|
/// Agent — the central runtime actor.
///
/// Holds references to all port interfaces plus an optional pipeline hook.
pub(all) struct Agent {
  model_port : &ModelPort
  tool_provider : &ToolProvider
  tool_runtime : &ToolRuntime
  session_store : &SessionStore
  observer : &Observer
  compressor : &Compressor
  pipeline_hook : &PipelineHook?
  config : AgentConfig
}

///|
pub fn Agent::new(
  model_port : &ModelPort,
  tool_provider : &ToolProvider,
  tool_runtime : &ToolRuntime,
  session_store : &SessionStore,
  observer : &Observer,
  compressor : &Compressor,
  pipeline_hook : &PipelineHook?,
  config : AgentConfig,
) -> Agent {
  {
    model_port,
    tool_provider,
    tool_runtime,
    session_store,
    observer,
    compressor,
    pipeline_hook,
    config,
  }
}

///|
/// Run one full agent turn: load session, compress context, call the model,
/// execute tools in a loop, and persist the final session.
pub fn Agent::run_turn(
  self : Agent,
  input : Message,
  session_id : String,
) -> Result[TurnResult, AgentError] {
  // ── Stage: BeforeTurn ──
  match self.pipeline_hook {
    Some(hook) =>
      match hook.on_stage(Stage::BeforeTurn) {
        Ok(_) => ()
        Err(e) => return Err(AgentError::HookAborted(e.to_string()))
      }
    None => ()
  }

  self.observer.on_event(TurnEvent::TurnStarted)

  let session = match self.session_store.load(session_id) {
    Ok(s) => s
    Err(e) => return Err(AgentError::Session(e))
  }

  let mut current_session_id = session_id
  let mut messages = session.messages
  messages.push(input)

  let tools = self.tool_provider.list_tools()
  let mut tool_round = 0
  let all_results : Array[ToolResult] = []
  let initial_msg = {
    role: Role::Assistant,
    content: [],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
  let mut response = {
    message: initial_msg,
    tool_calls: [],
    finish_reason: FinishReason::Stop,
    usage: None,
    reasoning_summary: None,
  }

  while true {
    // ── Context compression ──
    let ctx = {
      session_id: current_session_id,
      model_context_window: self.config.model_context_window,
    }
    let action = self.compressor.compress(messages, ctx)
    match action {
      CompressAction::NewThread(
        messages=msgs,
        new_session_id=new_sid,
        messages_before=before,
        messages_after=after
      ) => {
        let new_session = {
          messages: msgs,
          metadata: Map::from_array([
            ("parent_session_id", Json::string(current_session_id)),
          ]),
        }
        match self.session_store.save(new_sid, new_session) {
          Ok(_) => ()
          Err(e) => return Err(AgentError::Session(e))
        }
        self.observer.on_event(
          TurnEvent::SessionRedirect(
            from=current_session_id,
            to=new_sid,
            messages_before=before,
            messages_after=after,
          ),
        )
        current_session_id = new_sid
        messages = msgs
      }
      CompressAction::Replace(msgs) => messages = msgs
      CompressAction::None => ()
    }

    // ── Stage: BeforeModel ──
    match self.pipeline_hook {
      Some(hook) =>
        match hook.on_stage(Stage::BeforeModel(messages)) {
          Ok(_) => ()
          Err(e) => return Err(AgentError::HookAborted(e.to_string()))
        }
      None => ()
    }

    // ── LLM round ──
    response = match
      self.model_port.chat(messages, tools, self.config.to_chat_options()) {
      Ok(r) => r
      Err(e) => {
        let reason = e.to_string()
        self.observer.on_event(TurnEvent::TurnFailed(reason))
        match self.pipeline_hook {
          Some(hook) => ignore(hook.on_stage(Stage::ModelError(e)))
          None => ()
        }
        return Err(AgentError::Model(e))
      }
    }

    self.observer.on_event(
      TurnEvent::ModelResponseReceived(
        message=response.message,
        usage=response.usage,
        reasoning_summary=response.reasoning_summary,
      ),
    )

    // ── Stage: AfterModel ──
    match self.pipeline_hook {
      Some(hook) =>
        match hook.on_stage(Stage::AfterModel(response)) {
          Ok(_) => ()
          Err(e) => return Err(AgentError::HookAborted(e.to_string()))
        }
      None => ()
    }

    messages.push(response.message)

    if response.tool_calls.is_empty() {
      break
    }

    tool_round = tool_round + 1
    if tool_round > self.config.max_tool_rounds {
      self.observer.on_event(TurnEvent::TurnFailed("tool loop exceeded"))
      return Err(AgentError::ToolLoopExceeded)
    }

    // ── Tool execution ──
    for tool_call in response.tool_calls {
      self.observer.on_event(TurnEvent::ToolCallPending(tool_call))

      // Stage: BeforeTool — PipelineHook can rewrite
      let mut effective_call = tool_call
      match self.pipeline_hook {
        Some(hook) =>
          match hook.on_stage(Stage::BeforeTool(effective_call)) {
            Ok(Stage::BeforeTool(tc)) => effective_call = tc
            Ok(_) => ()
            Err(e) => return Err(AgentError::HookAborted(e.to_string()))
          }
        None => ()
      }

      match self.tool_runtime.execute(effective_call.name, effective_call) {
        Ok(result) => {
          self.observer.on_event(
            TurnEvent::ToolCallResult(
              call=effective_call,
              result~,
              is_error=false,
            ),
          )
          match self.pipeline_hook {
            Some(hook) =>
              ignore(hook.on_stage(Stage::AfterTool(effective_call, result)))
            None => ()
          }
          all_results.push(result)
          messages.push(build_tool_result_message(effective_call, result))
        }
        Err(e) => {
          let error_result = {
            content: e.to_string(),
            structured: None,
            is_error: true,
          }
          self.observer.on_event(
            TurnEvent::ToolCallResult(
              call=effective_call,
              result=error_result,
              is_error=true,
            ),
          )
          match self.pipeline_hook {
            Some(hook) =>
              ignore(hook.on_stage(Stage::ToolError(effective_call, e)))
            None => ()
          }
          all_results.push(error_result)
          messages.push(build_error_message(effective_call, e))
        }
      }
    }
  }

  // ── End of turn — save session ──
  let final_session = { messages, metadata: Map::from_array([]) }
  match self.session_store.save(current_session_id, final_session) {
    Ok(_) => ()
    Err(e) => return Err(AgentError::Session(e))
  }

  self.observer.on_event(TurnEvent::TurnCompleted)

  let result = {
    message: response.message,
    tool_results: all_results,
    final_session_id: current_session_id,
  }

  // Stage: AfterTurn
  match self.pipeline_hook {
    Some(hook) => ignore(hook.on_stage(Stage::AfterTurn(result)))
    None => ()
  }

  Ok(result)
}
