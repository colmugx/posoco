///|
/// SystemPromptContributor: each feature extension can add a section to the
/// aggregate system prompt. A narrow, declarative seam — extensions that
/// only need to add prompt context need not implement the broader
/// `Hook::before_model`.

// SystemPromptContributor trait

///|
/// Returns a section of the system prompt. Empty strings are skipped.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}
