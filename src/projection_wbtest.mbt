///|
/// M3.8 — Model-request projection whitebox tests.
///
/// Covers the three synthesized hooks (SystemPromptHook idempotency fix,
/// MemoryRetrievalHook, UiRenderHook) and the Agent composition that
/// wires them into the pump's hooks chain (before_model / on_post_event).

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
async test "m38_sysprompt/idempotent_across_rounds" {
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[])
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
async test "m38_sysprompt/replaces_existing_system_message" {
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="NEW", contributors=[])
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
async test "m38_sysprompt/assembles_base_plus_contributors" {
  let c1 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_A",
  }
  let c2 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_B",
  }
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[
    SystemPromptSection::SystemPromptSection(id="a", contributor=c1),
    SystemPromptSection::SystemPromptSection(id="b", contributor=c2),
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
async test "m38_memory/injects_entries_after_system_prompt" {
  let entry : @types.MemoryEntry = {
    id: "m1",
    content: "prefer tabs over spaces",
    metadata: Map::from_array([]),
    score: None,
  }
  let mem : &@port.MemoryPort = FixedMemoryPort::{ entries: [entry] }
  let hook = MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
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
async test "m38_memory/idempotent_replaces_prior_memory_message" {
  let entry : @types.MemoryEntry = {
    id: "m1",
    content: "fact one",
    metadata: Map::from_array([]),
    score: None,
  }
  let mem : &@port.MemoryPort = FixedMemoryPort::{ entries: [entry] }
  let hook = MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
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
async test "m38_memory/swallows_search_failure" {
  let mem : &@port.MemoryPort = FailingMemoryPort::{ _dummy: () }
  let hook = MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("query"),
  ])
  let out = hook.before_model([user])
  // Unchanged — no memory message injected.
  assert_true(out.length() == 1)
}

///|
/// ModelCompleted stage emits NO render intent: it is an intermediate state
/// in every tool→model round-trip; a persistent "model responded" Status
/// intent misleads the host UI into showing a stalled final state mid-turn.
async test "m38_ui/model_completed_renders_nothing" {
  let ui = RecordingUiPort::new_unsupported()
  let hook = UiRenderHook::UiRenderHook(ui=ui as &@port.UiPort)
  let completion : @kernel.Completion = @kernel.Completion::Completion(
    content=[@kernel.Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
    usage=None,
  )
  let stage : @port.HookStage = ModelCompleted(completion~)
  hook.on_post_event(stage)
  assert_true(ui.rendered_intents().length() == 0)
}

///|
/// ToolCompleted stage renders a Notice slot intent.
async test "m38_ui/tool_completed_renders_notice" {
  let ui = RecordingUiPort::new_unsupported()
  let hook = UiRenderHook::UiRenderHook(ui=ui as &@port.UiPort)
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("c1"),
    name: @kernel.ToolName::unchecked("read"),
    arguments: Json::null(),
  }
  let outcome : @kernel.ToolOutcome = @kernel.Success(
    content="file contents",
    structured=None,
  )
  let stage : @port.HookStage = ToolCompleted(call~, outcome~)
  hook.on_post_event(stage)
  let intents = ui.rendered_intents()
  assert_true(intents.length() == 1)
  match intents[0] {
    { slot: Notice, title: Some(_), .. } => ()
    other => fail("expected Notice slot with title, got " + other.to_string())
  }
}

///|
/// `on_failure` is invoked with a sanitized reason when memory search
/// fails; messages still pass through unchanged.
async test "m38_memory/search_failure_invokes_on_failure" {
  let seen : Array[String] = []
  let mem : &@port.MemoryPort = FailingMemoryPort::{ _dummy: () }
  let hook = MemoryRetrievalHook::MemoryRetrievalHook(memories=[mem], on_failure=fn(
    reason,
  ) {
    seen.push(reason)
  })
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("query"),
  ])
  let out = hook.before_model([user])
  // Unchanged — no memory message injected.
  assert_true(out.length() == 1)
  assert_eq(seen.length(), 1)
  assert_true(seen[0].contains("MemoryError::Search"))
}

