///|
struct FixedPromptContributor {
  text : String
}

///|
pub extend FixedPromptContributor with @port.SystemPromptContributor::{
  system_prompt,
}

///|
pub impl @port.SystemPromptContributor for FixedPromptContributor with fn system_prompt(
  self : FixedPromptContributor,
) -> String {
  self.text
}

///|
struct MutablePromptContributor {
  text : Ref[String]
}

///|
pub extend MutablePromptContributor with @port.SystemPromptContributor::{
  system_prompt,
}

///|
pub impl @port.SystemPromptContributor for MutablePromptContributor with fn system_prompt(
  self : MutablePromptContributor,
) -> String {
  self.text.val
}

///|
struct StartSettingLifecycle {
  target : Ref[String]
}

///|
pub extend StartSettingLifecycle with @port.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
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
struct FailingInboundPort {
  _dummy : Unit
}

///|
pub extend FailingInboundPort with @port.MemoryPort::{
  inbound,
  search,
  delete,
  store,
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn inbound(
  _self : FailingInboundPort,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  raise Inbound("always fails for \{session_id} \{request}")
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn store(
  _self : FailingInboundPort,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  raise Store("always fails: \{content} \{metadata.length()}")
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn search(
  _self : FailingInboundPort,
  query~ : String,
  top_k? : Int32,
) -> String? raise @error.MemoryError {
  ignore(top_k)
  raise Search("always fails: \{query}")
}

///|
pub impl @port.MemoryPort for FailingInboundPort with fn delete(
  _self : FailingInboundPort,
  id : String,
) -> Unit raise @error.MemoryError {
  raise Delete("always fails: \{id}")
}

///|
struct SlowInboundPort {
  _dummy : Unit
}

///|
pub extend SlowInboundPort with @port.MemoryPort::{
  inbound,
  search,
  delete,
  store,
}

///|
pub impl @port.MemoryPort for SlowInboundPort with fn inbound(
  _self : SlowInboundPort,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  @async.sleep(200)
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
  top_k? : Int32,
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
fn expect_inbound_message(
  message : @kernel.Message,
  bodies : Array[String],
) -> Unit raise {
  match message {
    UserMessage(content~) =>
      match content {
        [Text(text), ..] =>
          assert_eq(text, MEMORY_INBOUND_LEAD + "\n\n" + bodies.join("\n\n"))
        _ => fail("expected Text content in inbound memory message")
      }
    _ => fail("expected UserMessage inbound memory at this index")
  }
}

///|
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
async fn exec_memory_tool(
  provider : MemoryToolProvider,
  tool : String,
  args : Array[(String, Json)],
) -> @kernel.ToolOutcome {
  let call = tk_memory_call(tool, args)
  let ctx = @port.ToolCallContext(
    effect_id=@kernel.EffectId::first(),
    call_id=call.call_id,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@port.ToolCancellable) { () },
  )
  (provider as &@port.ToolProvider).execute(ctx)
}

///|
fn secondary_failure_errors(
  observer : @test_support.RecordingObserver,
  hook_point : String,
) -> Array[String] raise {
  let out : Array[String] = []
  for e in observer.events() {
    match e {
      Custom(source~, label~, data~) =>
        if source == "posoco.core" && label == "secondary_failure" {
          match data {
            Object(fields) =>
              match fields.get("hook_point") {
                Some(String(hp)) if hp == hook_point =>
                  match fields.get("error") {
                    Some(String(err)) => out.push(err)
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
fn build_memory_agent(
  model : @test_support.ScriptedModel,
  memory : Array[&@port.MemoryPort],
  store : @test_support.RecordingSessionPort,
  observer : @test_support.RecordingObserver,
  system_prompt : String?,
  timeout_ms : Int32?,
) -> Agent raise @error.CompositionError {
  let config : AgentConfig = agent_config(
    max_tool_rounds=Some(10),
    system_prompt~,
    memory_inbound_timeout_ms=timeout_ms,
  )
  Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="memory", memory~),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config~,
  )
}

///|
async test "m38_sysprompt/idempotent_across_rounds" {
  let hook = SystemPromptHook(base_prompt="BASE", contributors=[])
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
  let after2 = hook.before_model(after1)
  assert_true(after2.length() == 1)
  assert_true(physical_equal(after2, after1))
}

///|
async test "m38_sysprompt/replaces_existing_system_message" {
  let hook = SystemPromptHook(base_prompt="NEW", contributors=[])
  let seed : @kernel.Message = SystemMessage(content=[Text("OLD")])
  let user : @kernel.Message = UserMessage(content=[Text("hello")])
  let out = hook.before_model([seed, user])
  assert_true(out.length() == 2)
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
async test "m38_sysprompt/assembles_base_plus_contributors" {
  let c1 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_A",
  }
  let c2 : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "SECTION_B",
  }
  let hook = SystemPromptHook(base_prompt="BASE", contributors=[
    SystemPromptSection(id="a", contributor=c1),
    SystemPromptSection(id="b", contributor=c2),
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
async test "m38_sysprompt/empty_prompt_short_circuits" {
  let empty : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "",
  }
  let hook = SystemPromptHook(base_prompt="", contributors=[
    SystemPromptSection(id="empty", contributor=empty),
  ])
  let user : @kernel.Message = UserMessage(content=[Text("hello")])
  let input = [user]
  let out = hook.before_model(input)
  assert_true(out.length() == 1)
  assert_true(physical_equal(out, input))
}

///|
async test "m38_sysprompt/prepends_when_no_system_message" {
  let hook = SystemPromptHook(base_prompt="BASE", contributors=[])
  let user : @kernel.Message = UserMessage(content=[Text("hello")])
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
async test "m38_sysprompt/config_base_precedes_contributors" {
  let contributor : &@port.SystemPromptContributor = FixedPromptContributor::{
    text: "from_ext",
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="ext", prompt_contributors=[contributor]),
      @test_support.tk_ext(id="io", sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=agent_config(
      max_tool_rounds=Some(10),
      system_prompt=Some("host_base"),
    ),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "session_base"))
  assert_true(model.received_messages.length() == 1)
  let prompt = model.received_messages[0]
  assert_true(prompt.length() >= 1)
  match prompt[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "host_base\n\next:\nfrom_ext")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage at index 0")
  }
}

///|
async test "m38_sysprompt/lazy_assembly_reads_post_on_start" {
  let text_ref = Ref("before_start")
  let contributor = MutablePromptContributor::{ text: text_ref, }
  let starter : &@port.Lifecycle = StartSettingLifecycle::{ target: text_ref, }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="lifecycle", lifecycle=[starter]),
      @test_support.tk_ext(id="ext", prompt_contributors=[
        contributor as &@port.SystemPromptContributor,
      ]),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "session_lazy"))
  assert_true(model.received_messages.length() == 1)
  let prompt = model.received_messages[0]
  match prompt[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "ext:\nafter_start")
        _ => fail("expected Text content")
      }
    _ => fail("expected SystemMessage at index 0")
  }
}

///|
async test "m38_memory/fresh_session_injects_once" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[Some("fact one")])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    @test_support.RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "session_1"))
  assert_eq(mem.call_count(), 1)
  assert_eq(mem.received_sessions(), ["session_1"])
  assert_eq(mem.received_requests(), ["hello"])
  assert_eq(model.received_messages.length(), 1)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 3)
  match prompt[0] {
    SystemMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "SYS")
        _ => fail("expected Text content in system message")
      }
    _ => fail("expected SystemMessage at index 0")
  }
  expect_inbound_message(prompt[1], ["fact one"])
  match prompt[2] {
    UserMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "hello")
        _ => fail("expected Text content in the user input")
      }
    _ => fail("expected the real input at index 2")
  }
}

