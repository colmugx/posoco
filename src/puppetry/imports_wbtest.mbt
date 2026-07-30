///|
/// Kernel aliases used only by Puppetry white-box fixtures. Keeping these
/// aliases in the wbtest compilation unit prevents the production package
/// from reporting unused type declarations while preserving readable
/// canonical fixtures.
///
/// R3 M3.7: types already re-exported via `imports.mbt` (Message, Content,
/// Completion, CompletionPayload, FinishReason, Usage, ToolCall, ToolDef,
/// ToolOutcome, CompactMode, CompactResult) are NOT duplicated here.
using @kernel {
  type ModelFailure,
  type CallId,
  type ToolName,
  type OwnerId,
  type ToolCatalogBuilder,
  type CatalogCompositionError,
  type HostChunkCallback,
  type CancelReason,
}
