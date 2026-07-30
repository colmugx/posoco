///|
/// M3.8 — Model-request projection whitebox tests.
///
/// Covers the three synthesized hooks (SystemPromptHook idempotency fix,
/// MemoryRetrievalHook, UiRenderHook) and the Agent composition that
/// wires them into the pump's pre_model_hooks / post_event_hooks chains.

///|
/// Minimal SystemPromptContributor fake returning a fixed string.
struct FixedPromptContributor {
  text : String
}

///|
pub impl @port.SystemPromptContributor for FixedPromptContributor with fn system_prompt(
  self : FixedPromptContributor,
) -> String {
  self.text
}

///|
/// Minimal MemoryPort fake whose `search` returns a fixed entry list.
/// Ignores store/delete (we only test the read path here).
struct FixedMemoryPort {
  entries : Array[@types.MemoryEntry]
}

///|
pub impl @port.MemoryPort for FixedMemoryPort with fn search(
  self : FixedMemoryPort,
  _query : @types.MemoryQuery,
) -> Array[@types.MemoryEntry] {
  self.entries.copy()
}

///|
pub impl @port.MemoryPort for FixedMemoryPort with fn store(
  _self : FixedMemoryPort,
  _entry : @types.MemoryEntry,
) -> String raise @error.MemoryError {
  raise @error.MemoryError::Store("store not supported in FixedMemoryPort")
}

///|
pub impl @port.MemoryPort for FixedMemoryPort with fn delete(
  _self : FixedMemoryPort,
  _id : String,
) -> Unit raise @error.MemoryError {
  raise @error.MemoryError::Delete("delete not supported in FixedMemoryPort")
}

///|
/// MemoryPort whose search always raises MemoryError.
struct FailingMemoryPort {
  _dummy : Unit
}

///|
pub impl @port.MemoryPort for FailingMemoryPort with fn search(
  _self : FailingMemoryPort,
  _query : @types.MemoryQuery,
) -> Array[@types.MemoryEntry] raise @error.MemoryError {
  raise @error.MemoryError::Search("always fails")
}

///|
pub impl @port.MemoryPort for FailingMemoryPort with fn store(
  _self : FailingMemoryPort,
  _entry : @types.MemoryEntry,
) -> String raise @error.MemoryError {
  raise @error.MemoryError::Store("not supported")
}

///|
pub impl @port.MemoryPort for FailingMemoryPort with fn delete(
  _self : FailingMemoryPort,
  _id : String,
) -> Unit raise @error.MemoryError {
  raise @error.MemoryError::Delete("not supported")
}

///|
/// Running before_model twice does NOT accumulate SystemMessages.
/// The hook replaces the head SystemMessage in place.
test "m38_sysprompt/idempotent_across_rounds" {
  let hook = @port.SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[])
  // Round 1: empty transcript → prepends SystemMessage.
  let after1 = hook.before_model([])
  assert_true(after1.length() == 1)
  // Round 2: one SystemMessage present → replaces, does not append.
  let after2 = hook.before_model(after1)
  assert_true(after2.length() == 1)
}

///|
/// When the transcript already has a SystemMessage (e.g. the caller
/// seeded one), the hook replaces its content rather than prepending a
/// second one.
test "m38_sysprompt/replaces_existing_system_message" {
  let hook = @port.SystemPromptHook::SystemPromptHook(base_prompt="NEW", contributors=[])
  let seed : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text("OLD"),
  ])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("hello"),
  ])
  let out = hook.before_model([seed, user])
  assert_true(out.length() == 2)
  // Head is now the new system message.
  match out[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "NEW")
        _ => fail("expected Text content in system message")
      }
    _ => fail("expected SystemMessage at head after replace")
  }
}

