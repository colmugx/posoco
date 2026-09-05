///|
/// Canonical streaming chunk shape emitted by modelports through the
/// `Stream(cb)` callback of `ModelPort::chat`. `HostChunkCallback` receives
/// this type directly; there is no separate JSON wire contract.
///
/// Streaming remains a host/telemetry concern, not a transcript fact
/// (ADR §2.11).
pub(all) enum StreamChunk {
  TextDelta(token~ : String)
  ReasoningDelta(token~ : String)
  ToolCallDelta(
    index~ : Int,
    id~ : String?,
    name~ : String?,
    arguments_delta~ : String?
  )
  Usage(
    input_tokens~ : Int,
    output_tokens~ : Int,
    total_tokens~ : Int,
    cached_input_tokens~ : Int?,
    uncached_input_tokens~ : Int?
  )
  Finish(reason~ : String)
} derive(Eq, Debug)

///|
/// Validate the scalar part of one provider stream chunk before it reaches a
/// live sink or the mutable accumulator. Tool-call sparsity is stateful and
/// is checked by `StreamAccumulator::push` (and by the executor's callback
/// guard); this method enforces the stateless part of that same protocol.
pub fn StreamChunk::validate(self : StreamChunk) -> Result[Unit, String] {
  match self {
    TextDelta(..) | ReasoningDelta(..) | Finish(..) => Ok(())
    ToolCallDelta(index~, ..) =>
      if index < 0 {
        Err("stream tool-call index must be non-negative")
      } else {
        Ok(())
      }
    Usage(
      input_tokens~,
      output_tokens~,
      total_tokens~,
      cached_input_tokens~,
      uncached_input_tokens~
    ) => {
      let usage : @kernel.Usage = {
        input_tokens: Some(input_tokens),
        output_tokens: Some(output_tokens),
        total_tokens: Some(total_tokens),
        cached_input_tokens,
        uncached_input_tokens,
      }
      match usage.validate() {
        Ok(_) => Ok(())
        Err(reason) => Err("stream " + reason)
      }
    }
  }
}

///|
/// Mutable per-index accumulator used by `StreamAccumulator` while assembling
/// streamed tool calls. Each streamed `ToolCallDelta` targets an `index`;
/// the builder records the first non-empty `id` / `name` / `arguments_json()`
/// it sees for that index.
pub(all) struct ToolCallBuilder {
  mut id : String
  mut name : String
  mut arguments_buf : StringBuilder
} derive(Debug)

///|
pub fn ToolCallBuilder::ToolCallBuilder() -> ToolCallBuilder {
  { id: "", name: "", arguments_buf: StringBuilder(), }
}

///|
pub fn ToolCallBuilder::arguments_json(self : ToolCallBuilder) -> String {
  self.arguments_buf.to_string()
}

///|
/// Accumulates `StreamChunk` events during a streaming chat call. Modelports
/// that want a standard "double-write" implementation (one chunk to the
/// `Stream(cb)` callback for telemetry, one chunk to the accumulator for the
/// final completion) can use this helper. Modelports with more sophisticated
/// needs (e.g. DeepSeek's dynamic tool-result removal during streaming) are
/// free to ignore this and maintain their own state.
///
/// R3 M3.7: the previous `to_response() -> ModelResponse` has been replaced
/// by `to_completion() -> @kernel.Completion`. The old `ModelResponse` type
/// is deleted — `chat` now returns `ModelCallResult` whose `completion`
/// field is the canonical `Completion`.
pub struct StreamAccumulator {
  priv text_buf : StringBuilder
  priv reasoning_buf : StringBuilder
  priv tool_calls : Array[ToolCallBuilder]
  priv mut finish_reason : String
  priv mut usage_input : Int?
  priv mut usage_cached : Int?
  priv mut usage_uncached : Int?
  priv mut usage_output : Int?
  priv mut usage_total : Int?
} derive(Debug)

///|
pub fn StreamAccumulator::StreamAccumulator() -> StreamAccumulator {
  {
    text_buf: StringBuilder(),
    reasoning_buf: StringBuilder(),
    tool_calls: [],
    finish_reason: "stop",
    usage_input: None,
    usage_cached: None,
    usage_uncached: None,
    usage_output: None,
    usage_total: None,
  }
}

///|
pub fn StreamAccumulator::text(self : StreamAccumulator) -> String {
  self.text_buf.to_string()
}

///|
pub fn StreamAccumulator::reasoning(self : StreamAccumulator) -> String {
  self.reasoning_buf.to_string()
}

