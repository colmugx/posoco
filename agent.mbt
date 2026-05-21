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
  memory_port : &MemoryPort?
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
  memory_port : &MemoryPort?,
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
    memory_port,
    config,
  }
}

///|
/// Run one full agent turn: load session, compress context, call the model,
/// execute tools in a loop, and persist the final session.
pub async fn Agent::run_turn(
  self : Agent,
  input : Message,
  session_id : String,
) -> TurnResult raise AgentError {
  // ── Stage: BeforeTurn ──
  match self.pipeline_hook {
    Some(hook) =>
      match hook.on_stage(BeforeTurn) {
        Ok(_) => ()
        Err(e) => raise HookAborted(e.to_string())
      }
    None => ()
  }

  self.observer.on_event(TurnStarted)

  let session = match self.session_store.load(session_id) {
    Ok(s) => s
    Err(e) => raise Session(e)
  }

  let mut current_session_id = session_id
  let mut messages = session.messages
  messages.push(input)

  let tools = self.tool_provider.list_tools()
  let mut tool_round = 0
  let all_results : Array[ToolResult] = []
  let mut resolution_required = false
  let initial_msg = {
    role: Assistant,
    content: [],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
  let mut response = {
    message: initial_msg,
    tool_calls: [],
    finish_reason: Stop,
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
      NewThread(
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
          Err(e) => raise Session(e)
        }
        self.observer.on_event(
          SessionRedirect(
            from=current_session_id,
            to=new_sid,
            messages_before=before,
            messages_after=after,
          ),
        )
        current_session_id = new_sid
        messages = msgs
      }
      Replace(msgs) => messages = msgs
      None => ()
    }

    // ── Stage: BeforeModel ──
    match self.pipeline_hook {
      Some(hook) =>
        match hook.on_stage(BeforeModel(messages)) {
          Ok(BeforeModel(msgs)) => messages = msgs
          Ok(_) => ()
          Err(e) => raise HookAborted(e.to_string())
        }
      None => ()
    }

    // ── LLM round ──
    response = self.model_port.chat(
      messages,
      tools,
      self.config.to_chat_options(),
    ) catch {
      e => {
        let reason = e.to_string()
        self.observer.on_event(TurnFailed(reason))
        match self.pipeline_hook {
          Some(hook) => ignore(hook.on_stage(ModelError(reason)))
          None => ()
        }
        raise Model(reason)
      }
    }

    self.observer.on_event(
      ModelResponseReceived(
        message=response.message,
        usage=response.usage,
        reasoning_summary=response.reasoning_summary,
      ),
    )

    // ── Stage: AfterModel ──
    match self.pipeline_hook {
      Some(hook) =>
        match hook.on_stage(AfterModel(response)) {
          Ok(_) => ()
          Err(e) => raise HookAborted(e.to_string())
        }
      None => ()
    }

    messages.push(response.message)

    if response.tool_calls.is_empty() {
      break
    }

    tool_round = tool_round + 1
    if tool_round > self.config.max_tool_rounds {
      self.observer.on_event(TurnFailed("tool loop exceeded"))
      raise ToolLoopExceeded
    }

    // ── Tool execution ──
    for tool_call in response.tool_calls {
      self.observer.on_event(ToolCallPending(tool_call))

      // Stage: BeforeTool — PipelineHook can rewrite
      let mut effective_call = tool_call
      let mut skip_tool = false
      match self.pipeline_hook {
        Some(hook) =>
          match hook.on_stage(BeforeTool(effective_call)) {
            Ok(BeforeTool(tc)) => effective_call = tc
            Ok(_) => ()
            Err(Deferred(reason=reason)) => {
              self.observer.on_event(
                ToolCallDeferred(call=effective_call, reason=reason),
              )
              let rejection = ToolResult::{
                content: "Tool rejected (needs approval): " + reason,
                structured: None,
                is_error: true,
              }
              all_results.push(rejection)
              skip_tool = true
              messages.push(build_tool_result_message(effective_call, rejection))
              resolution_required = true
            }
            Err(Aborted(msg)) => raise HookAborted(msg)
          }
        None => ()
      }
      if skip_tool == false {
        try {
          let result = self.tool_runtime.execute(effective_call.name, effective_call)
          self.observer.on_event(
            ToolCallResult(call=effective_call, result~, is_error=false),
          )
          match self.pipeline_hook {
            Some(hook) => ignore(hook.on_stage(AfterTool(effective_call, result)))
            None => ()
          }
          all_results.push(result)
          messages.push(build_tool_result_message(effective_call, result))
        } catch {
          e => {
            let error_result = {
              content: e.to_string(),
              structured: None,
              is_error: true,
            }
            self.observer.on_event(
              ToolCallResult(call=effective_call, result=error_result, is_error=true),
            )
            match self.pipeline_hook {
              Some(hook) => ignore(hook.on_stage(ToolError(effective_call, e)))
              None => ()
            }
            all_results.push(error_result)
            messages.push(build_error_message(effective_call, e))
          }
        }
      } // end if not skip_tool
    }  // end for
    if resolution_required {
      break
    }
  }  // end while

  // ── End of turn — save session ──
  let final_session = { messages, metadata: Map::from_array([]) }
  match self.session_store.save(current_session_id, final_session) {
    Ok(_) => ()
    Err(e) => raise Session(e)
  }

  self.observer.on_event(TurnCompleted)

  let result = {
    message: response.message,
    tool_results: all_results,
    final_session_id: current_session_id,
  }

  // Stage: AfterTurn
  match self.pipeline_hook {
    Some(hook) => ignore(hook.on_stage(AfterTurn(result)))
    None => ()
  }

  result
}
