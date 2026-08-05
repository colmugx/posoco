///|
/// `PortRuntime` — the default `Runtime`: delegates every effect to the
/// composed extension ports (`ModelPort` + `ToolProvider`s). This is exactly
/// the behaviour of the historical internal port adapter; cancellation is
/// `NotPropagated` because plain `ToolProvider`s receive no cancel signal.
///
/// Host builders wrap this type and override the methods they need instead
/// of implementing `Runtime` from scratch.

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
/// The default runtime, built from the composed extension ports.
pub struct PortRuntime {
  priv model : &@port.ModelPort
  priv tools : Map[String, &@port.ToolProvider]
}

///|
pub fn PortRuntime::new(
  model~ : &@port.ModelPort,
  tools~ : Map[String, &@port.ToolProvider],
) -> PortRuntime {
  { model, tools }
}

///|
pub impl Runtime for PortRuntime with fn call_model(
  self,
  messages : Array[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((Json) -> Unit)?,
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
  // When the modelport returns no preprocessing (empty processed_messages),
  // substitute the input messages so the reducer's transcript-replace step
  // is a no-op. Real modelports that actually preprocess return their
  // processed tree here and we honour it.
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
pub impl Runtime for PortRuntime with fn execute_tool(self, ctx : EffectContext) -> @kernel.ToolOutcome {
  let name = ctx.tool_name.to_string()
  let provider = match self.tools.get(name) {
    Some(p) => p
    None =>
      return @kernel.RuntimeFailure(
        error_category="MissingOwner",
        message="no tool provider for '" + name + "'",
      )
  }
  let call : @kernel.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.tool_name,
    arguments: ctx.arguments,
  }
  provider.execute(name, call) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="ToolProviderError",
        message=error.to_string(),
      )
  }
}

///|
/// Plain `ToolProvider`s receive no cancel signal, so the default runtime
/// reports `NotPropagated` for every effect. Runtimes with real cancellation
/// wrap this method.
pub impl Runtime for PortRuntime with fn cancel_effects(
  self : PortRuntime,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
/// Forward compact to `ModelPort::compact`.
pub impl Runtime for PortRuntime with fn compact(
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
