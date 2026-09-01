///|
/// M3.8 — Model-request projection whitebox tests.
///
/// Covers the SystemPromptHook projection and the Agent composition that
/// wires hooks into the pump chain (before_model / on_post_event), the
/// same-length rewrite guard, UI projection opt-in, and the memory surface:
/// session-opening inbound injection plus the built-in memory_search /
/// memory_add tools.

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
/// Mutable contributor used to prove the SystemPromptHook caches the assembled
/// text on first use. The shared `Ref[String]` lets later mutations reach the
/// underlying value even when the contributor is copied into multiple contexts.
struct MutablePromptContributor {
  text : Ref[String]
}

///|
pub impl @port.SystemPromptContributor for MutablePromptContributor with fn system_prompt(
  self : MutablePromptContributor,
) -> String {
  self.text.val
}

///|
/// Lifecycle fake that mutates a contributor from its on_start callback.
struct StartSettingLifecycle {
  target : Ref[String]
}

///|
pub impl @port.Lifecycle for StartSettingLifecycle with fn on_start(
  self : StartSettingLifecycle,
) -> Unit {
  self.target.val = "after_start"
}

///|
pub impl @port.Lifecycle for StartSettingLifecycle with fn on_compose(
  _self : StartSettingLifecycle,
  _ctx : @port.CompositionView,
) -> Unit {
  ()
}

///|
pub impl @port.Lifecycle for StartSettingLifecycle with fn on_shutdown(
  _self : StartSettingLifecycle,
) -> Unit {
  ()
}

///|
/// MemoryPort whose every slot raises MemoryError — the failure arm of the
/// port contract. Success, empty, and per-session cycling are covered by the
/// testkit `ScriptedMemoryPort`.
struct FailingInboundPort {
  _dummy : Unit
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn inbound(
  _self : FailingInboundPort,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  raise @error.MemoryError::Inbound("always fails for \{session_id} \{request}")
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn store(
  _self : FailingInboundPort,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  raise @error.MemoryError::Store(
    "always fails: \{content} \{metadata.length()}",
  )
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn search(
  _self : FailingInboundPort,
  query~ : String,
  top_k? : Int,
) -> String? raise @error.MemoryError {
  ignore(top_k)
  raise @error.MemoryError::Search("always fails: \{query}")
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn delete(
  _self : FailingInboundPort,
  id : String,
) -> Unit raise @error.MemoryError {
  raise @error.MemoryError::Delete("always fails: \{id}")
}

///|
/// Inbound port that suspends well past any small timeout before answering —
/// the timeout arm of the inbound collector.
struct SlowInboundPort {
  _dummy : Unit
}

///|
pub impl @port.MemoryPort for SlowInboundPort with fn inbound(
  _self : SlowInboundPort,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  // The cancellation raised into the sleeping task when the timeout fires
  // is this task's business, not the port contract's — swallow it.
  @async.sleep(200) catch {
    _ => ()
  }
  Some("too late for \{session_id} \{request}")
}

///|
pub impl @port.MemoryPort for SlowInboundPort with fn store(
  _self : SlowInboundPort,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  "slow-\{content.length()}-\{metadata.length()}"
}

///|
pub impl @port.MemoryPort for SlowInboundPort with fn search(
  _self : SlowInboundPort,
  query~ : String,
  top_k? : Int,
) -> String? raise @error.MemoryError {
  ignore((query, top_k))
  None
}

///|
pub impl @port.MemoryPort for SlowInboundPort with fn delete(
  _self : SlowInboundPort,
  id : String,
) -> Unit raise @error.MemoryError {
  ignore(id)
}

///|
/// Assert the message is core's injected inbound-memory message: user role,
/// one Text carrying the lead line and the provider bodies in order,
/// separated by blank lines.
fn expect_inbound_message(
  message : @kernel.Message,
  bodies : Array[String],
) -> Unit raise {
  match message {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(text), ..] =>
          assert_eq(text, MEMORY_INBOUND_LEAD + "\n\n" + bodies.join("\n\n"))
        _ => fail("expected Text content in inbound memory message")
      }
    _ => fail("expected UserMessage inbound memory at this index")
  }
}

///|
/// Build a tool call aimed at the built-in memory tools.
fn tk_memory_call(
  tool : String,
  args : Array[(String, Json)],
) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked("mem_call"),
    name: @kernel.ToolName::unchecked(tool),
    arguments: Json::object(Map::from_array(args)),
  }
}

