///|
/// Streaming chunk shape emitted by modelports inside the `Stream(cb)`
/// callback of `ModelPort::chat`. This is the modelport's own representation
/// of provider chunks; posoco does NOT define a canonical chunk type (ADR
/// §2.11 — streaming is host/telemetry concern, not transcript fact).
///
/// `StreamChunk` exists as a public type because it is useful for modelports
/// that want a shared wire vocabulary (ext-llm and ext-deepseek both emit
/// these). Modelports that prefer their own chunk type are free to use it;
/// the only contract is "what you pass to the `Stream(cb)` callback, the
/// `HostChunkCallback` consumer must be able to decode".
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
/// the builder records the first non-empty `id` / `name` / `arguments_json`
/// it sees for that index.
pub(all) struct ToolCallBuilder {
  mut id : String
  mut name : String
  mut arguments_json : String
} derive(Debug)

///|
pub fn ToolCallBuilder::ToolCallBuilder() -> ToolCallBuilder {
  { id: "", name: "", arguments_json: "" }
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
  mut text : String
  mut reasoning : String
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
    text: "",
    reasoning: "",
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
pub fn StreamAccumulator::push(
  self : StreamAccumulator,
  chunk : StreamChunk,
) -> Unit {
  match chunk {
    TextDelta(token~) => self.text = self.text + token
    ReasoningDelta(token~) => self.reasoning = self.reasoning + token
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
        Some(delta) => builder.arguments_json = builder.arguments_json + delta
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
    if tc.arguments_json == "" {
      raise ResponseParse(
        "incomplete streamed tool call at index \{index}: missing arguments JSON",
      )
    }
    let args : Json = @json.parse(tc.arguments_json) catch {
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
  let reasoning_opt : @kernel.Reasoning? = if self.reasoning == "" {
    None
  } else {
    Some(@kernel.Reasoning::{ content: self.reasoning, raw: None })
  }
  let content : Array[@kernel.Content] = if self.text == "" {
    []
  } else {
    [@kernel.Text(self.text)]
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
