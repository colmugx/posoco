///|
/// Store whose checkpoints succeed up to `fail_at` and fail exactly once, so a
/// committed-message checkpoint can fail after the shadow already recorded the
/// message but before persistence advanced.
struct CoreShadowCheckpointFailStore {
  mut checkpoints : Int32
  fail_at : Int32
}

///|
impl @port.SessionStore for CoreShadowCheckpointFailStore with fn load(
  _self,
  _id,
) -> @types.Session {
  { messages: [], metadata: Map::from_array([]), }
}

///|
impl @port.SessionStore for CoreShadowCheckpointFailStore with fn save(
  _self,
  _id,
  _session,
) -> Unit {

}

///|
impl @port.SessionStore for CoreShadowCheckpointFailStore with fn checkpoint(
  self,
  _id,
  _checkpoint,
) -> Unit raise @error.SessionError {
  self.checkpoints = self.checkpoints + 1
  if self.checkpoints == self.fail_at {
    raise Save("core shadow test store offline")
  }
}

///|
fn core_shadow_source_snapshot_count(agent : Agent) -> Int32 {
  agent.runtime.core_shadow.store.source_snapshots.length()
}

///|
fn core_shadow_current(
  agent : Agent,
  session_id : String,
) -> @types.Session raise {
  let current = agent.runtime.core_shadow.store.current(session_id) catch {
    _ => fail("expected the shadow core to hold \{session_id}")
  }
  current.session
}

///|
fn assert_core_messages_equal(
  left : Array[@kernel.Message],
  right : Array[@kernel.Message],
) -> Unit raise {
  assert_eq(left.length(), right.length())
  for i in 0..<left.length() {
    assert_true(left[i] == right[i])
  }
}

///|
fn has_secondary_failure(
  events : Array[@types.TurnEvent],
  hook_point : String,
) -> Bool {
  for event in events {
    match event {
      Custom(source="posoco.core", label="secondary_failure", data~) =>
        match data {
          Object(fields) =>
            match fields.get("hook_point") {
              Some(String(value)) if value == hook_point => return true
              _ => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
fn shadow_is_complete(agent : Agent, session_id : String) -> Bool {
  match agent.runtime.core_shadow.state.get(session_id) {
    Some(Complete) => true
    _ => false
  }
}

///|
async test "core_shadow/no_store_records_committed_messages" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("probe", "tc-shadow", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let provider = RecordingToolProvider(
    [tk_tool_def("probe", "")],
    Map::from_array([
      ("probe", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[provider]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "shadow-nostore"))
  let core = core_shadow_current(agent, "shadow-nostore")
  assert_eq(core.messages.length(), 4)
  assert_true(core.messages[0] == tk_user_msg("hello"))
  guard core.messages[1] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the assistant tool call")
  }
  assert_eq(call.name.to_string(), "probe")
  guard core.messages[2] is ToolMessage(outcome=Success(content="ok", ..), ..) else {
    fail("expected the committed tool result")
  }
  guard core.messages[3] is AssistantMessage(content=[Text("done")], ..) else {
    fail("expected the terminal assistant message")
  }
  assert_true(shadow_is_complete(agent, "shadow-nostore"))
}

///|
async test "core_shadow/new_session_with_store_matches_persisted" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("probe", "tc-shadow", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_stop_response("again")),
  ])
  let provider = RecordingToolProvider(
    [tk_tool_def("probe", "")],
    Map::from_array([
      ("probe", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[provider]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "shadow-store"))
  let core = core_shadow_current(agent, "shadow-store")
  let persisted = store.load("shadow-store") catch {
    _ => fail("expected the persisted session")
  }
  assert_eq(core.messages.length(), 4)
  assert_core_messages_equal(core.messages, persisted.messages)
  // A second successful operation rehydrates from the persisted transcript
  // and continues the same shadow lineage instead of stopping on a false
  // conflict.
  ignore(agent.run_turn(tk_user_msg("next"), "shadow-store"))
  let after = core_shadow_current(agent, "shadow-store")
  let persisted_after = store.load("shadow-store") catch {
    _ => fail("expected the persisted session after the second turn")
  }
  assert_eq(after.messages.length(), 6)
  assert_core_messages_equal(after.messages, persisted_after.messages)
  assert_true(shadow_is_complete(agent, "shadow-store"))
}

///|
async test "core_shadow/hydrates_existing_store_before_new_boundaries" {
  let store = RecordingSessionStore()
  store.seed("shadow-seeded", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([("seed", Json::string("kept"))]),
  })
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("new"), "shadow-seeded"))
  let core = core_shadow_current(agent, "shadow-seeded")
  assert_eq(core.messages.length(), 3)
  assert_true(core.messages[0] == tk_user_msg("old"))
  assert_true(core.messages[1] == tk_user_msg("new"))
  guard core.messages[2] is AssistantMessage(content=[Text("done")], ..) else {
    fail("expected the terminal assistant message")
  }
  assert_eq(core.metadata["seed"], Json::string("kept"))
}

///|
async test "core_shadow/store_failure_keeps_recorded_core" {
  let store = CoreShadowCheckpointFailStore::{ checkpoints: 0, fail_at: 2, }
  let observer = RecordingObserver()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("probe", "tc-shadow", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_stop_response("next")),
  ])
  let provider = RecordingToolProvider(
    [tk_tool_def("probe", "")],
    Map::from_array([
      ("probe", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[provider]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hello"), "shadow-fail"),
  ) catch {
    error => Err(error)
  }
  match first {
    Err(_) => ()
    Ok(_) => fail("expected the committed checkpoint to fail the turn")
  }
  let core = core_shadow_current(agent, "shadow-fail")
  assert_eq(core.messages.length(), 2)
  assert_true(core.messages[0] == tk_user_msg("hello"))
  guard core.messages[1] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the committed assistant message before store I/O")
  }
  assert_eq(call.name.to_string(), "probe")
  // The store still loads an empty (stale) session. The next operation must
  // not overwrite the leading core: production proceeds, shadow stops, and a
  // diagnostic is emitted.
  ignore(agent.run_turn(tk_user_msg("next"), "shadow-fail"))
  let after = core_shadow_current(agent, "shadow-fail")
  assert_eq(after.messages.length(), 2)
  assert_true(after.messages[0] == tk_user_msg("hello"))
  assert_true(after.messages[1] == core.messages[1])
  assert_false(agent.runtime.core_shadow.is_tracked("shadow-fail"))
  match agent.runtime.core_shadow.state.get("shadow-fail") {
    Some(Stopped(reason~, ..)) => assert_eq(reason, "admission_conflict")
    _ => fail("expected the stale admission conflict to stay stopped")
  }
  assert_true(has_secondary_failure(observer.events(), "core_shadow_admit"))
}

///|
/// Model that returns a tool call first, blocks on selected `gate_calls`, then
/// stops. `compact` answers with `compacted` and the configured mode.
struct ShadowGatedTurnModel {
  gate_calls : Array[Int32]
  mut calls : Int32
  mut entered : Bool
  mut released : Bool
  compacted : Array[@kernel.Message]
  compact_mode : @kernel.CompactMode
}

///|
impl @port.ModelPort for ShadowGatedTurnModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  if self.gate_calls.contains(self.calls) {
    self.entered = true
    while !self.released {
      @async.pause()
    }
  }
  if self.calls == 1 {
    return tk_tool_call_response("leaf", "call_1", Json::null())
  }
  if self.calls == 2 {
    return tk_tool_call_response("leaf", "call_2", Json::null())
  }
  tk_stop_response("done")
}

///|
impl @port.ModelPort for ShadowGatedTurnModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  { compacted_messages: self.compacted.copy(), mode: self.compact_mode, }
}

