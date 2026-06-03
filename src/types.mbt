///|
/// types.mbt — Posoco Agent Framework: domain model types.
///
/// Cross-cutting types that flow through the system. These represent the
/// business concepts shared by multiple port interfaces.

///|
/// ——— Message Types ———
pub(all) enum Role {
  System
  User
  Assistant
  Tool
} derive(Eq, Debug)

///|
pub(all) enum Content {
  Text(String)
  Image(String, String) // (media_type, data)
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
/// ——— Tool Types ———
pub(all) struct ToolDef {
  name : String
  description : String
  input_schema : Json
} derive(Eq, Debug)

///|
pub(all) struct ToolResult {
  content : String
  structured : Json?
  is_error : Bool
} derive(Eq, Debug)

///|
/// ——— Model Types ———
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
/// ——— ChatOptions ———
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
/// ——— Session ———
pub(all) struct Session {
  messages : Array[Message]
  metadata : Map[String, Json]
} derive(Eq, Debug)

///|
/// ——— TurnEvent (7 variants) ———
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
    Custom(source~, label~, ..) => "Custom(source:\{source}, label:\{label})"
  }
}

///|
/// ——— TurnResult ———
pub(all) struct TurnResult {
  message : Message
  tool_results : Array[ToolResult]
  final_session_id : String
} derive(Eq, Debug)

///|
/// ——— Memory Types ———
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