///|
/// Drive the white-box `MemoryToolProvider` through its port trait.
async fn exec_memory_tool(
  provider : MemoryToolProvider,
  tool : String,
  args : Array[(String, Json)],
) -> @kernel.ToolOutcome {
  (provider as &@port.ToolProvider).execute(tool, tk_memory_call(tool, args))
}

///|
/// Sanitized error payloads of the `secondary_failure` Custom events emitted
/// for `hook_point`, in emission order.
fn secondary_failure_errors(
  observer : RecordingObserver,
  hook_point : String,
) -> Array[String] raise {
  let out : Array[String] = []
  for e in observer.events() {
    match e {
      Custom(source~, label~, data~) =>
        if source == "posoco.core" && label == "secondary_failure" {
          match data {
            Json::Object(fields) =>
              match fields.get("hook_point") {
                Some(Json::String(hp)) if hp == hook_point =>
                  match fields.get("error") {
                    Some(Json::String(err)) => out.push(err)
                    _ => fail("secondary_failure event missing 'error'")
                  }
                _ => ()
              }
            _ => fail("secondary_failure data must be a JSON object")
          }
        }
      _ => ()
    }
  }
  out
}

///|
/// Compose a one-model Agent over `store` with the given memory sources,
/// observer, system prompt, and inbound timeout — the standard rig for the
/// inbound-injection tests.
fn build_memory_agent(
  model : ScriptedModel,
  memory : Array[&@port.MemoryPort],
  store : RecordingSessionStore,
  observer : RecordingObserver,
  system_prompt : String?,
  timeout_ms : Int?,
) -> Agent raise @error.CompositionError {
  let config : AgentConfig = {
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
    system_prompt,
    memory_inbound_timeout_ms: timeout_ms,
  }
  Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="memory", memory~),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config~,
  )
}

///|
/// Running before_model twice does NOT accumulate SystemMessages.
/// The hook owns index 0 and keeps the assembled text stable.
async test "m38_sysprompt/idempotent_across_rounds" {
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[])
  // Round 1: empty transcript → prepends SystemMessage.
  let after1 = hook.before_model([])
  assert_true(after1.length() == 1)
  match after1[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "BASE")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage")
  }
  // Round 2: identical SystemMessage at head → returns the same array.
  let after2 = hook.before_model(after1)
  assert_true(after2.length() == 1)
  assert_true(physical_equal(after2, after1))
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
/// Contributors are concatenated after the base in registration order,
/// with blank lines between sections.
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
        [Text(s), ..] => assert_eq(s, "BASE\n\na:\nSECTION_A\n\nb:\nSECTION_B")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage")
  }
}

///|
/// When the assembled prompt is empty, the hook returns messages unchanged
/// and does not inject a blank SystemMessage or evict an existing head.
async test "m38_sysprompt/empty_prompt_short_circuits" {
  let empty : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "",
  }
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="", contributors=[
    SystemPromptSection::SystemPromptSection(id="empty", contributor=empty),
  ])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("hello"),
  ])
  let input = [user]
  let out = hook.before_model(input)
  assert_true(out.length() == 1)
  assert_true(physical_equal(out, input))
}

///|
/// When there is no SystemMessage at index 0, the hook prepends one.
async test "m38_sysprompt/prepends_when_no_system_message" {
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="BASE", contributors=[])
  let user : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("hello"),
  ])
  let out = hook.before_model([user])
  assert_true(out.length() == 2)
  match out[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "BASE")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage at index 0")
  }
  match out[1] {
    UserMessage(_) => ()
    _ => fail("expected original UserMessage to shift to index 1")
  }
}