///|
impl @port.ModelPort for ShadowGatedTurnModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async fn shadow_invoke_command(
  agent : Agent,
  command_id : String,
  args : Json,
) -> Bool {
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == command_id {
        guard port.invoke(command_id, args) is Success(..) else { return false }
        return true
      }
    }
  }
  false
}

///|
fn shadow_redirects(
  events : Array[@types.TurnEvent],
) -> Array[(String, String, Int32, Int32)] {
  let found : Array[(String, String, Int32, Int32)] = []
  for event in events {
    match event {
      SessionRedirect(from~, to~, messages_before~, messages_after~) =>
        found.push((from, to, messages_before, messages_after))
      _ => ()
    }
  }
  found
}

///|
fn shadow_source_of(agent : Agent, session_id : String) -> CoreSource raise {
  guard agent.runtime.core_shadow.store.sessions[session_id].versions[0].source
    is Some(source) else {
    fail("expected \{session_id} to carry a core source")
  }
  source
}

///|
fn shadow_resolve_source(
  agent : Agent,
  source : CoreSource,
) -> @types.Session raise {
  agent.runtime.core_shadow.store.resolve_source(source) catch {
    _ => fail("expected the source to resolve")
  }
}

///|
async test "core_shadow/fork_pins_safe_point_source_after_assistant_commit" {
  let model = ShadowGatedTurnModel::{
    gate_calls: [1],
    calls: 0,
    entered: false,
    released: false,
    compacted: [],
    compact_mode: NewThread,
  }
  let store = RecordingSessionStore()
  store.seed("fork-parent", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let turn = @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      agent.run_turn(tk_user_msg("go"), "fork-parent")
    })
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        shadow_invoke_command(
          agent,
          "fork-here",
          Json::object(Map::from_array([("index", Json::number(3.0))])),
        )
      }),
    ) catch {
      error => Err(error)
    }
    guard enqueued is Ok(true) else {
      fail("fork enqueue failed: \{repr(enqueued)}")
    }
    running.wait()
  })
  assert_eq(turn.final_session_id, "fork-parent")
  let redirects = shadow_redirects(observer.events())
  assert_eq(redirects.length(), 1)
  let child_sid = redirects[0].1
  // The parent shadow stops after fork; the child owns the pinned source.
  assert_false(agent.runtime.core_shadow.is_tracked("fork-parent"))
  assert_true(shadow_is_complete(agent, child_sid))
  let parent_core = core_shadow_current(agent, "fork-parent")
  assert_eq(parent_core.messages.length(), 4)
  guard parent_core.messages[3] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the safe-point assistant tool call")
  }
  assert_eq(call.call_id.to_string(), "call_1")
  let child_core = core_shadow_current(agent, child_sid)
  assert_eq(child_core.messages.length(), 3)
  assert_true(child_core.messages[0] == tk_user_msg("old-one"))
  assert_true(child_core.messages[1] == tk_user_msg("old-two"))
  assert_true(child_core.messages[2] == tk_user_msg("go"))
  assert_eq(
    child_core.metadata[@types.PARENT_THREAD_ID_KEY],
    Json::string("fork-parent"),
  )
  let source = shadow_source_of(agent, child_sid)
  assert_eq(source.sid, "fork-parent")
  assert_eq(source.prefix, 3)
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 3)
  assert_true(resolved.messages[2] == tk_user_msg("go"))
  // The pinned version is the full safe-point transcript (including the
  // assistant committed after admission); the child body trims it to the
  // requested prefix.
  let full_source = agent.runtime.core_shadow.store.materialize(
    source.sid,
    source.version,
  ) catch {
    _ => fail("expected the parent source version to materialize")
  }
  assert_eq(full_source.messages.length(), 4)
  guard full_source.messages[3] is AssistantMessage(tool_calls=[call], ..) else {
    fail(
      "expected the source version to include the committed assistant tool call",
    )
  }
  assert_eq(call.call_id.to_string(), "call_1")
  // A later parent rewrite cannot retarget the child's source.
  ignore(
    agent.runtime.core_shadow.store.rewrite(
      "fork-parent",
      [tk_user_msg("parent-rewritten")],
      Map::from_array([]),
    ),
  )
  let after_rewrite = shadow_resolve_source(agent, source)
  assert_eq(after_rewrite.messages.length(), 3)
  assert_true(after_rewrite.messages[2] == tk_user_msg("go"))
  let full_after = agent.runtime.core_shadow.store.materialize(
    source.sid,
    source.version,
  ) catch {
    _ =>
      fail("expected the pinned source version to survive the parent rewrite")
  }
  assert_eq(full_after.messages.length(), 4)
  guard full_after.messages[3] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the pinned source version to survive the parent rewrite")
  }
  assert_eq(call.call_id.to_string(), "call_1")
}

