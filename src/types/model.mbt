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
  { id: "", name: "", arguments_buf: StringBuilder::new() }
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
pub(all) struct StreamAccumulator {
  mut text_buf : StringBuilder
  mut reasoning_buf : StringBuilder
  tool_calls : Array[ToolCallBuilder]
  mut finish_reason : String
  mut usage_input : Int?
  mut usage_cached : Int?
  mut usage_uncached : Int?
  mut usage_output : Int?
  mut usage_total : Int?
} derive(Debug)

///|
pub fn StreamAccumulator::StreamAccumulator() -> StreamAccumulator {
  {
    text_buf: StringBuilder::new(),
    reasoning_buf: StringBuilder::new(),
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
) -> Unit {
  match chunk {
    TextDelta(token~) => self.text_buf.write_string(token)
    ReasoningDelta(token~) => self.reasoning_buf.write_string(token)
    ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      while self.tool_calls.length() <= index {
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
    Some(@kernel.Reasoning::{ content: reasoning_text, raw: None })
  }
  let text = self.text()
  let content : Array[@kernel.Content] = if text == "" {
    []
  } else {
    [@kernel.Text(text)]
  }
  let finish : @kernel.FinishReason = match self.finish_reason {
    "stop" => @kernel.Stop
    "length" => @kernel.Length
    "tool_calls" | "toolcalls" => @kernel.ToolCalls
    other => @kernel.Other(other)
  }
  let usage : @kernel.Usage? = match self.usage_total {
    Some(_) =>
      Some({
        input_tokens: self.usage_input,
        output_tokens: self.usage_output,
        total_tokens: self.usage_total,
        cached_input_tokens: self.usage_cached,
        uncached_input_tokens: self.usage_uncached,
      })
    None => None
  }
  @kernel.Completion(
    content~,
    tool_calls~,
    reasoning=reasoning_opt,
    finish_reason=finish,
    usage~,
  )
}