///|
/// The assembled text is cached on first use: a later mutation of the
/// contributor is ignored.
async test "m38_sysprompt/caches_assembled_text" {
  let text_ref = Ref::Ref("first")
  let contributor = MutablePromptContributor::{ text: text_ref, }
  let hook = SystemPromptHook::SystemPromptHook(base_prompt="", contributors=[
    SystemPromptSection::SystemPromptSection(
      id="mut",
      contributor=contributor as &@port.SystemPromptContributor,
    ),
  ])
  let out1 = hook.before_model([])
  match out1[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "mut:\nfirst")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage")
  }
  contributor.text.val = "second"
  let out2 = hook.before_model([])
  match out2[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "mut:\nfirst")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage")
  }
}

///|
/// End-to-end: AgentConfig.system_prompt is the first section, contributor
/// sections follow in registration order, separated by blank lines, and the
/// result is a single SystemMessage at index 0.
async test "m38_sysprompt/config_base_precedes_contributors" {
  let contributor : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "from_ext",
  }
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="ext", prompt_contributors=[contributor]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config={
      max_tool_rounds: Some(10),
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
      compact_threshold: None,
      system_prompt: Some("host_base"),
      memory_inbound_timeout_ms: None,
    },
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_base"))
  assert_true(model.received_messages.length() == 1)
  let prompt = model.received_messages[0]
  assert_true(prompt.length() >= 1)
  match prompt[0] {
    @kernel.SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "host_base\n\next:\nfrom_ext")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage at index 0")
  }
}

///|
/// Lifecycle::on_start runs before the first before_model, so a contributor
/// whose value is set in on_start is read with the post-start value.
async test "m38_sysprompt/lazy_assembly_reads_post_on_start" {
  let text_ref = Ref::Ref("before_start")
  let contributor = MutablePromptContributor::{ text: text_ref, }
  let starter : &@port.Lifecycle = StartSettingLifecycle::{ target: text_ref, }
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="lifecycle", lifecycle=[starter]),
      tk_ext(id="ext", prompt_contributors=[
        contributor as &@port.SystemPromptContributor,
      ]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_lazy"))
  assert_true(model.received_messages.length() == 1)
  let prompt = model.received_messages[0]
  match prompt[0] {
    @kernel.SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "ext:\nafter_start")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage at index 0")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// M3.8 memory — session-opening inbound injection (Agent-level)
// ──────────────────────────────────────────────────────────────────────────

///|
/// A fresh session injects once: the first model-visible transcript is
/// [system, memory, input]; the port sees the session id and the exact
/// first-input text; the memory text is core's lead plus the provider body.
async test "m38_memory/fresh_session_injects_once" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let mem = ScriptedMemoryPort(inbounds=[Some("fact one")])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    RecordingSessionStore(),
    RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "session_1"))
  assert_eq(mem.call_count(), 1)
  assert_eq(mem.received_sessions(), ["session_1"])
  assert_eq(mem.received_requests(), ["hello"])
  assert_eq(model.received_messages.length(), 1)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 3)
  match prompt[0] {
    @kernel.SystemMessage(content~) =>
      match content {
        [@kernel.Text(s), ..] => assert_eq(s, "SYS")
        _ => fail("expected Text content in system message")
      }
    _ => fail("expected SystemMessage at index 0")
  }
  expect_inbound_message(prompt[1], ["fact one"])
  match prompt[2] {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(s), ..] => assert_eq(s, "hello")
        _ => fail("expected Text content in the user input")
      }
    _ => fail("expected the real input at index 2")
  }
}

///|
/// Without a system prompt the memory message lands at index 0 and the real
/// input shifts to index 1.
async test "m38_memory/memory_at_front_without_system_prompt" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let mem = ScriptedMemoryPort(inbounds=[Some("fact")])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    RecordingSessionStore(),
    RecordingObserver(),
    None,
    None,
  )
  ignore(agent.run_turn(tk_user_msg("query"), "session_1"))
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 2)
  expect_inbound_message(prompt[0], ["fact"])
  match prompt[1] {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(s), ..] => assert_eq(s, "query")
        _ => fail("expected Text content in the user input")
      }
    _ => fail("expected the real input at index 1")
  }
}

