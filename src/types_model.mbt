///|
pub(all) enum FinishReason {
  Stop
  Length
  ToolCalls
  Other(String)
} derive(Eq, Debug)

///|
pub(all) struct Usage {
  input_tokens : Int?
  output_tokens : Int?
  total_tokens : Int?
} derive(Eq, Debug)

///|
pub(all) struct ModelResponse {
  message : Message
  tool_calls : Array[ToolCall]
  finish_reason : FinishReason
  usage : Usage?
  reasoning_content : String?
} derive(Eq, Debug)

///|
pub(all) enum StreamChunk {
  TextDelta(token~ : String)
  ReasoningDelta(token~ : String)
  ToolCallDelta(
    index~ : Int,
    id~ : String?,
    name~ : String?,
    arguments_delta~ : String?
  )
  Usage(Usage)
  Finish(reason~ : FinishReason)
} derive(Eq, Debug)

///|
pub(all) struct ToolCallBuilder {
  mut id : String
  mut name : String
  mut arguments_json : String
} derive(Debug)

///|
pub fn ToolCallBuilder::new() -> ToolCallBuilder {
  { id: "", name: "", arguments_json: "" }
}

///|
/// Accumulates StreamChunk events into a ModelResponse.
pub(all) struct StreamAccumulator {
  mut text : String
  mut reasoning : String
  tool_calls : Array[ToolCallBuilder]
  mut finish_reason : FinishReason
  mut usage : Usage?
} derive(Debug)

///|
pub fn StreamAccumulator::new() -> StreamAccumulator {
  { text: "", reasoning: "", tool_calls: [], finish_reason: Stop, usage: None }
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
        self.tool_calls.push(ToolCallBuilder::new())
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
    Usage(usage) => self.usage = Some(usage)
    Finish(reason~) => self.finish_reason = reason
  }
}

///|
/// Assemble accumulated stream chunks into a ModelResponse.
///
/// T07 error-transparency: malformed tool-call argument JSON raises
/// `ModelError::ResponseParse` instead of silently becoming `{}`. This
/// prevents a corrupted stream from masquerading as a valid empty-args call.
pub fn StreamAccumulator::to_response(
  self : StreamAccumulator,
) -> ModelResponse raise ModelError {
  let tool_calls : Array[ToolCall] = []
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
    tool_calls.push({ id: tc.id, name: tc.name, arguments: args })
  }
  let reasoning_opt : String? = if self.reasoning == "" {
    None
  } else {
    Some(self.reasoning)
  }
  let content : Array[Content] = if self.text == "" {
    []
  } else {
    [Text(self.text)]
  }
  let message : Message = {
    role: Assistant,
    content,
    tool_calls,
    tool_call_id: None,
    name: None,
    reasoning_content: reasoning_opt,
  }
  {
    message,
    tool_calls,
    finish_reason: self.finish_reason,
    usage: self.usage,
    reasoning_content: reasoning_opt,
  }
}
