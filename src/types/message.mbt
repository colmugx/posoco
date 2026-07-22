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
/// A conversation message. `reasoning_content` carries provider reasoning
/// (e.g. DeepSeek deepseek-reasoner思维链, OpenAI o-series reasoning content).
/// Providers that don't produce reasoning leave it None. Wire encoders decide
/// whether to resend it in subsequent turns (DeepSeek: must resend for turns
/// with tool_calls; optional otherwise).
pub(all) struct Message {
  role : Role
  content : Array[Content]
  tool_calls : Array[ToolCall]
  tool_call_id : String?
  name : String?
  reasoning_content : String?
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
