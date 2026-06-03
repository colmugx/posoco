///|
/// port.mbt — Posoco Agent Framework: port interfaces and contract types.
///
/// Defines the abstract port interfaces (hexagonal architecture) that Posoco
/// adapters implement. Port contract types (Stage, HookError, CompressContext,
/// CompressAction) are kept here because they exist solely to define the
/// PipelineHook and Compressor trait boundaries.
///
/// Domain model types live in types.mbt. Error types live in errors.mbt.

///|
/// ——— PipelineHook Contract Types ———
pub(all) enum HookError {
  Aborted(String)
  Deferred(reason~ : String) // needs approval, break tool loop
} derive(Eq, Debug)

///|
pub impl Show for HookError with fn to_string(self) -> String {
  match self {
    Aborted(msg) => "HookError::Aborted(\{msg})"
    Deferred(reason~) => "HookError::Deferred(\{reason})"
  }
}

///|
/// ——— Compressor Contract Types ———
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
/// ——— The 8 Port Traits ———
pub(open) trait ModelPort {
  async fn chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError
}

///|
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[ToolDef]
}

///|
pub(open) trait ToolRuntime {
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
  fn on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}

///|
pub(open) trait MemoryPort {
  fn store(Self, entry : MemoryEntry) -> String raise MemoryError
  fn search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  fn delete(Self, id : String) -> Unit raise MemoryError
}
