///|
/// Returns a section of the system prompt. Blank returns (whitespace only)
/// are skipped; a non-blank return is included verbatim.
///
/// Stability contract: the returned text MUST be byte-for-byte identical for
/// the entire lifetime of one `Agent`. Posoco reads each contributor exactly
/// once — during the first turn's first `before_model` call — and caches the
/// assembled result. Dynamic signals (e.g. plan-mode toggles) MUST NOT be
/// implemented as contributors; inject them through `PipelineHook::before_model`
/// instead. A message injected there is persisted with the session, so keep
/// such notifications idempotent.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}