///|
/// A second turn on the same session never re-reads the port; the injected
/// memory message stays byte-identical at the head of the model-visible
/// prefix while the transcript grows behind it.
async test "m38_memory/second_turn_no_reread_prefix_stable" {
  let model = ScriptedModel([
    Respond(tk_stop_response("ok")),
    Respond(tk_stop_response("ok")),
  ])
  let mem = ScriptedMemoryPort(inbounds=[Some("fact")])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    RecordingSessionStore(),
    RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "session_1"))
  ignore(agent.run_turn(tk_user_msg("again"), "session_1"))
  assert_eq(mem.call_count(), 1)
  let first = model.received_messages[0]
  let second = model.received_messages[1]
  assert_eq(first.length(), 3)
  for i in 0..<first.length() {
    assert_eq(second[i], first[i])
  }
  assert_true(second.length() > first.length())
}

///|
/// An empty inbound read spends the session's single attempt: no memory
/// message, the turn still completes, and a later turn of the same session
/// does not retry. A second session in the same process gets its own read.
async test "m38_memory/empty_inbound_spends_attempt_per_session" {
  let model = ScriptedModel([
    Respond(tk_stop_response("ok")),
    Respond(tk_stop_response("ok")),
    Respond(tk_stop_response("ok")),
  ])
  let mem = ScriptedMemoryPort(inbounds=[None, Some("second session fact")])
  let observer = RecordingObserver()
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    RecordingSessionStore(),
    observer,
    None,
    None,
  )
  let first_turn = agent.run_turn(tk_user_msg("q1"), "session_1")
  assert_eq(first_turn.final_session_id, "session_1")
  assert_eq(model.received_messages[0].length(), 1)
  // Second turn of the same session: the attempt is already spent, so no
  // retry — history replays unshifted.
  ignore(agent.run_turn(tk_user_msg("q2"), "session_1"))
  assert_eq(mem.call_count(), 1)
  assert_eq(model.received_messages[1].length(), 3)
  match model.received_messages[1][0] {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(s), ..] => assert_eq(s, "q1")
        _ => fail("expected Text content")
      }
    _ => fail("expected history replay to start with the first input")
  }
  // A fresh session gets its own single attempt.
  ignore(agent.run_turn(tk_user_msg("q3"), "session_2"))
  assert_eq(mem.call_count(), 2)
  assert_eq(mem.received_sessions(), ["session_1", "session_2"])
  assert_eq(model.received_messages[2].length(), 2)
  expect_inbound_message(model.received_messages[2][0], ["second session fact"])
  let mut completed = 0
  let mut failed = 0
  for e in observer.events() {
    match e {
      TurnCompleted => completed = completed + 1
      TurnFailed(_) => failed = failed + 1
      _ => ()
    }
  }
  assert_eq(completed, 3)
  assert_eq(failed, 0)
}

///|
/// Resume: a second Agent over the same persisted session replays the
/// original memory message byte-for-byte and never reads its own port —
/// the prefix a session was formed under survives process boundaries.
async test "m38_memory/resume_skips_read_and_replays_prefix" {
  let model1 = ScriptedModel([Respond(tk_stop_response("ok"))])
  let mem1 = ScriptedMemoryPort(inbounds=[Some("fact")])
  let store = RecordingSessionStore()
  let agent1 = build_memory_agent(
    model1,
    [mem1 as &@port.MemoryPort],
    store,
    RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent1.run_turn(tk_user_msg("hello"), "session_1"))
  let model2 = ScriptedModel([Respond(tk_stop_response("ok"))])
  let mem2 = ScriptedMemoryPort(inbounds=[Some("CHANGED")])
  let agent2 = build_memory_agent(
    model2,
    [mem2 as &@port.MemoryPort],
    store,
    RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent2.run_turn(tk_user_msg("resume"), "session_1"))
  assert_eq(mem2.call_count(), 0)
  let first = model1.received_messages[0]
  let second = model2.received_messages[0]
  for i in 0..<first.length() {
    assert_eq(second[i], first[i])
  }
  assert_true(second.length() > first.length())
}