///|
pub fn StreamAccumulator::push(
  self : StreamAccumulator,
  chunk : StreamChunk,
) -> Unit raise @error.ModelError {
  match chunk.validate() {
    Ok(_) => ()
    Err(reason) => raise @error.ModelError::ResponseParse(reason)
  }
  match chunk {
    TextDelta(token~) => self.text_buf.write_string(token)
    ReasoningDelta(token~) => self.reasoning_buf.write_string(token)
    ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      // Provider tool-call indexes are a continuous 0-based sequence: a new
      // call may introduce exactly the next slot, while later deltas may
      // revisit an existing slot. Reject a sparse index before any array
      // access or allocation, so a malformed chunk cannot leave placeholder
      // builders in the completion.
      if index > self.tool_calls.length() {
        raise @error.ModelError::ResponseParse(
          "stream tool-call index is sparse; expected an existing index or the next contiguous 0-based index",
        )
      }
      if index == self.tool_calls.length() {
        self.tool_calls.push(ToolCallBuilder())
      }
      let builder = self.tool_calls[index]
      match id {
        Some(v) => builder.id = v
        None => ()
      }
      match name {
        Some(v) => builder.name = v
        None => ()
      }
      match arguments_delta {
        Some(delta) => builder.arguments_buf.write_string(delta)
        None => ()
      }
    }
    Usage(
      input_tokens~,
      output_tokens~,
      total_tokens~,
      cached_input_tokens~,
      uncached_input_tokens~
    ) => {
      self.usage_input = Some(input_tokens)
      self.usage_cached = cached_input_tokens
      self.usage_uncached = uncached_input_tokens
      self.usage_output = Some(output_tokens)
      self.usage_total = Some(total_tokens)
    }
    Finish(reason~) => self.finish_reason = reason
  }
}

///|
/// Assemble accumulated stream chunks into a canonical `@kernel.Completion`.
///
/// T07 error-transparency: malformed tool-call argument JSON raises
/// `ModelError::ResponseParse` instead of silently becoming `{}`. This
/// prevents a corrupted stream from masquerading as a valid empty-args call.
pub fn StreamAccumulator::to_completion(
  self : StreamAccumulator,
) -> @kernel.Completion raise @error.ModelError {
  // Keep this check even though `push` validates Usage chunks. The fields are
  // private only to this package, and future package-local code must not be
  // able to turn an internally polluted accumulator into a completion that
  // bypasses the canonical Usage invariant. Validate all optional fields even
  // when total_tokens is absent (the old projection would omit the usage in
  // that case and silently discard a negative field).
  let accumulated_usage : @kernel.Usage = {
    input_tokens: self.usage_input,
    output_tokens: self.usage_output,
    total_tokens: self.usage_total,
    cached_input_tokens: self.usage_cached,
    uncached_input_tokens: self.usage_uncached,
  }
  match accumulated_usage.validate() {
    Err(reason) => raise ResponseParse("invalid accumulated usage: " + reason)
    Ok(_) => ()
  }
  let tool_calls : Array[@kernel.ToolCall] = []
  for index, tc in self.tool_calls {
    if tc.id == "" {
      raise ResponseParse(
        "incomplete streamed tool call at index \{index}: missing id",
      )
    }
    if tc.name == "" {
      raise ResponseParse(
        "incomplete streamed tool call at index \{index}: missing name",
      )
    }
    let tc_args = tc.arguments_json()
    if tc_args == "" {
      raise ResponseParse(
        "incomplete streamed tool call at index \{index}: missing arguments JSON",
      )
    }
    let args : Json = @json.parse(tc_args) catch {
      _ =>
        raise ResponseParse(
          "malformed tool-call arguments JSON at index \{index}; raw identifiers and payload omitted",
        )
    }
    tool_calls.push({
      call_id: @kernel.CallId::unchecked(tc.id),
      name: @kernel.ToolName::unchecked(tc.name),
      arguments: args,
    })
  }
  let reasoning_text = self.reasoning()
  let reasoning_opt : @kernel.Reasoning? = if reasoning_text == "" {
    None
  } else {
    Some({ content: reasoning_text, raw: None, })
  }
  let text = self.text()
  let content : Array[@kernel.Content] = if text == "" {
    []
  } else {
    [Text(text)]
  }
  let finish : @kernel.FinishReason = match self.finish_reason {
    "stop" => Stop
    "length" => Length
    "tool_calls" | "toolcalls" => ToolCalls
    other => Other(other)
  }
  let usage : @kernel.Usage? = match self.usage_total {
    Some(_) => Some(accumulated_usage)
    None => None
  }
  Completion(
    content~,
    tool_calls~,
    reasoning=reasoning_opt,
    finish_reason=finish,
    usage~,
  )
}