///|
async test "m38_memory/second_turn_no_reread_prefix_stable" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[Some("fact")])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    @test_support.RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "session_1"))
  ignore(agent.run_turn(@test_support.tk_user_msg("again"), "session_1"))
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
async test "m38_memory/empty_inbound_spends_attempt_per_session" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[
    None,
    Some("second session fact"),
  ])
  let observer = @test_support.RecordingObserver()
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    observer,
    None,
    None,
  )
  let first_turn = agent.run_turn(@test_support.tk_user_msg("q1"), "session_1")
  assert_eq(first_turn.final_session_id, "session_1")
  assert_eq(model.received_messages[0].length(), 1)
  ignore(agent.run_turn(@test_support.tk_user_msg("q2"), "session_1"))
  assert_eq(mem.call_count(), 1)
  assert_eq(model.received_messages[1].length(), 3)
  match model.received_messages[1][0] {
    UserMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "q1")
        _ => fail("expected Text content")
      }
    _ => fail("expected history replay to start with the first input")
  }
  ignore(agent.run_turn(@test_support.tk_user_msg("q3"), "session_2"))
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
async test "m38_memory/resume_skips_read_and_replays_prefix" {
  let model1 = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem1 = @test_support.ScriptedMemoryPort(inbounds=[Some("fact")])
  let store = @test_support.RecordingSessionPort()
  let agent1 = build_memory_agent(
    model1,
    [mem1 as &@port.MemoryPort],
    store,
    @test_support.RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent1.run_turn(@test_support.tk_user_msg("hello"), "session_1"))
  let model2 = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem2 = @test_support.ScriptedMemoryPort(inbounds=[Some("CHANGED")])
  let agent2 = build_memory_agent(
    model2,
    [mem2 as &@port.MemoryPort],
    store,
    @test_support.RecordingObserver(),
    Some("SYS"),
    None,
  )
  ignore(agent2.run_turn(@test_support.tk_user_msg("resume"), "session_1"))
  assert_eq(mem2.call_count(), 0)
  let first = model1.received_messages[0]
  let second = model2.received_messages[0]
  for i in 0..<first.length() {
    assert_eq(second[i], first[i])
  }
  assert_true(second.length() > first.length())
}

