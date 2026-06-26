///|
pub(all) struct AgentConfig {
  max_tool_rounds : Int
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : ToolChoice?
  reasoning_effort : ReasoningEffort?
  model_context_window : Int?
}

///|
pub fn AgentConfig::to_chat_options(self : AgentConfig) -> ChatOptions {
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
  tool_map : Map[String, &ToolProvider]
  providers : Array[&ToolProvider]
  collisions : Array[String]
}

///|
fn build_tool_routing(tools : Array[&ToolProvider]) -> ToolRouting {
  let tool_map : Map[String, &ToolProvider] = Map::from_array([])
  let collisions : Array[String] = []
  for provider in tools {
    let tool_defs = provider.list_tools()
    for tool in tool_defs {
      if tool_map.contains(tool.name) {
        collisions.push(
          "Tool '\{tool.name}' registered by multiple providers; last one wins",
        )
      }
      tool_map[tool.name] = provider
    }
  }
  { tool_map, providers: tools, collisions }
}

///|
/// Agent — array-based composition: tools routed by name, hooks chained,
/// observers fan-out, compressors first-wins, sessions write-all/read-first.
pub(all) struct Agent {
  model_port : &ModelPort
  tool_routing : ToolRouting
  pipeline_hook : &PipelineHook?
  compressors : Array[&Compressor]
  observers : Array[&Observer]
  memories : Array[&MemoryPort]
  sessions : Array[&SessionStore]
  lifecycle : &Lifecycle?
  config : AgentConfig
}