///|
async test "core_shadow/midturn_newthread_source_includes_tool_and_assistant" {
  let model = ShadowGatedTurnModel::{
    gate_calls: [2],
    calls: 0,
    entered: false,
    released: false,
    compacted: [tk_user_msg("mid-turn summary")],
    compact_mode: NewThread,
  }
  let store = RecordingSessionStore()
  store.seed("mid-parent", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let turn = @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      agent.run_turn(tk_user_msg("go"), "mid-parent")
    })
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        shadow_invoke_command(agent, "compact", Json::null())
      }),
    ) catch {
      error => Err(error)
    }
    guard enqueued is Ok(true) else {
      fail("mid-turn compact enqueue failed: \{repr(enqueued)}")
    }
    running.wait()
  })
  let child_sid = turn.final_session_id
  assert_true(child_sid.has_prefix("mid-parent_compact_"))
  assert_false(agent.runtime.core_shadow.is_tracked("mid-parent"))
  assert_true(shadow_is_complete(agent, child_sid))
  let parent_core = core_shadow_current(agent, "mid-parent")
  assert_eq(parent_core.messages.length(), 6)
  guard parent_core.messages[4]
    is ToolMessage(outcome=Success(content="ok", ..), ..) else {
    fail("expected the safe-point tool result")
  }
  guard parent_core.messages[5] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the safe-point second assistant tool call")
  }
  assert_eq(call.call_id.to_string(), "call_2")
  let child_core = core_shadow_current(agent, child_sid)
  assert_eq(child_core.messages.length(), 1)
  assert_true(child_core.messages[0] == tk_user_msg("mid-turn summary"))
  assert_eq(
    child_core.metadata[@types.PARENT_THREAD_ID_KEY],
    Json::string("mid-parent"),
  )
  let source = shadow_source_of(agent, child_sid)
  assert_eq(source.sid, "mid-parent")
  assert_eq(source.prefix, 6)
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 6)
  assert_true(resolved.messages[5] == parent_core.messages[5])
  guard resolved.messages[4]
    is ToolMessage(outcome=Success(content="ok", ..), ..) else {
    fail("expected the source to include the committed tool result")
  }
}

///|
async test "core_shadow/idle_newthread_source_and_summary_stay_separate" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("child done")),
  ])
  let store = RecordingSessionStore()
  store.seed("idle-parent", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("idle-parent")
  let child_sid = outcome.final_session_id
  assert_false(agent.runtime.core_shadow.is_tracked("idle-parent"))
  let parent_core = core_shadow_current(agent, "idle-parent")
  assert_eq(parent_core.messages.length(), 2)
  assert_true(parent_core.messages[0] == tk_user_msg("old-one"))
  let child_core = core_shadow_current(agent, child_sid)
  assert_eq(child_core.messages.length(), 1)
  assert_true(child_core.messages[0] == tk_user_msg("summary"))
  let source = shadow_source_of(agent, child_sid)
  assert_eq(source.sid, "idle-parent")
  assert_eq(source.prefix, 2)
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 2)
  assert_true(resolved.messages[0] == tk_user_msg("old-one"))
  assert_true(resolved.messages[1] == tk_user_msg("old-two"))
  // A later child turn terminal-rewrites the child body but must retain the
  // source captured at creation.
  ignore(agent.run_turn(tk_user_msg("child-turn"), child_sid))
  let after_child = core_shadow_current(agent, child_sid)
  assert_eq(after_child.messages.length(), 3)
  assert_true(after_child.messages[0] == tk_user_msg("summary"))
  let versions = agent.runtime.core_shadow.store.sessions[child_sid].versions
  guard versions[versions.length() - 1].source is Some(latest_source) else {
    fail("expected the child rewrite to retain its creation source")
  }
  assert_eq(latest_source.sid, "idle-parent")
  assert_eq(latest_source.prefix, 2)
  assert_true(shadow_is_complete(agent, child_sid))
}

///|
async test "core_shadow/replace_compact_mirrors_terminal_without_child" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("replacement")],
      mode: Replace,
    }),
  ])
  let store = RecordingSessionStore()
  store.seed("replace-parent", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("replace-parent")
  assert_eq(outcome.final_session_id, "replace-parent")
  assert_false(agent.runtime.core_shadow.is_tracked("replace-parent"))
  assert_true(shadow_is_complete(agent, "replace-parent"))
  let core = core_shadow_current(agent, "replace-parent")
  assert_eq(core.messages.length(), 1)
  assert_true(core.messages[0] == tk_user_msg("replacement"))
  assert_eq(agent.runtime.core_shadow.store.sessions.length(), 1)
}

