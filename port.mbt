///|
/// port.mbt — Posoco Agent Framework: core types, enums, structs, and traits.
///
/// This file defines the abstract port interfaces (hexagonal architecture)
/// that Posoco adapters implement. The module has zero external dependencies.

///|
/// ——— 4.1 Message Types ———
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
/// ——— 4.2 Tool Types ———
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
/// ——— 4.3 Model Types ———
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
/// ——— 4.4 ChatOptions ———
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
/// ——— 4.5 Session ———
pub(all) struct Session {
  messages : Array[Message]
  metadata : Map[String, Json]
} derive(Eq, Debug)

///|
/// ——— 4.6 TurnEvent (7 variants) ———
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
pub impl Show for TurnEvent with to_string(self) -> String {
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
/// ——— 4.7 Error Types ———
pub(all) suberror ModelError {
  RequestBuild(String)
  Transport(String)
  ResponseParse(String)
} derive(Debug)

///|
pub impl Show for ModelError with to_string(self) -> String {
  match self {
    RequestBuild(msg) => "ModelError::RequestBuild(\{msg})"
    Transport(msg) => "ModelError::Transport(\{msg})"
    ResponseParse(msg) => "ModelError::ResponseParse(\{msg})"
  }
}

///|
pub(all) suberror SessionError {
  Load(String)
  Save(String)
} derive(Debug)

///|
pub impl Show for SessionError with to_string(self) -> String {
  match self {
    Load(msg) => "SessionError::Load(\{msg})"
    Save(msg) => "SessionError::Save(\{msg})"
  }
}

///|
pub(all) suberror RuntimeError {
  InvocationFailed(String)
  Transport(String)
} derive(Debug)

///|
pub impl Show for RuntimeError with to_string(self) -> String {
  match self {
    InvocationFailed(msg) => "RuntimeError::InvocationFailed(\{msg})"
    Transport(msg) => "RuntimeError::Transport(\{msg})"
  }
}

///|
pub(all) suberror AgentError {
  Model(String)
  Session(SessionError)
  Runtime(RuntimeError)
  ToolLoopExceeded
  HookAborted(String)
} derive(Debug)

///|
pub impl Show for AgentError with to_string(self) -> String {
  match self {
    Model(msg) => "AgentError::Model(\{msg})"
    Session(err) => "AgentError::Session(\{err.to_string()})"
    Runtime(err) => "AgentError::Runtime(\{err.to_string()})"
    ToolLoopExceeded => "AgentError::ToolLoopExceeded"
    HookAborted(msg) => "AgentError::HookAborted(\{msg})"
  }
}

///|
pub(all) enum HookError {
  Aborted(String)
  Deferred(reason~ : String)  // needs approval, break tool loop
} derive(Eq, Debug)
///|
pub impl Show for HookError with to_string(self) -> String {
  match self {
    Aborted(msg) => "HookError::Aborted(\{msg})"
    Deferred(reason=reason) => "HookError::Deferred(\{reason})"
  }
}

///|
/// ——— 4.8 TurnResult ———
pub(all) struct TurnResult {
  message : Message
  tool_results : Array[ToolResult]
  final_session_id : String
} derive(Eq, Debug)

///|
/// ——— Compressor Types ———
pub(all) struct CompressContext {
  session_id : String
  model_context_window : Int?
} derive(Eq, Debug)

///|
pub(all) enum CompressAction {
  None
  Replace(Array[Message])
  NewThread(
    messages~ : Array[Message],
    new_session_id~ : String,
    messages_before~ : Int,
    messages_after~ : Int
  )
} derive(Eq, Debug)

///|
/// ——— Stage Enum (9 variants, for PipelineHook) ———
pub(all) enum Stage {
  BeforeTurn
  BeforeModel(Array[Message])
  AfterModel(ModelResponse)
  ModelError(String)
  BeforeTool(ToolCall)
  AfterTool(ToolCall, ToolResult)
  ToolError(ToolCall, RuntimeError)
  AfterTurn(TurnResult)
  TurnError(AgentError)
} derive(Debug)

///|
/// ——— The 7 Traits ———
pub(open) trait ModelPort {
  async chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError
}

///|
pub(open) trait ToolProvider {
  list_tools(Self) -> Array[ToolDef]
}

///|
pub(open) trait ToolRuntime {
  async execute(Self, name : String, call : ToolCall) -> ToolResult raise RuntimeError
}

///|
pub(open) trait SessionStore {
  load(Self, id : String) -> Result[Session, SessionError]
  save(Self, id : String, session : Session) -> Result[Unit, SessionError]
}

///|
pub(open) trait Observer {
  on_event(Self, event : TurnEvent) -> Unit
}

///|
pub(open) trait Compressor {
  compress(Self, messages : Array[Message], ctx : CompressContext) -> CompressAction
}

///|
pub(open) trait PipelineHook {
  on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}

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

///|
pub(all) suberror MemoryError {
  Store(String)
  Search(String)
  Delete(String)
} derive(Debug)

///|
pub(open) trait MemoryPort {
  store(Self, entry : MemoryEntry) -> String raise MemoryError
  search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  delete(Self, id : String) -> Unit raise MemoryError
}