///|
/// Construct an Agent with array-based composition.
///
/// - `tools`: routed by tool name (last-wins on collision)
/// - `hooks`: chained in order (first runs first)
/// - `memory`: fan-out store/search
/// - `compressors`: first non-None wins
/// - `observers`: all receive every event
/// - `sessions`: write-all, read-first
pub fn Agent::new(
  model_port : &ModelPort,
  tools~ : Array[&ToolProvider],
  hooks~ : Array[&PipelineHook],
  memory~ : Array[&MemoryPort],
  compressors~ : Array[&Compressor],
  observers~ : Array[&Observer],
  sessions~ : Array[&SessionStore],
  lifecycle~ : &Lifecycle?,
  config~ : AgentConfig,
) -> Agent {
  let tool_routing = build_tool_routing(tools)
  let pipeline_hook : &PipelineHook? = match hooks.length() {
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
pub fn Agent::tool_collisions(self : Agent) -> Array[String] {
  self.tool_routing.collisions.copy()
}

///|
pub async fn Agent::shutdown(self : Agent) -> Unit {
  match self.lifecycle {
    Some(lc) => lc.on_shutdown() catch { _ => () }
    None => ()
  }
}

///|
async fn call_hook(
  hook : &PipelineHook,
  stage : Stage,
) -> Result[Stage, HookError] raise AgentError {
  hook.on_stage(stage) catch {
    e => raise HookAborted(e.to_string())
  }
}

///|
async fn ignore_hook(hook : &PipelineHook, stage : Stage) -> Unit {
  ignore(hook.on_stage(stage)) catch {
    _ => ()
  }
}

///|
/// Run one full agent turn. Tool calls execute in parallel via @async.all.
pub async fn Agent::run_turn(
  self : Agent,
  input : Message,
  session_id : String,
) -> TurnResult raise AgentError {
  let result = self.run_turn_inner(input, session_id) catch {
    e => {
      // Finally: ensure TurnError fires on any error path before propagating.
      match self.pipeline_hook {
        Some(hook) => ignore_hook(hook, TurnError(e)) catch { _ => () }
        None => ()
      }
      raise e
    }
  }
  result
}

///|
async fn Agent::run_turn_inner(
  self : Agent,
  input : Message,
  session_id : String,
) -> TurnResult raise AgentError {
  match self.pipeline_hook {
    Some(hook) =>
      match call_hook(hook, BeforeTurn) {
        Ok(_) => ()
        Err(e) => raise HookAborted(e.to_string())
      }
    None => ()
  }

  for obs in self.observers {
    obs.on_event(TurnStarted)
  }

  let session = match self.sessions {
    [first, ..] =>
      match first.load(session_id) {
        Ok(s) => s
        Err(e) => raise Session(e)
      }
    [] => raise Session(Load("no session store configured"))
  }

  let mut current_session_id = session_id
  let mut messages = session.messages
  messages.push(input)

  let tools : Array[ToolDef] = []
  for provider in self.tool_routing.providers {
    let provider_tools = provider.list_tools()
    for t in provider_tools {
      tools.push(t)
    }
  }
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
    reasoning_content: None,
  }

  while true {
    let ctx = {
      session_id: current_session_id,
      model_context_window: self.config.model_context_window,
    }
    let mut compress_done = false
    for comp in self.compressors {
      if compress_done {
        break
      }
      let action = comp.compress(messages, ctx)
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
          for store in self.sessions {
            match store.save(new_sid, new_session) {
              Ok(_) => ()
              Err(e) => raise Session(e)
            }
          }
          for obs in self.observers {
            obs.on_event(
              SessionRedirect(
                from=current_session_id,
                to=new_sid,
                messages_before=before,
                messages_after=after,
              ),
            )
          }
          current_session_id = new_sid
          messages = msgs
          compress_done = true
        }
        Replace(msgs) => {
          messages = msgs
          compress_done = true
        }
        None => ()
      }
    }

    match self.pipeline_hook {
      Some(hook) =>
        match call_hook(hook, BeforeModel(messages)) {
          Ok(BeforeModel(msgs)) => messages = msgs
          Ok(_) => ()
          Err(e) => raise HookAborted(e.to_string())
        }
      None => ()
    }

    response = self.model_port.chat_streaming(
      messages,
      tools,
      self.config.to_chat_options(),
      fn(chunk : StreamChunk) {
        for obs in self.observers {
          obs.on_event(StreamChunkReceived(chunk~))
        }
      },
    ) catch {
      e => {
        let reason = e.to_string()
        for obs in self.observers {
          obs.on_event(TurnFailed(reason))
        }
        match self.pipeline_hook {
          Some(hook) => ignore_hook(hook, ModelError(reason)) catch { _ => () }
          None => ()
        }
        raise Model(reason)
      }
    }

    for obs in self.observers {
      obs.on_event(
        ModelResponseReceived(
          message=response.message,
          usage=response.usage,
          reasoning_content=response.reasoning_content,
        ),
      )
    }

    match self.pipeline_hook {
      Some(hook) =>
        match call_hook(hook, AfterModel(response)) {
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
      for obs in self.observers {
        obs.on_event(TurnFailed("tool loop exceeded"))
      }
      raise ToolLoopExceeded
    }

    let approved_calls : Array[ToolCall] = []
    for tool_call in response.tool_calls {
      for obs in self.observers {
        obs.on_event(ToolCallPending(tool_call))
      }

      let mut effective_call = tool_call
      let mut skip_tool = false
      match self.pipeline_hook {
        Some(hook) =>
          match call_hook(hook, BeforeTool(effective_call)) {
            Ok(BeforeTool(tc)) => effective_call = tc
            Ok(_) => ()
            Err(Deferred(reason~)) => {
              for obs in self.observers {
                obs.on_event(ToolCallDeferred(call=effective_call, reason~))
              }
              let rejection = ToolResult::{
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
            Err(Aborted(msg)) => raise HookAborted(msg)
          }
        None => ()
      }
      if skip_tool == false {
        approved_calls.push(effective_call)
      }
    }

    let mut exec_results : Array[Result[ToolResult, RuntimeError]] = []
    if !approved_calls.is_empty() {
      exec_results = @async.all(
        approved_calls.map(fn(call) {
          async fn() -> Result[ToolResult, RuntimeError] {
            match self.tool_routing.tool_map.get(call.name) {
              Some(provider) =>
                Ok(provider.execute(call.name, call)) catch {
                  e => Err(e)
                }
              None =>
                Err(
                  RuntimeError::UnknownTool(
                    "No provider for tool '\{call.name}'",
                  ),
                )
            }
          }
        }),
      ) catch {
        e => raise Model(e.to_string())
      }
    }

    for i = 0; i < approved_calls.length(); i = i + 1 {
      let call = approved_calls[i]
      match exec_results[i] {
        Ok(result) => {
          for obs in self.observers {
            obs.on_event(ToolCallResult(call~, result~, is_error=false))
          }
          match self.pipeline_hook {
            Some(hook) =>
              ignore_hook(hook, AfterTool(call, result)) catch {
                _ => ()
              }
            None => ()
          }
          all_results.push(result)
          messages.push(build_tool_result_message(call, result))
        }
        Err(e) => {
          let error_result = {
            content: e.to_string(),
            structured: None,
            is_error: true,
          }
          for obs in self.observers {
            obs.on_event(
              ToolCallResult(call~, result=error_result, is_error=true),
            )
          }
          match self.pipeline_hook {
            Some(hook) =>
              ignore_hook(hook, ToolError(call, e)) catch {
                _ => ()
              }
            None => ()
          }
          all_results.push(error_result)
          messages.push(build_error_message(call, e))
        }
      }
    }

    if resolution_required {
      break
    }
  }

  let final_session = { messages, metadata: Map::from_array([]) }
  for store in self.sessions {
    match store.save(current_session_id, final_session) {
      Ok(_) => ()
      Err(e) => raise Session(e)
    }
  }

  for obs in self.observers {
    obs.on_event(TurnCompleted)
  }

  let result = {
    message: response.message,
    tool_results: all_results,
    final_session_id: current_session_id,
  }

  match self.pipeline_hook {
    Some(hook) => ignore_hook(hook, AfterTurn(result)) catch { _ => () }
    None => ()
  }

  result
}