///|
/// Standalone-compact model that mutates the supplied message content before
/// returning. The shadow source must already be a deep copy.
struct ShadowMutatingCompactModel {}

///|
impl @port.ModelPort for ShadowMutatingCompactModel with fn chat(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  tk_stop_response("unused")
}

///|
impl @port.ModelPort for ShadowMutatingCompactModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  match messages[0] {
    UserMessage(content~) => content.push(Text("model-poison"))
    _ => ()
  }
  { compacted_messages: [tk_user_msg("summary")], mode: NewThread, }
}

///|
impl @port.ModelPort for ShadowMutatingCompactModel with fn provider_config(
  _self,
) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async test "core_shadow/compact_source_frozen_before_model_mutation" {
  let model = ShadowMutatingCompactModel::{ }
  let store = RecordingSessionStore()
  store.seed("frozen-parent", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("frozen-parent")
  let source = shadow_source_of(agent, outcome.final_session_id)
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 1)
  guard resolved.messages[0] is UserMessage(content~) else {
    fail("expected the source user message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected source text") }
  assert_eq(text, "old")
}

///|
/// Hook that rewrites the transcript before every model call.
struct ShadowRewriteHook {}

///|
impl @port.PipelineHook for ShadowRewriteHook with fn before_model(
  _self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let out : Array[@kernel.Message] = [
    SystemMessage(content=[Text("rewritten")]),
  ]
  for message in messages {
    out.push(message)
  }
  out
}

///|
async test "core_shadow/hook_rewrite_mirrors_terminal_transcript" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore()
  let hook = ShadowRewriteHook::{ }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], hooks=[hook]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "hook-parent"))
  let core = core_shadow_current(agent, "hook-parent")
  let persisted = store.load("hook-parent") catch {
    _ => fail("expected the rewritten session to persist")
  }
  assert_core_messages_equal(core.messages, persisted.messages)
  assert_true(session_metadata_equal(core.metadata, persisted.metadata))
  guard core.messages[0] is SystemMessage(content=[Text("rewritten")]) else {
    fail("expected the rewritten system message at the terminal")
  }
  guard core.messages[core.messages.length() - 1]
    is AssistantMessage(content=[Text("done")], ..) else {
    fail("expected the terminal assistant message")
  }
  assert_true(shadow_is_complete(agent, "hook-parent"))
  assert_false(agent.runtime.core_shadow.is_tracked("hook-parent"))
}

///|
async test "core_shadow/terminal_mirror_survives_store_save_failure" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("replacement")],
      mode: Replace,
    }),
  ])
  let store = RecordingSessionStore()
  store.seed("save-fail", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  store.fail_save("save-fail")
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("save-fail"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(_) => ()
    Ok(_) => fail("expected the output save to fail")
  }
  let core = core_shadow_current(agent, "save-fail")
  assert_eq(core.messages.length(), 1)
  assert_true(core.messages[0] == tk_user_msg("replacement"))
  assert_true(shadow_is_complete(agent, "save-fail"))
  let persisted = store.load("save-fail") catch {
    _ => fail("expected the old persisted body")
  }
  assert_eq(persisted.messages.length(), 2)
  assert_true(persisted.messages[0] == tk_user_msg("old-one"))
}

///|
async test "core_shadow/hook_rewrite_fork_pins_committed_source" {
  let model = ShadowGatedTurnModel::{
    gate_calls: [1],
    calls: 0,
    entered: false,
    released: false,
    compacted: [],
    compact_mode: NewThread,
  }
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let hook = ShadowRewriteHook::{ }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer], hooks=[hook]),
    ],
    config=tk_config(),
  )
  let fork_turn = @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      agent.run_turn(tk_user_msg("go"), "hook-fork-parent")
    })
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        shadow_invoke_command(
          agent,
          "fork-here",
          Json::object(Map::from_array([("index", Json::number(1.0))])),
        )
      }),
    ) catch {
      error => Err(error)
    }
    guard enqueued is Ok(true) else {
      fail("fork enqueue failed: \{repr(enqueued)}")
    }
    running.wait()
  })
  assert_eq(fork_turn.final_session_id, "hook-fork-parent")
  let redirects = shadow_redirects(observer.events())
  assert_eq(redirects.length(), 1)
  let child_sid = redirects[0].1
  assert_true(agent.runtime.core_shadow.store.sessions.contains(child_sid))
  assert_true(shadow_is_complete(agent, child_sid))
  let source = shadow_source_of(agent, child_sid)
  assert_eq(source.sid, "hook-fork-parent")
  assert_eq(source.prefix, 1)
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 1)
  guard resolved.messages[0] is SystemMessage(content=[Text("rewritten")]) else {
    fail("expected the hook-rewritten safe-point prefix")
  }
  // A child turn keeps the creation source while the terminal boundary is
  // captured synchronously.
  ignore(agent.run_turn(tk_user_msg("child"), child_sid))
  let versions = agent.runtime.core_shadow.store.sessions[child_sid].versions
  guard versions[versions.length() - 1].source is Some(latest_source) else {
    fail("expected the child rewrite to retain its creation source")
  }
  assert_eq(latest_source.sid, "hook-fork-parent")
  assert_eq(latest_source.prefix, 1)
}