///|
/// End-to-end: a failing MemoryPort surfaces exactly one
/// `Custom(source="posoco.core", label="secondary_failure")` observer
/// event; the turn still completes (primary outcome untouched).
async test "m38_memory/failing_search_emits_secondary_failure_event" {
  let model = ScriptedModel([Respond(tk_stop_response("hi"))])
  let mem : &@port.MemoryPort = FailingMemoryPort::{ _dummy: () }
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="memory", memory=[mem]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "session_1")
  ignore(result)
  let mut secondary = 0
  let mut completed = 0
  let mut failed = 0
  for e in observer.events() {
    match e {
      Custom(source~, label~, ..) =>
        if source == "posoco.core" && label == "secondary_failure" {
          secondary = secondary + 1
        }
      TurnCompleted => completed = completed + 1
      TurnFailed(_) => failed = failed + 1
      _ => ()
    }
  }
  assert_eq(secondary, 1)
  assert_eq(completed, 1)
  assert_eq(failed, 0)
}

// ──────────────────────────────────────────────────────────────────────────
// W1.1 — same-length pre-model hook rewrite is a real rewrite
// ──────────────────────────────────────────────────────────────────────────

///|
/// Probe hook: replaces the transcript with one different message of the
/// SAME count. Before the reducer became the sole transcript writer the
/// pump's length-compare guard silently dropped this rewrite.
struct SameLengthAgentHook {}

///|
pub impl @port.PipelineHook for SameLengthAgentHook with fn before_model(
  _self,
  _messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  [@kernel.UserMessage(content=[@kernel.Text("rewritten-by-hook")])]
}

///|
/// W1.1: the transcript seeds through Start after pre-model hooks rewrite the
/// initial messages at prompt start; the model must observe the REWRITTEN
/// content even when the rewrite keeps the same message count.
async test "m38_hooks/same_length_rewrite_reaches_model" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="hook", hooks=[SameLengthAgentHook::{  }]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("original"), "session_rewrite")
  ignore(result)
  // The model must have received the REWRITTEN message, not the original.
  assert_eq(model.received_messages.length(), 1)
  let received = model.received_messages[0]
  assert_eq(received.length(), 1)
  match received[0] {
    @kernel.UserMessage(content~) =>
      match content[0] {
        @kernel.Text(text) => assert_eq(text, "rewritten-by-hook")
        _ => fail("expected text content")
      }
    _ => fail("expected rewritten user message")
  }
  // The turn still completed exactly once.
  let mut completed = 0
  let mut failed = 0
  for e in observer.events() {
    match e {
      TurnCompleted => completed = completed + 1
      TurnFailed(_) => failed = failed + 1
      _ => ()
    }
  }
  assert_eq(completed, 1)
  assert_eq(failed, 0)
}

// ──────────────────────────────────────────────────────────────────────────
// BR-5 — UiRenderHook projection is opt-in, never auto-injected
// ──────────────────────────────────────────────────────────────────────────

///|
/// Build an Agent whose only UI contributor is `ui`, with a model that
/// requests one tool call and then stops.
fn build_ui_agent(
  ui : RecordingUiPort,
  ui_projection : Bool,
) -> Agent raise @error.CompositionError {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
  Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], ui=[ui], sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
    ui_projection~,
  )
}

///|
/// BR-5: by default Posoco's render policy is NOT installed — a host that
/// contributes a UiPort but does not opt in sees zero render intents.
async test "br5_ui_projection/default_off_renders_nothing" {
  let ui = RecordingUiPort()
  let agent = build_ui_agent(ui, false)
  let result = agent.run_turn(tk_user_msg("hi"), "session_ui_off")
  assert_eq(result.final_session_id, "session_ui_off")
  assert_eq(ui.render_count(), 0)
}

///|
/// BR-5: `ui_projection=true` restores the built-in UiRenderHook — tool
/// completion projects into the Notice slot.
async test "br5_ui_projection/opt_in_renders_tool_notice" {
  let ui = RecordingUiPort()
  let agent = build_ui_agent(ui, true)
  let result = agent.run_turn(tk_user_msg("hi"), "session_ui_on")
  assert_eq(result.final_session_id, "session_ui_on")
  assert_true(ui.render_count() > 0)
  let notices = ui.rendered_in_slot(@port.UiSlot::Notice)
  assert_eq(notices.length(), 1)
}
