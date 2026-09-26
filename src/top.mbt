///|
// Public type re-exports. R3 M3.7: legacy `@types.*` chat/message/tool types
// are deleted; canonical kernel types are the single protocol. The Kernel
// concept name "Canonical*" has been dropped in favour of the unqualified
// name (`Message`, `Content`, ...) so ext authors never see a "Canonical"
// prefix — one system, one protocol.
///|
/// Stable metadata key for Agent-derived automatic session titles. Product
/// UIs and SessionStore adapters may read this without inspecting transcript
/// roles or extension-specific injected messages.
pub const SESSION_TITLE_METADATA_KEY = @types.SESSION_TITLE_METADATA_KEY

pub using @types {
  type ChatOptions,
  type StreamMode,
  type StreamChunk,
  type StreamAccumulator,
  type Session,
  type TurnEvent,
  type TurnResult,
  type EventScope,
}

///|
// Core port traits.
pub using @port {
  trait ModelPort,
  trait DecisionPort,
  trait LogPort,
  trait ToolProvider,
  trait SessionStore,
  trait Observer,
  trait PipelineHook,
  trait MemoryPort,
  trait Lifecycle,
  trait CommandPort,
  trait UiPort,
  trait SystemPromptContributor,
  // Self-reporting manifest protocol.
  trait Extension,
  // Port-related enums.
  type CommandOutcome,
  type CommandType,
  type CommandParam,
  type HookAbort,
  type ParamType,
  type HookStage,
  type ToolDecision,
  type DecisionQuestion,
  type DecisionAnswer,
  type LogLevel,
  type LogDurability,
  type UiHint,
  type UiSlot,
  type UiBody,
  type UiRequest,
  type UiResponse,
  // Port-related structs.
  type DecisionOption,
  type DecisionRequest,
  type DecisionNamedProbability,
  type DecisionUsage,
  type DecisionResult,
  type LogRecord,
  type CommandDef,
  type AutocompleteItem,
  type AutocompleteSource,
  type UiDescriptor,
  type UiRender,
  type UiEntry,
  type ExtensionManifest,
  type ProviderConfig,
  type SessionCheckpoint,
  // Consumption direction: declared capability requirements and the curated
  // composed-capability view delivered at Lifecycle::on_compose.
  type Capability,
  type CompositionView,
  type TaskMode,
  type TaskSpec,
  type TaskReceipt,
  type TaskStatus,
  type TaskOutcome,
  type TaskSubmitError,
  type TaskHandle,
  type Tasks,
}

///|
pub using @error {
  type AgentError,
  type ModelError,
  type DecisionError,
  type LogError,
  type RateLimitInfo,
  type RuntimeError,
  type SessionError,
  type CompositionError,
  type CommandError,
  type MemoryError,
  type UiError,
}

///|
// Canonical domain types used by public extension ports. Catalogs, effects,
// HostRuntime, journals and Puppet remain internal to Posoco's Agent
// implementation and are intentionally not re-exported here.
pub using @kernel {
  type Completion,
  type CompletionPayload,
  type Content,
  type FinishReason,
  type Message,
  type ToolCall,
  type ToolDef,
  type ToolOutcome,
  type NotExecutedReason,
  type ModelFailure,
  type ExecutionPolicy,
  type OwnerId,
  // Model-call + compact protocol used by ModelPort.
  type ModelCallResult,
  type CompactMode,
  type CompactResult,
  type CompactTrigger,
  type ContextPressure,
  // Identity newtypes.
  type CallId,
  type ToolName,
  type Reasoning,
  type Transcript,
  type Usage,
  // Invocation identity passed to model-side port calls (wire contract).
  type InvocationScope,
  type SessionId,
  type RunId,
  type TurnId,
}