///|
async test "core_shadow/h1_admission_conflict_not_revived_by_rewrite" {
  let store = CoreShadowCheckpointFailStore::{ checkpoints: 0, fail_at: 2, }
  let observer = RecordingObserver()
  let model = ShadowGatedTurnModel::{
    gate_calls: [2],
    calls: 0,
    entered: false,
    released: false,
    compacted: [tk_user_msg("replacement")],
    compact_mode: Replace,
  }
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hello"), "h1-conflict"),
  ) catch {
    error => Err(error)
  }
  match first {
    Err(_) => ()
    Ok(_) => fail("expected the first store checkpoint to fail")
  }
  let before = core_shadow_current(agent, "h1-conflict")
  assert_eq(before.messages.length(), 2)
  assert_true(before.messages[0] == tk_user_msg("hello"))
  // The stale store reloads empty, so admission conflicts. A Replace rewrite
  // and terminal success must not revive/overwrite the leading core.
  let second = @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      agent.run_turn(tk_user_msg("next"), "h1-conflict")
    })
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        shadow_invoke_command(agent, "compact", Json::null())
      }),
    ) catch {
      error => Err(error)
    }
    guard enqueued is Ok(true) else {
      fail("compact enqueue failed: \{repr(enqueued)}")
    }
    running.wait()
  })
  ignore(second)
  let after = core_shadow_current(agent, "h1-conflict")
  assert_eq(after.messages.length(), 2)
  assert_true(after.messages[0] == tk_user_msg("hello"))
  assert_true(after.messages[1] == before.messages[1])
  match agent.runtime.core_shadow.state.get("h1-conflict") {
    Some(Stopped(reason~, ..)) => assert_eq(reason, "admission_conflict")
    _ => fail("expected the admission conflict to stay Stopped")
  }
}

///|
test "core_shadow/h2_missing_provenance_not_revived_by_rewrite" {
  let shadow = CoreShadowRecording::CoreShadowRecording()
  shadow.mark_missing_provenance("missing-child")
  shadow.record_boundary("run-1", "missing-child", 1, "sp-1", false, [
    tk_user_msg("rewritten"),
  ])
  match
    shadow.record_terminal(
      "missing-child",
      "run-1",
      [tk_user_msg("terminal")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(_) => ()
  }
  assert_false(shadow.store.sessions.contains("missing-child"))
  match shadow.state.get("missing-child") {
    Some(MissingProvenance) => ()
    _ => fail("expected missing provenance to survive the rewrite")
  }
}

///|
test "core_shadow/late_run_terminal_is_rejected" {
  let shadow = CoreShadowRecording::CoreShadowRecording()
  match
    shadow.hydrate("late-parent", [tk_user_msg("old")], Map::from_array([])) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "late-parent",
      [tk_user_msg("old")],
      Map::from_array([]),
      [tk_user_msg("old")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  let late = shadow.record_terminal(
    "late-parent",
    "run-2",
    [tk_user_msg("late")],
    Map::from_array([]),
  )
  match late {
    Err(_) => ()
    Ok(_) => fail("expected a late run terminal to be rejected")
  }
  let current = shadow.store.current("late-parent") catch {
    _ => fail("expected the original core body")
  }
  assert_true(current.session.messages[0] == tk_user_msg("old"))
  match shadow.state.get("late-parent") {
    Some(Tracking(run_id~)) => assert_eq(run_id, "run-1")
    _ => fail("expected the original run to remain tracking")
  }
  shadow.record_boundary("run-1", "late-parent", 1, "sp-1", true, [
    tk_user_msg("done"),
  ])
  match
    shadow.record_terminal(
      "late-parent",
      "run-1",
      [tk_user_msg("done")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  let done = shadow.store.current("late-parent") catch {
    _ => fail("expected the terminal core body")
  }
  assert_true(done.session.messages[0] == tk_user_msg("done"))
  match shadow.store.sessions["late-parent"].versions[2].body {
    Append(tail~) => assert_eq(tail.length(), 0)
    Full(..) => fail("terminal metadata update must not create a Full body")
  }
}

///|
async test "core_shadow/dispatch_failure_keeps_synced_hook_rewrite_boundary" {
  let store = CoreShadowCheckpointFailStore::{ checkpoints: 0, fail_at: 2, }
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let hook = ShadowRewriteHook::{ }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], hooks=[hook]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hello"), "synced-dispatch-fail"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(_) => ()
    Ok(_) => fail("expected the subscriber checkpoint to fail")
  }
  let core = core_shadow_current(agent, "synced-dispatch-fail")
  assert_eq(core.messages.length(), 3)
  guard core.messages[0] is SystemMessage(content=[Text("rewritten")]) else {
    fail("expected the committed hook rewrite at the first message")
  }
  assert_true(core.messages[1] == tk_user_msg("hello"))
  guard core.messages[2] is AssistantMessage(content=[Text("done")], ..) else {
    fail("expected the committed assistant before subscriber dispatch")
  }
}

///|
async test "core_shadow/cancelled_terminal_is_synced" {
  let model = ShadowGatedTurnModel::{
    gate_calls: [1],
    calls: 0,
    entered: false,
    released: false,
    compacted: [],
    compact_mode: NewThread,
  }
  let store = RecordingSessionStore()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let running = group.spawn(async fn() {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(tk_user_msg("abort me"), "synced-cancel"),
      ) catch {
        error => Err(error)
      }
      outcome.val = r
    })
    while !model.entered {
      @async.pause()
    }
    ignore(agent.control().abort_active(Some("stop")))
    model.released = true
    ignore(running.wait())
  })
  guard outcome.val is Err(@error.AgentError::Cancelled(_)) else {
    fail("expected structured Cancelled, got \{repr(outcome.val)}")
  }
  let core = core_shadow_current(agent, "synced-cancel")
  assert_true(core.messages.length() >= 2)
  assert_true(core.messages[0] == tk_user_msg("abort me"))
  guard core.messages[1] is AssistantMessage(tool_calls=[call], ..) else {
    fail("expected the committed assistant before cancellation")
  }
  assert_eq(call.call_id.to_string(), "call_1")
  let terminal = match agent.runtime.puppet.last_completed_transcript() {
    Some(transcript) => transcript.messages_snapshot()
    None => fail("expected the cancelled run to expose its terminal transcript")
  }
  assert_core_messages_equal(core.messages, terminal)
  assert_true(shadow_is_complete(agent, "synced-cancel"))
}

