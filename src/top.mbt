///|
// Public type re-exports. R3 M3.7: legacy `@types.*` chat/message/tool types
// are deleted; canonical kernel types are the single protocol. The Kernel
// concept name "Canonical*" has been dropped in favour of the unqualified
// name (`Message`, `Content`, ...) so ext authors never see a "Canonical"
// prefix — one system, one protocol.
pub using @types {
  type ChatOptions,
  type StreamMode,
  type StreamChunk,
  type StreamAccumulator,
  type Session,
  type TurnEvent,
  type TurnResult,
  type MemoryEntry,
  type MemoryQuery,
}

///|
// Core port traits.
pub using @port {
  trait ModelPort,
  trait ToolProvider,
  trait SessionStore,
  trait Observer,
  trait PostEventHook,
  trait PreModelHook,
  trait PreToolHook,
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
  type PostStage,
  type ToolHookDecision,
  type UiHint,
  type UiSlot,
  type UiBody,
  type UiRequest,
  type UiResponse,
  // Port-related structs.
  type CommandDef,
  type AutocompleteItem,
  type AutocompleteSource,
  type UiDescriptor,
  type UiRender,
  type SystemPromptHook,
  type SystemPromptSection,
  type ExtensionManifest,
  type ProviderConfig,
  // Builtin UiPort impls (testkit-grade, also used by hosts without a UI).
  type NoopUiPort,
  type CompositeUiPort,
}

///|
pub using @error {
  type AgentError,
  type ModelError,
  type RuntimeError,
  type SessionError,
  type CompositionError,
  type CommandError,
  type MemoryError,
  type UiError,
}

///|
// Kernel canonical types — single protocol, no "Canonical" prefix. These are
// the types ext/agent developers see; `HostRuntime` and other reducer-internal
// concepts stay here because PortHostAdapter implements the trait, but ext
// authors typically interact with ModelPort/ToolProvider/SessionStore instead.
pub using @kernel {
  trait HostRuntime,
  type HostChunkCallback,
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
  type ModelStepId,
  type EffectId,
  type RunId,
  type SessionId,
  type RunOutcome,
  type KernelEvent,
  type Budget,
  type BudgetDimension,
  type CatalogVersion,
  type ToolCatalogBuilder,
  type ToolCatalogSnapshot,
  type CatalogCompositionError,
  type ExecutionPolicy,
  type OwnerId,
  type CancelReason,
  type KernelError,
  // Model-call + compact protocol (R3 M3.7).
  type ModelCallResult,
  type CompactMode,
  type CompactResult,
  type CompactTrigger,
  // Identity newtypes.
  type CallId,
  type ToolName,
  type Reasoning,
  type Transcript,
  type Usage,
}

///|
pub using @puppetry {
  trait RunJournal,
  trait EventSubscriber,
  trait JournalContributor,
  trait PuppetLifecycleNode,
  type ModelId,
  type Puppet,
  type PuppetConfig,
  type PuppetError,
  type PromptResult,
  type TurnId,
  type QuiescentStatus,
  type InMemoryJournal,
  type EventEnvelope,
  type SubscriberError,
  type NoopSubscriber,
  type NoopContributor,
}
