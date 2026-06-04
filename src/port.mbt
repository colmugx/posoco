///|
pub(all) enum HookError {
  Aborted(String)
  Deferred(reason~ : String)
} derive(Eq, Debug)

///|
pub impl Show for HookError with fn to_string(self) -> String {
  match self {
    Aborted(msg) => "HookError::Aborted(\{msg})"
    Deferred(reason~) => "HookError::Deferred(\{reason})"
  }
}

///|
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
pub(open) trait ModelPort {
  async fn chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError

  /// Streaming chat. Default: ignores on_chunk, falls back to chat().
  async fn chat_streaming(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
    on_chunk : (StreamChunk) -> Unit,
  ) -> ModelResponse raise ModelError = _
}

///|
/// Unified tool interface: declare tools via list_tools(), execute via execute().
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[ToolDef]
  async fn execute(Self, name : String, call : ToolCall) -> ToolResult raise RuntimeError
}

///|
pub(open) trait SessionStore {
  fn load(Self, id : String) -> Result[Session, SessionError]
  fn save(Self, id : String, session : Session) -> Result[Unit, SessionError]
}

///|
pub(open) trait Observer {
  fn on_event(Self, event : TurnEvent) -> Unit
}

///|
pub(open) trait Compressor {
  fn compress(Self, messages : Array[Message], ctx : CompressContext) -> CompressAction
}

///|
pub(open) trait PipelineHook {
  async fn on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}

///|
pub(open) trait MemoryPort {
  fn store(Self, entry : MemoryEntry) -> String raise MemoryError
  fn search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  fn delete(Self, id : String) -> Unit raise MemoryError
}

///|
pub(open) trait Lifecycle {
  async fn on_shutdown(Self) -> Unit
}
