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
/// Decode the provider-agnostic subset of the canonical call-options bag.
///
/// `ChatOptions` intentionally cannot represent provider-specific fields. Do
/// not drop those fields: reject them at this boundary so the caller can route
/// the original bag to a host that understands it.
fn decode_chat_options(
  call_options : Json,
) -> Result[@types.ChatOptions, @kernel.ModelFailure] {
  let fields = match call_options {
    Json::Null => return Ok({ temperature: None, max_output_tokens: None })
    Json::Object(fields) => fields
    _ =>
      return Err(
        @kernel.RequestBuild(reason="call_options must be null or an object"),
      )
  }
  for key in fields.keys() {
    if key != "temperature" && key != "max_output_tokens" {
      return Err(
        @kernel.RequestBuild(
          reason="unsupported call_options field '" + key + "'",
        ),
      )
    }
  }
  let temperature = match fields.get("temperature") {
    None => None
    Some(Json::Number(value, ..)) =>
      if (value - value).is_nan() {
        return Err(
          @kernel.RequestBuild(
            reason="call_options.temperature must be a finite number",
          ),
        )
      } else {
        Some(value)
      }
    Some(_) =>
      return Err(
        @kernel.RequestBuild(reason="call_options.temperature must be a number"),
      )
  }
  let max_output_tokens = match fields.get("max_output_tokens") {
    None => None
    Some(Json::Number(value, ..)) => {
      let converted = value.to_int()
      if converted.to_double() != value {
        return Err(
          @kernel.RequestBuild(
            reason="call_options.max_output_tokens must be an integer in Int range",
          ),
        )
      }
      Some(converted)
    }
    Some(_) =>
      return Err(
        @kernel.RequestBuild(
          reason="call_options.max_output_tokens must be a number",
        ),
      )
  }
  Ok({ temperature, max_output_tokens })
}

///|
priv struct PortHostAdapter {
  model : &@port.ModelPort
  tools : Map[String, &@port.ToolProvider]
}

///|
fn PortHostAdapter::new(
  model~ : &@port.ModelPort,
  tools~ : Map[String, &@port.ToolProvider],
) -> PortHostAdapter {
  { model, tools }
}

///|
impl @kernel.HostRuntime for PortHostAdapter with fn call_model(
  self,
  messages : Array[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : @kernel.HostChunkCallback?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  let options = match decode_chat_options(call_options) {
    Ok(options) => options
    Err(failure) => return Err(failure)
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
impl @kernel.HostRuntime for PortHostAdapter with fn execute_tool(
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
impl @kernel.HostRuntime for PortHostAdapter with fn cancel_effects(
  self : PortHostAdapter,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
/// Forward `HostRuntime::compact` to `ModelPort::compact`.
impl @kernel.HostRuntime for PortHostAdapter with fn compact(
  self,
  messages : Array[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  let options = match decode_chat_options(call_options) {
    Ok(options) => options
    Err(failure) => return Err(failure)
  }
  let result = self.model.compact(messages, options, trigger) catch {
    error => return Err(model_error_to_failure(error))
  }
  Ok(result)
}