///|
async test "core_shadow/failed_terminal_is_synced" {
  let model = ScriptedModel([Fail(Transport("network down"))])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("fail"), "synced-failed-terminal"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(_) => ()
    Ok(_) => fail("expected the model failure")
  }
  let core = core_shadow_current(agent, "synced-failed-terminal")
  assert_eq(core.messages.length(), 1)
  assert_true(core.messages[0] == tk_user_msg("fail"))
  assert_true(shadow_is_complete(agent, "synced-failed-terminal"))
}

///|
test "core_shadow/duplicate_boundary_is_ignored" {
  let shadow = CoreShadowRecording::CoreShadowRecording()
  match
    shadow.hydrate(
      "boundary-parent",
      [tk_user_msg("seed")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "boundary-parent",
      [tk_user_msg("seed")],
      Map::from_array([]),
      [tk_user_msg("seed")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  shadow.record_boundary("run-1", "boundary-parent", 1, "sp-1", false, [
    tk_user_msg("seed"),
    tk_user_msg("one"),
  ])
  let first = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the first committed boundary")
  }
  assert_eq(first.version, 1)
  match shadow.store.sessions["boundary-parent"].versions[1].body {
    Append(..) => ()
    Full(..) => fail("prefix growth must use Append, not Full")
  }
  shadow.record_boundary("run-1", "boundary-parent", 1, "sp-1", false, [
    tk_user_msg("seed"),
    tk_user_msg("poison"),
  ])
  let duplicate = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the duplicate boundary")
  }
  assert_eq(duplicate.version, 1)
  assert_true(duplicate.session.messages[1] == tk_user_msg("one"))
  shadow.record_boundary("run-1", "boundary-parent", 2, "sp-2", true, [
    tk_user_msg("seed"),
    tk_user_msg("one"),
    tk_user_msg("two"),
  ])
  let terminal = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the terminal boundary")
  }
  assert_eq(terminal.version, 2)
  assert_eq(terminal.session.messages.length(), 3)
  assert_true(shadow_is_state_complete(shadow, "boundary-parent"))
}

///|
fn shadow_is_state_complete(
  shadow : CoreShadowRecording,
  session_id : String,
) -> Bool {
  match shadow.state.get(session_id) {
    Some(Complete) => true
    _ => false
  }
}

///|
async test "core_shadow/standalone_newthread_source_keeps_fixated_tool" {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("dangling-call"),
    name: @kernel.ToolName::unchecked("leaf"),
    arguments: Json::null(),
  }
  let dangling : @kernel.Message = AssistantMessage(
    content=[Text("working")],
    tool_calls=[call],
    reasoning=None,
    finish_reason=ToolCalls,
  )
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("after compact")),
  ])
  let store = RecordingSessionStore()
  store.seed("fixate-parent", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("fixate-parent")
  let child_sid = outcome.final_session_id
  let source = shadow_source_of(agent, child_sid)
  assert_eq(source.sid, "fixate-parent")
  assert_eq(source.prefix, 2)
  assert_true(
    source.version < 0,
    msg="fixated source must be a detached snapshot",
  )
  let resolved = shadow_resolve_source(agent, source)
  assert_eq(resolved.messages.length(), 2)
  guard resolved.messages[1]
    is ToolMessage(outcome=RuntimeFailure(error_category="Interrupted", ..), ..) else {
    fail("expected the fixated interrupted tool result in the source")
  }
  let child = core_shadow_current(agent, child_sid)
  assert_eq(child.messages.length(), 1)
  assert_true(child.messages[0] == tk_user_msg("summary"))
  assert_eq(core_shadow_source_snapshot_count(agent), 1)
  // The source snapshot must not become the parent's current committed fact.
  let parent = core_shadow_current(agent, "fixate-parent")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
  let head = agent.runtime.core_shadow.store.current("fixate-parent") catch {
    _ => fail("expected the parent head")
  }
  assert_eq(head.version, 0)
  assert_eq(
    agent.runtime.core_shadow.store.sessions["fixate-parent"].versions.length(),
    1,
  )
  // The next real turn can continue from the raw parent body.
  ignore(agent.run_turn(tk_user_msg("next"), "fixate-parent"))
  let after = core_shadow_current(agent, "fixate-parent")
  assert_true(after.messages[0] == dangling)
  assert_true(after.messages.length() >= 2)
}

