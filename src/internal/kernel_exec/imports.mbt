///|
/// Package-level re-exports of canonical identity/cancel types so
/// kernel_exec files keep using unqualified names after the promotion to
pub using @kernel {
  type RunId,
  type SessionId,
  type EffectId,
  type CancelReason,
  type CancelDisposition,
  type CatalogVersion,
}
