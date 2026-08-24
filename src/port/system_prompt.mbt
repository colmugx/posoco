///|
/// Returns a section of the system prompt. Empty strings are skipped.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}
