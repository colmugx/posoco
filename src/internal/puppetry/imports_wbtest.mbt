///|
/// Test-only aliases avoid unused production declarations.
using @kernel {
  type ModelFailure,
  type CallId,
  type ToolName,
  type OwnerId,
  type CancelReason,
}

///|
using @kernel_exec {
  type ToolCatalogBuilder,
  type CatalogCompositionError,
  type HostChunkCallback,
}
