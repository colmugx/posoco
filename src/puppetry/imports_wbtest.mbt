///|
/// Kernel aliases used only by Puppetry white-box fixtures. Keeping these
/// aliases in the wbtest compilation unit prevents the production package
/// from reporting unused type declarations while preserving readable
/// canonical fixtures.
using @kernel {
  type AssistantCompletion,
  type ModelFailure,
  type ToolOutcome,
  type CallId,
  type ToolName,
  type OwnerId,
  type CanonicalToolCall,
  type CancelReason,
  type CancelDisposition,
  type ToolCatalogBuilder,
  type CatalogCompositionError,
  type HostChunkCallback,
}