///|
/// A session whose persisted transcript is non-empty never reads the port —
/// injection is keyed to the session's first turn, not to process state.
async test "m38_memory/preseeded_history_never_injects" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let mem = ScriptedMemoryPort(inbounds=[Some("must never be read")])
  let store = RecordingSessionStore()
  store.seed("session_pre", {
    messages: [
      tk_user_msg("old question"),
      @kernel.AssistantMessage(
        content=[@kernel.Text("old answer")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.Stop,
      ),
    ],
    metadata: Map::from_array([]),
  })
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    store,
    RecordingObserver(),
    None,
    None,
  )
  ignore(agent.run_turn(tk_user_msg("new question"), "session_pre"))
  assert_eq(mem.call_count(), 0)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 3)
  match prompt[0] {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(s), ..] => assert_eq(s, "old question")
        _ => fail("expected Text content")
      }
    _ => fail("expected the seeded history to start unshifted")
  }
}

///|
/// Multiple providers land in ONE message: bodies verbatim, in registration
/// order, behind the single lead line.
async test "m38_memory/two_providers_merge_into_one_message" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let notes = ScriptedMemoryPort(inbounds=[Some("notes fact")])
  let book = ScriptedMemoryPort(inbounds=[Some("book fact")])
  let agent = build_memory_agent(
    model,
    [notes as &@port.MemoryPort, book as &@port.MemoryPort],
    RecordingSessionStore(),
    RecordingObserver(),
    None,
    None,
  )
  ignore(agent.run_turn(tk_user_msg("query"), "session_1"))
  assert_eq(notes.call_count(), 1)
  assert_eq(book.call_count(), 1)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 2)
  expect_inbound_message(prompt[0], ["notes fact", "book fact"])
}

///|
/// A failing provider neither cancels the turn nor masks its sibling: the
/// sibling's body still lands, and exactly one `secondary_failure` event
/// with hook_point "memory_inbound" reaches the observer.
async test "m38_memory/failing_provider_does_not_mask_sibling" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let failing : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let ok = ScriptedMemoryPort(inbounds=[Some("recovered")])
  let observer = RecordingObserver()
  let agent = build_memory_agent(
    model,
    [failing, ok as &@port.MemoryPort],
    RecordingSessionStore(),
    observer,
    None,
    None,
  )
  let result = agent.run_turn(tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 2)
  expect_inbound_message(prompt[0], ["recovered"])
  let failures = secondary_failure_errors(observer, "memory_inbound")
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("MemoryError::Inbound"))
}

///|
/// A port that hangs past `memory_inbound_timeout_ms` is cut off: no
/// injection, the turn completes, and one secondary_failure names the
/// timeout.
async test "m38_memory/inbound_timeout_emits_secondary_failure" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let slow : &@port.MemoryPort = SlowInboundPort::{ _dummy: (), }
  let observer = RecordingObserver()
  let agent = build_memory_agent(
    model,
    [slow],
    RecordingSessionStore(),
    observer,
    None,
    Some(1),
  )
  let result = agent.run_turn(tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_eq(model.received_messages[0].length(), 1)
  let failures = secondary_failure_errors(observer, "memory_inbound")
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("timeout"))
}

// ──────────────────────────────────────────────────────────────────────────
// M3.8 memory — built-in memory_search / memory_add tools (white-box)
// ──────────────────────────────────────────────────────────────────────────

