///|
/// Port Host Adapter — wraps `ModelPort` + `ToolProvider` into the canonical
/// `HostRuntime` contract for the Puppet.

///|
/// Map `@error.ModelError` (raised by ModelPort) to the kernel's
/// `ModelFailure` so it can travel through the reducer as data.
fn model_error_to_failure(error : @error.ModelError) -> @kernel.ModelFailure {
  match error {
    @error.RequestBuild(reason) => @kernel.RequestBuild(reason~)
    @error.Transport(reason) => @kernel.Transport(reason~)
    @error.ResponseParse(reason) => @kernel.Parse(reason~)
  }
}

///|
pub(all) struct PortHostAdapter {
  model : &@port.ModelPort
  tools : Map[String, &@port.ToolProvider]
  model_id : String
}

///|
pub fn PortHostAdapter::new(
  model~ : &@port.ModelPort,
  tools~ : Map[String, &@port.ToolProvider],
  model_id~ : String,
) -> PortHostAdapter {
  { model, tools, model_id }
}

///|
/// Construct a PortHostAdapter from an Agent's aggregated ports. Used by
/// M3.6's `Agent.run_turn_via_puppet`.
pub fn PortHostAdapter::from_agent(agent : Agent) -> PortHostAdapter {
  PortHostAdapter::new(
    model=agent.model_port,
    tools=agent.tool_routing.tool_map.copy(),
    model_id="legacy_agent",
  )
}

///|
pub fn PortHostAdapter::model_id(self : PortHostAdapter) -> String {
  self.model_id
}

///|
pub impl @kernel.HostRuntime for PortHostAdapter with fn call_model(
  self,
  messages : Array[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : @kernel.HostChunkCallback?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  let _ = call_options
  let options : @types.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let stream : @types.StreamMode = match on_chunk {
    Some(cb) => @types.Stream(cb)
    None => @types.NoStream
  }
  let result = self.model.chat(messages, tool_definitions, options, stream) catch {
    error => return Err(model_error_to_failure(error))
  }
  // R3 M3.7: when the modelport returns no preprocessing (empty
  // processed_messages), substitute the input messages so the reducer's
  // transcript-replace step is a no-op. Real modelports that actually
  // preprocess (DeepSeek dynamic tool-result elision) return their processed
  // tree here and we honour it.
  let final_result : @kernel.ModelCallResult = if result.processed_messages.is_empty() {
    @kernel.ModelCallResult::{
      completion: result.completion,
      processed_messages: messages,
    }
  } else {
    result
  }
  Ok(final_result)
}

///|
pub impl @kernel.HostRuntime for PortHostAdapter with fn execute_tool(
  self,
  _owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  let name = tool_name.to_string()
  let provider = match self.tools.get(name) {
    Some(p) => p
    None =>
      return @kernel.RuntimeFailure(
        error_category="MissingOwner",
        message="no tool provider for '" + name + "'",
      )
  }
  let call : @kernel.ToolCall = { call_id, name: tool_name, arguments }
  provider.execute(name, call) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="ToolProviderError",
        message=error.to_string(),
      )
  }
}

///|
pub impl @kernel.HostRuntime for PortHostAdapter with fn cancel_effects(
  self : PortHostAdapter,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
/// Forward `HostRuntime::compact` to `ModelPort::compact`.
pub impl @kernel.HostRuntime for PortHostAdapter with fn compact(
  self,
  messages : Array[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  let _ = call_options // M3.5: future work — decode into ChatOptions
  let options : @types.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let result = self.model.compact(messages, options, trigger) catch {
    error => return Err(model_error_to_failure(error))
  }
  Ok(result)
}
