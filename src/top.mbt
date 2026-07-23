///|
pub using @port {
  trait ModelPort,
  trait ToolProvider,
  trait SessionStore,
  trait Observer,
  trait Compressor,
  trait PipelineHook,
  trait MemoryPort,
  trait Lifecycle,
  trait CommandPort,
  type CommandDef,
  type CommandParam,
  type Stage,
  type HookError,
}

///|
pub using @types {
  type Message,
  type Role,
  type Content,
  type ToolCall,
  type ToolResult,
  type ToolDef,
  type Session,
  type TurnEvent,
  type TurnResult,
  type ModelResponse,
  type ChatOptions,
  type StreamChunk,
  type ToolChoice,
  type ReasoningEffort,
  type StreamAccumulator,
  type FinishReason,
  type Usage,
}

///|
pub using @error {
  type ModelError,
  type SessionError,
  type RuntimeError,
  type AgentError,
  type CompositionError,
}
