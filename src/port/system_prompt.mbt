///|
/// Returns a section of the system prompt. Empty strings are skipped.
///
/// Stability contract: the returned text MUST be byte-for-byte identical for
/// the entire lifetime of one `Agent`. Posoco reads each contributor exactly
/// once — during the first turn's first `before_model` call — and caches the
/// assembled result. Dynamic signals (e.g. plan-mode toggles) MUST NOT be
/// implemented as contributors; inject them through `PipelineHook::before_model`
/// as ephemeral User messages instead.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}