///|
/// memory_search fans out to every source and joins the hits in
/// registration order; a no-hit source contributes nothing.
async test "m38_memory/search_merges_sources_in_order" {
  let a = ScriptedMemoryPort(inbounds=[], search_script=[Some("hit-a")])
  let b = ScriptedMemoryPort(inbounds=[], search_script=[Some("hit-b")])
  let empty = ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[
      ("a", a as &@port.MemoryPort),
      ("b", b as &@port.MemoryPort),
      ("c", empty as &@port.MemoryPort),
    ],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("prefs")),
  ])
  match outcome {
    @kernel.Success(content~, structured=None) =>
      assert_eq(content, "hit-a\n\nhit-b")
    _ => fail("expected Success outcome for memory_search merge")
  }
  assert_eq(a.received_searches(), [("prefs", None)])
  assert_eq(b.received_searches(), [("prefs", None)])
  assert_eq(empty.received_searches(), [("prefs", None)])
}

///|
/// Every source empty → a clean Success telling the model there is nothing.
async test "m38_memory/search_all_empty_reports_no_match" {
  let a = ScriptedMemoryPort(inbounds=[])
  let b = ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("anything")),
  ])
  match outcome {
    @kernel.Success(content~, structured=None) =>
      assert_eq(content, "No matching memory.")
    _ => fail("expected Success outcome for all-empty search")
  }
}

///|
/// A raising source is skipped: its sibling's hit still lands and the
/// failure callback names the failed source.
async test "m38_memory/search_failure_skips_source_and_names_it" {
  let bad : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let good = ScriptedMemoryPort(inbounds=[], search_script=[Some("hit-b")])
  let reasons : Array[String] = []
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[("bad", bad), ("good", good as &@port.MemoryPort)],
    on_failure=fn(reason) { reasons.push(reason) },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("prefs")),
  ])
  match outcome {
    @kernel.Success(content~, structured=None) => assert_eq(content, "hit-b")
    _ => fail("expected the surviving sibling's hit")
  }
  assert_eq(reasons.length(), 1)
  assert_true(reasons[0].contains("bad"))
  assert_true(reasons[0].contains("MemoryError::Search"))
}

///|
/// memory_add without a source writes to EVERY source; receipt lines carry
/// each source's ticket in registration order, and every store records the
/// content with empty provider-convention metadata.
async test "m38_memory/add_writes_all_sources_with_receipts" {
  let a = ScriptedMemoryPort(inbounds=[])
  let b = ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("remember this")),
  ])
  match outcome {
    @kernel.Success(content~, structured=None) =>
      // Tickets are per source (each fake numbers from 0); the receipt
      // prefixes are what identify the target.
      assert_eq(content, "a: scripted-0\nb: scripted-0")
    _ => fail("expected Success outcome for memory_add write-all")
  }
  for port in [a, b] {
    let stores = port.received_stores()
    assert_eq(stores.length(), 1)
    let (content, metadata) = stores[0]
    assert_eq(content, "remember this")
    assert_eq(metadata.length(), 0)
  }
}

///|
/// memory_add with an explicit source routes to exactly that provider.
async test "m38_memory/add_targeted_source_routes_to_one" {
  let a = ScriptedMemoryPort(inbounds=[])
  let b = ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("for b only")),
    ("source", Json::string("b")),
  ])
  match outcome {
    @kernel.Success(content~, structured=None) =>
      assert_eq(content, "b: scripted-0")
    _ => fail("expected Success outcome for targeted memory_add")
  }
  assert_eq(a.received_stores().length(), 0)
  assert_eq(b.received_stores().length(), 1)
}

///|
/// memory_add rejects an unknown source (listing the valid ones) and empty
/// content as model-visible ToolReportedError; an unregistered memory tool
/// name raises RuntimeError::UnknownTool.
async test "m38_memory/add_rejects_unknown_source_and_empty_content" {
  let a = ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider::MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let unknown = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("x")),
    ("source", Json::string("zz")),
  ])
  match unknown {
    @kernel.ToolReportedError(content~, structured=None) => {
      assert_true(content.contains("unknown source 'zz'"))
      assert_true(content.contains("valid sources: a"))
    }
    _ => fail("expected ToolReportedError for unknown source")
  }
  let blank = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("  ")),
  ])
  match blank {
    @kernel.ToolReportedError(content~, structured=None) =>
      assert_eq(content, "memory_add: argument 'content' must be non-empty")
    _ => fail("expected ToolReportedError for empty content")
  }
  assert_eq(a.received_stores().length(), 0)
  let unregistered = Ok(exec_memory_tool(provider, "memory_forget", [])) catch {
    e => Err(e)
  }
  match unregistered {
    Err(@error.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("memory_forget"))
    _ => fail("expected RuntimeError::UnknownTool for unregistered memory tool")
  }
}