///|
async test "m38_memory/preseeded_history_never_injects" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let mem = @test_support.ScriptedMemoryPort(inbounds=[
    Some("must never be read"),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("session_pre", {
    messages: [
      @test_support.tk_user_msg("old question"),
      AssistantMessage(
        content=[Text("old answer")],
        tool_calls=[],
        reasoning=None,
        finish_reason=Stop,
      ),
    ],
    metadata: Map::from_array([]),
  })
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    store,
    @test_support.RecordingObserver(),
    None,
    None,
  )
  ignore(
    agent.run_turn(@test_support.tk_user_msg("new question"), "session_pre"),
  )
  assert_eq(mem.call_count(), 0)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 3)
  match prompt[0] {
    UserMessage(content~) =>
      match content {
        [Text(s), ..] => assert_eq(s, "old question")
        _ => fail("expected Text content")
      }
    _ => fail("expected the seeded history to start unshifted")
  }
}

///|
async test "m38_memory/two_providers_merge_into_one_message" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let notes = @test_support.ScriptedMemoryPort(inbounds=[Some("notes fact")])
  let book = @test_support.ScriptedMemoryPort(inbounds=[Some("book fact")])
  let agent = build_memory_agent(
    model,
    [notes as &@port.MemoryPort, book as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    @test_support.RecordingObserver(),
    None,
    None,
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("query"), "session_1"))
  assert_eq(notes.call_count(), 1)
  assert_eq(book.call_count(), 1)
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 2)
  expect_inbound_message(prompt[0], ["notes fact", "book fact"])
}

///|
async test "m38_memory/failing_provider_does_not_mask_sibling" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let failing : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let ok = @test_support.ScriptedMemoryPort(inbounds=[Some("recovered")])
  let observer = @test_support.RecordingObserver()
  let agent = build_memory_agent(
    model,
    [failing, ok as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    observer,
    None,
    None,
  )
  let result = agent.run_turn(@test_support.tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let prompt = model.received_messages[0]
  assert_eq(prompt.length(), 2)
  expect_inbound_message(prompt[0], ["recovered"])
  let failures = secondary_failure_errors(observer, "memory_inbound")
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("MemoryError::Inbound"))
}

///|
async test "m38_memory/inbound_timeout_emits_secondary_failure" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let slow : &@port.MemoryPort = SlowInboundPort::{ _dummy: (), }
  let observer = @test_support.RecordingObserver()
  let agent = build_memory_agent(
    model,
    [slow],
    @test_support.RecordingSessionPort(),
    observer,
    None,
    Some(1),
  )
  let result = agent.run_turn(@test_support.tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_eq(model.received_messages[0].length(), 1)
  let failures = secondary_failure_errors(observer, "memory_inbound")
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("timeout"))
}

