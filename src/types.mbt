///|
pub(all) enum Role {
  System
  User
  Assistant
  Tool
} derive(Eq, Debug)

///|
pub(all) enum Content {
  Text(String)
  Image(String, String)
} derive(Eq, Debug)

///|
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
} derive(Eq, Debug)

///|
pub(all) struct Message {
  role : Role
  content : Array[Content]
  tool_calls : Array[ToolCall]
  tool_call_id : String?
  name : String?
} derive(Eq, Debug)

///|
pub(all) struct ToolDef {
  name : String
  description : String
  input_schema : Json
  metadata : Json?
  source : String?
} derive(Eq, Debug)

///|
pub(all) struct ToolResult {
  content : String
  structured : Json?
  is_error : Bool
} derive(Eq, Debug)

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
  reasoning_summary : String?
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
pub fn StreamAccumulator::to_response(
  self : StreamAccumulator,
) -> ModelResponse {
  let tool_calls : Array[ToolCall] = self.tool_calls
    .filter(fn(tc) { tc.id != "" || tc.arguments_json != "" })
    .map(fn(tc) {
      let args : Json = @json.parse(tc.arguments_json) catch {
        _ => Json::object({})
      }
      { id: tc.id, name: tc.name, arguments: args }
    })
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
  }
  {
    message,
    tool_calls,
    finish_reason: self.finish_reason,
    usage: self.usage,
    reasoning_summary: reasoning_opt,
  }
}

///|
pub(all) enum ToolChoice {
  Auto
  NoTool
  Required
  NamedTool(String)
} derive(Eq, Debug)

///|
pub(all) struct ChatOptions {
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : ToolChoice?
  thinking : Bool?
} derive(Eq, Debug)

///|
pub(all) struct Session {
  messages : Array[Message]
  metadata : Map[String, Json]
} derive(Eq, Debug)

///|
pub(all) enum TurnEvent {
  TurnStarted
  ToolCallPending(ToolCall)
  ToolCallResult(call~ : ToolCall, result~ : ToolResult, is_error~ : Bool)
  ModelResponseReceived(
    message~ : Message,
    usage~ : Usage?,
    reasoning_summary~ : String?
  )
  SessionRedirect(
    from~ : String,
    to~ : String,
    messages_before~ : Int,
    messages_after~ : Int
  )
  TurnCompleted
  TurnFailed(String)
  ToolCallDeferred(call~ : ToolCall, reason~ : String)
  StreamChunkReceived(chunk~ : StreamChunk)
  Custom(source~ : String, label~ : String, data~ : Json)
} derive(Eq, Debug)

///|
pub impl Show for TurnEvent with fn to_string(self) -> String {
  match self {
    TurnStarted => "TurnStarted"
    ToolCallPending(call) => "ToolCallPending(\{call.id})"
    ToolCallResult(call~, is_error~, ..) =>
      "ToolCallResult(\{call.id}, is_error=\{is_error})"
    ModelResponseReceived(..) => "ModelResponseReceived"
    SessionRedirect(from~, to~, ..) => "SessionRedirect(from:\{from}, to:\{to})"
    TurnCompleted => "TurnCompleted"
    TurnFailed(msg) => "TurnFailed(\{msg})"
    ToolCallDeferred(call~, reason~) =>
      "ToolCallDeferred(\{call.id}, \{reason})"
    StreamChunkReceived(..) => "StreamChunkReceived"
    Custom(source~, label~, ..) => "Custom(source:\{source}, label:\{label})"
  }
}

///|
pub(all) struct TurnResult {
  message : Message
  tool_results : Array[ToolResult]
  final_session_id : String
} derive(Eq, Debug)

///|
pub(all) struct MemoryEntry {
  id : String
  content : String
  metadata : Map[String, Json]
  score : Double?
} derive(Eq, Debug)

///|
pub(all) struct MemoryQuery {
  query : String
  top_k : Int
  threshold : Double?
  filter : Map[String, Json]
} derive(Eq, Debug)
