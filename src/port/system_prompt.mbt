///|
/// SystemPromptContributor — extension seam for layered system prompt assembly.
///
/// A cetas-style agent assembles its system prompt from a fixed base section
/// (coding-agent rules, safety, cwd) plus per-feature sections contributed by
/// each tool/feature extension (e.g. posoco-ext-goal contributes a
/// "[GOAL CONTEXT]" block, posoco-ext-read contributes its "use read first"
/// guidance). The agent combines them via `SystemPromptHook`, which is the
/// single PipelineHook that injects the assembled prompt as a System message
/// at BeforeModel.
///
/// This seam exists because:
/// - extensions shouldn't be able to mutate arbitrary messages in the
///   transcript (that is PipelineHook's broader power);
/// - but every feature extension typically *does* want to add prompt context;
/// - so we provide a narrow, declarative trait just for that, with deterministic
///   ordering (registration order within the manifest).

// ──────────────────────────────────────────────────────────────────────────
// SystemPromptContributor trait
// ──────────────────────────────────────────────────────────────────────────

///|
/// Declares one section of the agent's system prompt. Implementations return
/// a plain string; the section is concatenated after the base prompt in
/// manifest order. Returning an empty string is allowed and contributes
/// nothing.
pub(open) trait SystemPromptContributor {
  fn system_prompt(Self) -> String
}

// ──────────────────────────────────────────────────────────────────────────
// SystemPromptHook — PipelineHook impl that assembles + injects the prompt
// ──────────────────────────────────────────────────────────────────────────

///|
/// A PipelineHook that combines a fixed base prompt with all contributor
/// sections, then prepends the result as a System message at BeforeModel.
///
/// At BeforeModel: if any system messages are already in the transcript, the
/// hook *prepends* the assembled prompt to the message list as the new first
/// system message. It does not mutate or remove user/assistant/tool messages.
/// Other stages pass through unchanged.
///
/// Section format (deliberately minimal — hosts that want richer formatting
/// can post-process; the core stays plain):
///
/// ```
/// <base_prompt>
///
/// <contributor_id_1>:
/// <contributor_1 section>
///
/// <contributor_id_2>:
/// <contributor_2 section>
/// ```
///
/// Sections that return "" are skipped entirely (no header emitted).
pub(all) struct SystemPromptHook {
  base_prompt : String
  contributors : Array[SystemPromptSection]
}

///|
/// One contributor entry: its manifest id (for the section header) and the
/// contributor itself. The id makes the assembled prompt self-describing for
/// debugging.
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
/// Assemble the full system prompt: base + every non-empty contributor
/// section, in registration order, with `id:` headers.
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
pub impl PipelineHook for SystemPromptHook with fn on_stage(self, stage : Stage) -> Result[
  Stage,
  HookError,
] {
  match stage {
    BeforeModel(messages) => {
      let assembled = self.assemble()
      let sys_msg : @types.Message = {
        role: @types.Role::System,
        content: [@types.Content::Text(assembled)],
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
      }
      let new_messages : Array[@types.Message] = [sys_msg]
      for m in messages {
        new_messages.push(m)
      }
      Ok(BeforeModel(new_messages))
    }
    other => Ok(other)
  }
}