///|
async test "m38_memory/search_merges_sources_in_order" {
  let a = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[
    Some("hit-a"),
  ])
  let b = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[
    Some("hit-b"),
  ])
  let empty = @test_support.ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider(
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
    Success(content~, structured=None) => assert_eq(content, "hit-a\n\nhit-b")
    _ => fail("expected Success outcome for memory_search merge")
  }
  assert_eq(a.received_searches(), [("prefs", None)])
  assert_eq(b.received_searches(), [("prefs", None)])
  assert_eq(empty.received_searches(), [("prefs", None)])
}

///|
async test "m38_memory/search_all_empty_reports_no_match" {
  let a = @test_support.ScriptedMemoryPort(inbounds=[])
  let b = @test_support.ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("anything")),
  ])
  match outcome {
    Success(content~, structured=None) =>
      assert_eq(content, "No matching memory.")
    _ => fail("expected Success outcome for all-empty search")
  }
}

///|
async test "m38_memory/search_failure_skips_source_and_names_it" {
  let bad : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let good = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[
    Some("hit-b"),
  ])
  let reasons : Array[String] = []
  let provider = MemoryToolProvider(
    sources=[("bad", bad), ("good", good as &@port.MemoryPort)],
    on_failure=fn(reason) { reasons.push(reason) },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("prefs")),
  ])
  match outcome {
    Success(content~, structured=None) => assert_eq(content, "hit-b")
    _ => fail("expected the surviving sibling's hit")
  }
  assert_eq(reasons.length(), 1)
  assert_true(reasons[0].contains("bad"))
  assert_true(reasons[0].contains("MemoryError::Search"))
}

///|
async test "m38_memory/search_all_failed_reports_failures_not_miss" {
  let bad : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let reasons : Array[String] = []
  let provider = MemoryToolProvider(sources=[("bad", bad)], on_failure=fn(
    reason,
  ) {
    reasons.push(reason)
  })
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("prefs")),
  ])
  match outcome {
    ToolReportedError(content~, structured=None) => {
      assert_true(content.contains("bad: failed"))
      assert_true(content.contains("MemoryError::Search"))
    }
    _ => fail("expected ToolReportedError when every source failed")
  }
  assert_eq(reasons.length(), 1)
}

///|
async test "m38_memory/search_failure_with_clean_miss_reports_failure" {
  let bad : &@port.MemoryPort = FailingInboundPort::{ _dummy: (), }
  let miss = @test_support.ScriptedMemoryPort(inbounds=[], search_script=[None])
  let provider = MemoryToolProvider(
    sources=[("bad", bad), ("miss", miss as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_search", [
    ("query", Json::string("prefs")),
  ])
  match outcome {
    ToolReportedError(content~, structured=None) => {
      assert_true(content.contains("bad: failed"))
      assert_false(content.contains("miss"))
    }
    _ => fail("expected ToolReportedError for failure + clean miss")
  }
}

///|
async test "m38_memory/add_writes_all_sources_with_receipts" {
  let a = @test_support.ScriptedMemoryPort(inbounds=[])
  let b = @test_support.ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("remember this")),
  ])
  match outcome {
    Success(content~, structured=None) =>
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
async test "m38_memory/add_targeted_source_routes_to_one" {
  let a = @test_support.ScriptedMemoryPort(inbounds=[])
  let b = @test_support.ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", b as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let outcome = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("for b only")),
    ("source", Json::string("b")),
  ])
  match outcome {
    Success(content~, structured=None) => assert_eq(content, "b: scripted-0")
    _ => fail("expected Success outcome for targeted memory_add")
  }
  assert_eq(a.received_stores().length(), 0)
  assert_eq(b.received_stores().length(), 1)
}