///|
/// Storage and retrieval side of the port contract, through the testkit fake
/// every memory test composes: writes route through `store` (ticketed),
/// queries through `search`, removals through `delete` — all recorded in
/// call order with their arguments.
async test "m38_memory/port_store_search_delete_contract" {
  let mem = ScriptedMemoryPort(inbounds=[Some("fact")], search_script=[
    Some("hit"),
  ])
  let port = mem as &@port.MemoryPort
  let ticket = port.store(content="entry", metadata=Map::from_array([]))
  assert_eq(ticket, "scripted-0")
  let second = port.store(content="another", metadata=Map::from_array([]))
  assert_eq(second, "scripted-1")
  let found = port.search(query="entry")
  assert_eq(found, Some("hit"))
  port.delete(ticket)
  assert_eq(mem.received_stores().length(), 2)
  let (content, metadata) = mem.received_stores()[0]
  assert_eq(content, "entry")
  assert_eq(metadata.length(), 0)
  assert_eq(mem.received_deletes(), ["scripted-0"])
  assert_eq(mem.received_searches(), [("entry", None)])
  // Past the script, search degrades to a clean no-hit.
  assert_eq(port.search(query="anything"), None)
}

///|
/// End-to-end: a scripted model step that calls `memory_search` runs the
/// built-in provider through the real tool routing and the outcome lands in
/// the turn's tool results — while the fresh-session inbound message is
/// injected in the same turn.
async test "m38_memory/e2e_memory_search_tool_reaches_sources" {
  let mem = ScriptedMemoryPort(inbounds=[Some("opening fact")], search_script=[
    Some("searched hit"),
  ])
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response(
        "memory_search",
        "call_1",
        Json::object(Map::from_array([("query", Json::string("prefs"))])),
      ),
    ),
    Respond(tk_stop_response("done")),
  ])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    RecordingSessionStore(),
    RecordingObserver(),
    None,
    None,
  )
  let result = agent.run_turn(tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_eq(mem.call_count(), 1)
  assert_eq(mem.received_searches(), [("prefs", None)])
  assert_eq(result.tool_results, [tk_ok_result("searched hit")])
  // The first model call saw [memory, input]; the memory message is frozen
  // into the same transcript the tool wave ran against.
  assert_eq(model.received_messages[0].length(), 2)
  expect_inbound_message(model.received_messages[0][0], ["opening fact"])
}

///|
/// An extension tool named `memory_search` collides with the built-in memory
/// provider at `Agent(...)` composition — fail-fast, no shadowing.
async test "m38_memory/memory_search_collision_at_composition" {
  let tools = RecordingToolProvider(
    [tk_tool_def("memory_search", "extension echo of the core tool")],
    Map::from_array([]),
  )
  let mem = ScriptedMemoryPort(inbounds=[])
  let composition_result = Ok(
    Agent(
      exts=[
        tk_ext(id="model", model=Some(ScriptedModel([]))),
        tk_ext(id="tools", tools=[tools]),
        tk_ext(id="memory", memory=[mem as &@port.MemoryPort]),
        tk_ext(id="io", sessions=[RecordingSessionStore()]),
      ],
      config=tk_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, msg, ..)) => {
      assert_eq(name, "memory_search")
      assert_true(msg.contains("collision"))
    }
    _ => fail("expected ToolCollision for extension 'memory_search'")
  }
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
      tk_ext(id="hook", hooks=[SameLengthAgentHook::{ }]),
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