///|
test "core_shadow/terminal_body_mismatch_is_rejected_without_overwrite" {
  let shadow = CoreShadowRecording::CoreShadowRecording()
  match
    shadow.hydrate(
      "terminal-mismatch",
      [tk_user_msg("seed")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "terminal-mismatch",
      [tk_user_msg("seed")],
      Map::from_array([]),
      [tk_user_msg("seed")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  shadow.record_boundary("run-1", "terminal-mismatch", 1, "sp-1", true, [
    tk_user_msg("seed"),
    tk_user_msg("committed"),
  ])
  match
    shadow.record_terminal(
      "terminal-mismatch",
      "run-1",
      [tk_user_msg("forged")],
      Map::from_array([]),
    ) {
    Err(_) => ()
    Ok(_) => fail("expected the mismatched terminal body to be rejected")
  }
  let current = shadow.store.current("terminal-mismatch") catch {
    _ => fail("expected the committed body")
  }
  assert_eq(current.session.messages.length(), 2)
  assert_true(current.session.messages[1] == tk_user_msg("committed"))
  match shadow.state.get("terminal-mismatch") {
    Some(Stopped(reason~, ..)) => assert_eq(reason, "terminal_body_mismatch")
    _ => fail("expected the mismatch to stop shadow completion")
  }
}

///|
async test "core_shadow/standalone_newthread_model_failure_keeps_parent_current" {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("dangling-call"),
    name: @kernel.ToolName::unchecked("leaf"),
    arguments: Json::null(),
  }
  let dangling : @kernel.Message = AssistantMessage(
    content=[Text("working")],
    tool_calls=[call],
    reasoning=None,
    finish_reason=ToolCalls,
  )
  let model = ScriptedModel([
    CompactFail(error=Transport("compact failed")),
    Respond(tk_stop_response("after compact")),
  ])
  let store = RecordingSessionStore()
  store.seed("fixate-fail-parent", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let failed : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("fixate-fail-parent"),
  ) catch {
    error => Err(error)
  }
  match failed {
    Err(_) => ()
    Ok(_) => fail("expected the compact model failure")
  }
  let parent = core_shadow_current(agent, "fixate-fail-parent")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
  assert_eq(
    agent.runtime.core_shadow.store.sessions["fixate-fail-parent"].versions.length(),
    1,
  )
  ignore(agent.run_turn(tk_user_msg("next"), "fixate-fail-parent"))
  let after = core_shadow_current(agent, "fixate-fail-parent")
  assert_true(after.messages[0] == dangling)
  assert_true(after.messages.length() >= 2)
}

///|
struct ShadowParkingCompactModel {
  mut entered : Bool
}

///|
impl @port.ModelPort for ShadowParkingCompactModel with fn chat(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  tk_stop_response("after cancel")
}

///|
impl @port.ModelPort for ShadowParkingCompactModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.entered = true
  for ;; {
    @async.pause()
  }
}

///|
impl @port.ModelPort for ShadowParkingCompactModel with fn provider_config(
  _self,
) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async test "core_shadow/standalone_newthread_cancel_keeps_parent_current" {
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("dangling-call"),
    name: @kernel.ToolName::unchecked("leaf"),
    arguments: Json::null(),
  }
  let dangling : @kernel.Message = AssistantMessage(
    content=[Text("working")],
    tool_calls=[call],
    reasoning=None,
    finish_reason=ToolCalls,
  )
  let model = ShadowParkingCompactModel::{ entered: false, }
  let store = RecordingSessionStore()
  store.seed("fixate-cancel-parent", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let outcome : Ref[Result[@types.CompactOutcome, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let running = group.spawn(async fn() {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("fixate-cancel-parent"),
      ) catch {
        error => Err(error)
      }
      outcome.val = r
    })
    while !model.entered {
      @async.pause()
    }
    running.cancel()
    let waited : Result[Unit, Error] = Ok(running.wait()) catch {
      _ => Err(Error::Failure("cancelled"))
    }
    ignore(waited)
  })
  match outcome.val {
    Err(@error.AgentError::Cancelled(_)) => ()
    _ => fail("expected the compact to be cancelled")
  }
  let parent = core_shadow_current(agent, "fixate-cancel-parent")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
  assert_eq(
    agent.runtime.core_shadow.store.sessions["fixate-cancel-parent"].versions.length(),
    1,
  )
  ignore(agent.run_turn(tk_user_msg("next"), "fixate-cancel-parent"))
  let after = core_shadow_current(agent, "fixate-cancel-parent")
  assert_true(after.messages[0] == dangling)
  assert_true(after.messages.length() >= 2)
}

///|
async test "core_shadow/missing_provenance_survives_real_next_turn" {
  let store = CoreShadowCheckpointFailStore::{ checkpoints: 0, fail_at: 2, }
  let observer = RecordingObserver()
  let model = ShadowGatedTurnModel::{
    gate_calls: [2],
    calls: 0,
    entered: false,
    released: false,
    compacted: [],
    compact_mode: NewThread,
  }
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hello"), "missing-real-parent"),
  ) catch {
    error => Err(error)
  }
  match first {
    Err(_) => ()
    Ok(_) => fail("expected the first store checkpoint to fail")
  }
  let fork_turn : Result[@types.TurnResult, @error.AgentError] = @async.with_task_group(async fn(
      group,
    ) {
      let turn_body : async () -> Result[@types.TurnResult, @error.AgentError] = () => {
        let r : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(tk_user_msg("fork"), "missing-real-parent"),
        ) catch {
          error => Err(error)
        }
        r
      }
      let running = group.spawn(turn_body)
      let enqueued : Result[Bool, Error] = Ok(
        @async.with_timeout(60, async fn() -> Bool {
          defer {
            model.released = true
          }
          while !model.entered {
            @async.pause()
          }
          shadow_invoke_command(
            agent,
            "fork-here",
            Json::object(Map::from_array([("index", Json::number(1.0))])),
          )
        }),
      ) catch {
        error => Err(error)
      }
      guard enqueued is Ok(true) else {
        fail("fork enqueue failed: \{repr(enqueued)}")
      }
      running.wait()
    },
  )
  match fork_turn {
    Err(Runtime(InvocationFailed(detail))) =>
      assert_true(detail.contains("core child fact"))
    _ => fail("expected the fork child fact to fail before output")
  }
  let child_sid = "missing-real-parent_fork_fork_1"
  assert_false(agent.runtime.core_shadow.store.sessions.contains(child_sid))
  assert_eq(shadow_redirects(observer.events()).length(), 0)
  assert_eq(agent.runtime.pending_new_thread.length(), 0)
  for key, _cursor in agent.runtime.progress.cursors {
    assert_false(key.has_prefix("missing-real-parent_fork_"))
  }
  match agent.runtime.core_shadow.state.get(child_sid) {
    Some(MissingProvenance) => ()
    _ => fail("expected the child to be marked missing provenance")
  }
  ignore(agent.run_turn(tk_user_msg("child"), child_sid))
  assert_false(agent.runtime.core_shadow.store.sessions.contains(child_sid))
  assert_false(agent.runtime.core_shadow.is_tracked(child_sid))
  match agent.runtime.core_shadow.state.get(child_sid) {
    Some(MissingProvenance) => ()
    _ => fail("expected missing provenance to survive the next real turn")
  }
}