///|
/// Contributors are concatenated after the base in registration order.
test "m38_sysprompt/assembles_base_plus_contributors" {
  let c1 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_A",
  }
  let c2 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_B",
  }
  let hook = @port.SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[
    @port.SystemPromptSection::SystemPromptSection(id="a", contributor=c1),
    @port.SystemPromptSection::SystemPromptSection(id="b", contributor=c2),
  ])
  let out = hook.before_model([])
  match out[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => {
          assert_true(s.contains("BASE"))
          assert_true(s.contains("SECTION_A"))
          assert_true(s.contains("SECTION_B"))
        }
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage")
  }
}

///|
/// When memory returns entries, the hook injects a memory SystemMessage
/// carrying the `[MEMORY]` marker. The message lands after the system
/// prompt (head).
test "m38_memory/injects_entries_after_system_prompt" {
  let entry : @types.MemoryEntry = {
    id: "m1",
    content: "prefer tabs over spaces",
    metadata: Map::from_array([]),
    score: None,
  }
  let mem : &@port.MemoryPort = FixedMemoryPort::{ entries: [entry] }
  let hook = @port.MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
  let sys : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text("SYS"),
  ])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("query"),
  ])
  let out = hook.before_model([sys, user])
  // sys, memory, user — three messages.
  assert_true(out.length() == 3)
  // Index 1 is the memory message.
  match out[1] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => {
          assert_true(s.has_prefix("[MEMORY]"))
          assert_true(s.contains("prefer tabs over spaces"))
        }
        _ => fail("expected Text in memory message")
      }
    _ => fail("expected SystemMessage at index 1 for memory")
  }
}

///|
/// Running the hook twice replaces the prior memory message in place
/// (idempotent — no accumulation).
test "m38_memory/idempotent_replaces_prior_memory_message" {
  let entry : @types.MemoryEntry = {
    id: "m1",
    content: "fact one",
    metadata: Map::from_array([]),
    score: None,
  }
  let mem : &@port.MemoryPort = FixedMemoryPort::{ entries: [entry] }
  let hook = @port.MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
  let sys : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text("SYS"),
  ])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("query"),
  ])
  let after1 = hook.before_model([sys, user])
  let after2 = hook.before_model(after1)
  // Still 3 messages: sys, memory, user — no duplicate memory message.
  assert_true(after2.length() == 3)
}

///|
/// Memory search failure is swallowed — the turn is not aborted and
/// messages pass through unchanged.
test "m38_memory/swallows_search_failure" {
  let mem : &@port.MemoryPort = FailingMemoryPort::{ _dummy: () }
  let hook = @port.MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("query"),
  ])
  let out = hook.before_model([user])
  // Unchanged — no memory message injected.
  assert_true(out.length() == 1)
}

///|
/// ModelCompleted stage renders a Status slot intent.
test "m38_ui/model_completed_renders_status" {
  let ui = RecordingUiPort::new_unsupported()
  let hook = @port.UiRenderHook::UiRenderHook(ui=ui as &@port.UiPort)
  let completion : @kernel.Completion = @kernel.Completion::Completion(
    content=[@kernel.Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
    usage=None,
  )
  let stage : @port.PostStage = ModelCompleted(completion~)
  hook.on_post_event(stage)
  let intents = ui.rendered_intents()
  assert_true(intents.length() == 1)
  match intents[0] {
    { slot: Status, .. } => ()
    other => fail("expected Status slot, got " + other.to_string())
  }
}

///|
/// ToolCompleted stage renders a Notice slot intent.
test "m38_ui/tool_completed_renders_notice" {
  let ui = RecordingUiPort::new_unsupported()
  let hook = @port.UiRenderHook::UiRenderHook(ui=ui as &@port.UiPort)
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("c1"),
    name: @kernel.ToolName::unchecked("read"),
    arguments: Json::null(),
  }
  let outcome : @kernel.ToolOutcome = @kernel.Success(
    content="file contents",
    structured=None,
  )
  let stage : @port.PostStage = ToolCompleted(call~, outcome~)
  hook.on_post_event(stage)
  let intents = ui.rendered_intents()
  assert_true(intents.length() == 1)
  match intents[0] {
    { slot: Notice, title: Some(_), .. } => ()
    other => fail("expected Notice slot with title, got " + other.to_string())
  }
}
