///|
/// Package-level re-exports of canonical identity/cancel types so
/// kernel_exec files keep using unqualified names after the promotion to
/// `@kernel` (`domain_run.mbt`). `pub using` preserves existing
/// `@kernel_exec.X` qualified references for sibling packages — single
/// source of truth lives in `@kernel`, do not duplicate aliases elsewhere.
pub using @kernel {
  type RunId,
  type SessionId,
  type EffectId,
  type CancelReason,
  type CancelDisposition,
  type CatalogVersion,
}
