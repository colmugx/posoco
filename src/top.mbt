///|
/// Posoco's public core is the canonical Kernel plus the long-lived Puppet.
///
/// There is deliberately no `Agent`, `run_turn`, compatibility port, or
/// legacy message projection at this boundary. Products compose direct model
/// and tool bindings, validate one catalog, then drive it through `Puppet`.

///|
pub using @kernel {
  trait HostRuntime,
  type HostChunkCallback,
  type AssistantCompletion,
  type AssistantFinishReason,
  type CanonicalContent,
  type CanonicalMessage,
  type CanonicalToolCall,
  type CanonicalToolDef,
  type CanonicalTranscript,
  type CanonicalUsage,
  type CallId,
  type ToolName,
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
}

///|
pub using @puppetry {
  trait ModelBinding,
  trait ToolBinding,
  trait RunJournal,
  trait EventSubscriber,
  trait JournalContributor,
  trait PuppetLifecycleNode,
  type CanonicalHost,
  type CanonicalHostCompositionError,
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

///|
/// Port layer re-exports — UI, system prompt, and the Extension manifest
/// protocol. These are the seams extension authors implement; they live in
/// the `port` subpackage but are surfaced under `@posoco.` so callers do not
/// need to import `@posoco/port` separately.
pub using @port {
  trait UiPort,
  trait SystemPromptContributor,
  trait Extension,
  type UiSlot,
  type UiBody,
  type UiRender,
  type AutocompleteItem,
  type AutocompleteSource,
  type UiDescriptor,
  type UiRequest,
  type UiResponse,
  type NoopUiPort,
  type CompositeUiPort,
  type SystemPromptHook,
  type SystemPromptSection,
  type ExtensionManifest,
}