///|
async test "m38_memory/add_rejects_unknown_source_and_empty_content" {
  let a = @test_support.ScriptedMemoryPort(inbounds=[])
  let provider = MemoryToolProvider(sources=[("a", a as &@port.MemoryPort)], on_failure=fn(
    _reason,
  ) {
    ()
  })
  let unknown = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("x")),
    ("source", Json::string("zz")),
  ])
  match unknown {
    ToolReportedError(content~, structured=None) => {
      assert_true(content.contains("unknown source 'zz'"))
      assert_true(content.contains("valid sources: a"))
    }
    _ => fail("expected ToolReportedError for unknown source")
  }
  let blank = exec_memory_tool(provider, "memory_add", [
    ("content", Json::string("  ")),
  ])
  match blank {
    ToolReportedError(content~, structured=None) =>
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
async test "m38_memory/e2e_memory_search_tool_reaches_sources" {
  let mem = @test_support.ScriptedMemoryPort(inbounds=[Some("opening fact")], search_script=[
    Some("searched hit"),
  ])
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response(
        "memory_search",
        "call_1",
        Json::object(Map::from_array([("query", Json::string("prefs"))])),
      ),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let agent = build_memory_agent(
    model,
    [mem as &@port.MemoryPort],
    @test_support.RecordingSessionPort(),
    @test_support.RecordingObserver(),
    None,
    None,
  )
  let result = agent.run_turn(@test_support.tk_user_msg("query"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  assert_eq(mem.call_count(), 1)
  assert_eq(mem.received_searches(), [("prefs", None)])
  assert_eq(result.tool_results, [@test_support.tk_ok_result("searched hit")])
  assert_eq(model.received_messages[0].length(), 2)
  expect_inbound_message(model.received_messages[0][0], ["opening fact"])
}

///|
async test "m38_memory/memory_search_collision_at_composition" {
  let tools = @test_support.RecordingToolProvider(
    [
      @test_support.tk_tool_def(
        "memory_search", "extension echo of the core tool",
      ),
    ],
    Map::from_array([]),
  )
  let mem = @test_support.ScriptedMemoryPort(inbounds=[])
  let composition_result = Ok(
    Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(id="tools", tools=[tools]),
        @test_support.tk_ext(id="memory", memory=[mem as &@port.MemoryPort]),
        @test_support.tk_ext(id="io", sessions=[
          @test_support.RecordingSessionPort(),
        ]),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(ToolCollision(name, msg, ..)) => {
      assert_eq(name, "memory_search")
      assert_true(msg.contains("collision"))
    }
    _ => fail("expected ToolCollision for extension 'memory_search'")
  }
}

///|
struct SameLengthAgentHook {}

///|
pub extend SameLengthAgentHook with @port.PipelineHook::{
  tool_exposure,
  on_turn_begin,
  on_post_event,
  before_model,
  before_tool,
  on_turn_end,
}

///|
pub impl @port.PipelineHook for SameLengthAgentHook with fn before_model(
  _self,
  _messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  [UserMessage(content=[Text("rewritten-by-hook")])]
}

///|
async test "m38_hooks/same_length_rewrite_reaches_model" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("ok"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="hook", hooks=[SameLengthAgentHook::{ }]),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(
    @test_support.tk_user_msg("original"),
    "session_rewrite",
  )
  ignore(result)
  assert_eq(model.received_messages.length(), 1)
  let received = model.received_messages[0]
  assert_eq(received.length(), 1)
  match received[0] {
    UserMessage(content~) =>
      match content[0] {
        Text(text) => assert_eq(text, "rewritten-by-hook")
        _ => fail("expected text content")
      }
    _ => fail("expected rewritten user message")
  }
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

///|
fn build_ui_agent(
  ui : @test_support.RecordingUiPort,
  ui_projection : Bool,
) -> Agent raise @error.CompositionError {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("echoed"),
        ),
      ),
    ]),
  )
  Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], ui=[ui], sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    ui_projection~,
  )
}

///|
async test "br5_ui_projection/default_off_renders_nothing" {
  let ui = @test_support.RecordingUiPort()
  let agent = build_ui_agent(ui, false)
  let result = agent.run_turn(@test_support.tk_user_msg("hi"), "session_ui_off")
  assert_eq(result.final_session_id, "session_ui_off")
  assert_eq(ui.render_count(), 0)
}

///|
async test "br5_ui_projection/opt_in_renders_tool_notice" {
  let ui = @test_support.RecordingUiPort()
  let agent = build_ui_agent(ui, true)
  let result = agent.run_turn(@test_support.tk_user_msg("hi"), "session_ui_on")
  assert_eq(result.final_session_id, "session_ui_on")
  assert_true(ui.render_count() > 0)
  let notices = ui.rendered_in_slot(Notice)
  assert_eq(notices.length(), 1)
}
