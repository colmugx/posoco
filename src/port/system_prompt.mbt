///|
/// SystemPromptContributor: each feature extension can add a section to the
/// aggregate system prompt. A narrow, declarative seam — extensions that
/// only need to add prompt context need not implement the broader
/// PreModelHook.

// SystemPromptContributor trait

///|
/// Returns a section of the system prompt. Empty strings are skipped.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}

// SystemPromptHook — PreModelHook impl that assembles + injects the prompt

///|
/// Combines a fixed base prompt with contributor sections and prepends the
/// result as a System message. Empty sections are skipped.
pub(all) struct SystemPromptHook {
  base_prompt : String
  contributors : Array[SystemPromptSection]
}

///|
/// A contributor entry: manifest id (for section header) and the contributor.
pub(all) struct SystemPromptSection {
  id : String
  contributor : &SystemPromptContributor
}

///|
pub fn SystemPromptSection::SystemPromptSection(
  id~ : String,
  contributor~ : &SystemPromptContributor,
) -> SystemPromptSection {
  { id, contributor }
}

///|
pub fn SystemPromptHook::SystemPromptHook(
  base_prompt~ : String,
  contributors~ : Array[SystemPromptSection],
) -> SystemPromptHook {
  { base_prompt, contributors }
}

///|
/// Assemble base + non-empty contributor sections with `id:` headers.
pub fn SystemPromptHook::assemble(self : SystemPromptHook) -> String {
  let sections : Array[String] = [self.base_prompt]
  for s in self.contributors {
    let text = s.contributor.system_prompt()
    if text != "" {
      sections.push(s.id + ":\n" + text)
    }
  }
  sections.join("\n\n")
}

///|
/// Idempotent injection: replaces the existing SystemMessage at index 0
/// (structural detection, not text-marker based) so repeated hook runs
/// do not accumulate.
pub impl PreModelHook for SystemPromptHook with fn before_model(
  self : SystemPromptHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise HookAbort {
  let assembled = self.assemble()
  let sys_msg : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text(assembled),
  ])
  if messages.length() == 0 {
    return [sys_msg]
  }
  match messages[0] {
    SystemMessage(..) => {
      let new_messages : Array[@kernel.Message] = [sys_msg]
      for i in 1..<messages.length() {
        new_messages.push(messages[i])
      }
      new_messages
    }
    _ => {
      let new_messages : Array[@kernel.Message] = [sys_msg]
      for m in messages {
        new_messages.push(m)
      }
      new_messages
    }
  }
}