///|
fn shadow_dangling_message() -> @kernel.Message {
  AssistantMessage(
    content=[Text("working")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("dangling-call"),
        name: @kernel.ToolName::unchecked("leaf"),
        arguments: Json::null(),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
  )
}

///|
async test "core_shadow/replace_compact_leaves_no_source_snapshot" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("replacement")],
      mode: Replace,
    }),
  ])
  let store = RecordingSessionStore()
  store.seed("no-orphan-replace", {
    messages: [shadow_dangling_message()],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.compact_session("no-orphan-replace"))
  assert_eq(core_shadow_source_snapshot_count(agent), 0)
  let core = core_shadow_current(agent, "no-orphan-replace")
  assert_eq(core.messages.length(), 1)
  assert_true(core.messages[0] == tk_user_msg("replacement"))
}

///|
async test "core_shadow/model_failure_leaves_no_source_snapshot" {
  let model = ScriptedModel([
    CompactFail(error=Transport("compact failed")),
    Respond(tk_stop_response("after failure")),
  ])
  let store = RecordingSessionStore()
  let dangling = shadow_dangling_message()
  store.seed("no-orphan-failure", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let failed : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("no-orphan-failure"),
  ) catch {
    error => Err(error)
  }
  match failed {
    Err(_) => ()
    Ok(_) => fail("expected the compact model failure")
  }
  assert_eq(core_shadow_source_snapshot_count(agent), 0)
  let parent = core_shadow_current(agent, "no-orphan-failure")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
  ignore(agent.run_turn(tk_user_msg("next"), "no-orphan-failure"))
}

///|
async test "core_shadow/cancel_leaves_no_source_snapshot" {
  let model = ShadowParkingCompactModel::{ entered: false, }
  let store = RecordingSessionStore()
  let dangling = shadow_dangling_message()
  store.seed("no-orphan-cancel", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(async fn(group) {
    let running = group.spawn(async fn() {
      let result : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("no-orphan-cancel"),
      ) catch {
        error => Err(error)
      }
      ignore(result)
    })
    while !model.entered {
      @async.pause()
    }
    running.cancel()
    let waited : Result[Unit, Error] = Ok(running.wait()) catch {
      _ => Err(Error::Failure("cancelled"))
    }
    ignore(waited)
  })
  assert_eq(core_shadow_source_snapshot_count(agent), 0)
  let parent = core_shadow_current(agent, "no-orphan-cancel")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
  ignore(agent.run_turn(tk_user_msg("next"), "no-orphan-cancel"))
}

///|
async test "core_shadow/child_failure_revokes_source_snapshot" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
  ])
  let store = RecordingSessionStore()
  let dangling = shadow_dangling_message()
  store.seed("no-orphan-child", {
    messages: [dangling],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let child_sid = "no-orphan-child_compact_agent_compact_session_1"
  ignore(
    agent.runtime.core_shadow.store.record_full(
      child_sid,
      [tk_user_msg("pre-existing")],
      Map::from_array([]),
    ),
  )
  let failed : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("no-orphan-child"),
  ) catch {
    error => Err(error)
  }
  guard failed is Err(Runtime(InvocationFailed(detail))) else {
    fail("expected the child core fact failure to abort the output")
  }
  assert_true(detail.contains("core child fact"))
  assert_false(store.store.contains(child_sid))
  assert_eq(agent.runtime.pending_new_thread.length(), 0)
  assert_eq(core_shadow_source_snapshot_count(agent), 0)
  let parent = core_shadow_current(agent, "no-orphan-child")
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == dangling)
}

///|
async test "core_shadow/replace_compact_saves_model_body_exactly" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [
        tk_user_msg("summary-one"),
        tk_user_msg("summary-two"),
      ],
      mode: Replace,
    }),
  ])
  let store = RecordingSessionStore()
  store.seed("replace-exact", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.compact_session("replace-exact"))
  let persisted = store.load("replace-exact") catch {
    _ => fail("expected the replaced session to persist")
  }
  assert_eq(persisted.messages.length(), 2)
  assert_true(persisted.messages[0] == tk_user_msg("summary-one"))
  assert_true(persisted.messages[1] == tk_user_msg("summary-two"))
  let core = core_shadow_current(agent, "replace-exact")
  assert_eq(core.messages.length(), 2)
  assert_true(core.messages[0] == tk_user_msg("summary-one"))
  assert_true(core.messages[1] == tk_user_msg("summary-two"))
}
