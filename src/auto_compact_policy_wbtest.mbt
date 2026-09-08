///|
/// Auto-compact policy tests: latest-occupancy trigger (not run-wide
/// cumulative), host-vs-provider window precedence with the 0.88 core
/// default, the one-fire-per-run latch, and the best-effort failure path
/// (observable skip, turn survives).

///|
/// `ScopeRecordingModel` wrapper whose provider_config reports fixed
/// auto-compact metadata, so precedence can be exercised end to end.
struct PolicyModel {
  inner : ScopeRecordingModel
  reported : @port.ProviderConfig
}

///|
impl @port.ModelPort for PolicyModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  (self.inner as &@port.ModelPort).chat(scope, messages, tools, options, stream)
}

///|
impl @port.ModelPort for PolicyModel with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  options : @types.ChatOptions,
  trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  (self.inner as &@port.ModelPort).compact(scope, messages, options, trigger)
}

///|
impl @port.ModelPort for PolicyModel with fn provider_config(self) -> @port.ProviderConfig {
  self.reported
}

///|
fn policy_reported(
  context_window? : Int? = None,
  compact_threshold? : Double? = None,
) -> @port.ProviderConfig {
  ProviderConfig(
    reasoning_effort_values=[],
    context_window~,
    compact_threshold~,
  )
}

///|
fn policy_tools() -> RecordingToolProvider {
  RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
}

///|
fn policy_replace_result() -> @kernel.CompactResult {
  { compacted_messages: [tk_user_msg("summary")], mode: Replace, }
}

///|
async test "policy/provider-reported window enables auto-compact without host config" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_live_window"))
  assert_eq(model.inner.compact_scopes().length(), 1)
}

///|
async test "policy/compact scope carries the resolved pressure reading" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_pressure_scope"))
  let scopes = model.inner.compact_scopes()
  assert_eq(scopes.length(), 1)
  guard scopes[0].pressure is Some(pressure) else {
    fail("expected the compact scope to carry pressure")
  }
  assert_eq(pressure.window_tokens, Some(100))
  assert_eq(pressure.occupancy_tokens, Some(95))
  assert_eq(pressure.compact_threshold, 0.9)
}

///|
async test "policy/host window overrides the provider report" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config={ ..tk_config(), model_context_window: Some(1000), },
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_host_override"))
  // 95 is far under 90% of the host's 1000-token override: no compact.
  assert_eq(model.inner.compact_scopes().length(), 0)
}

///|
async test "policy/core default threshold is 0.88 when nobody declares one" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(89)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(context_window=Some(100)),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_default_threshold"))
  // 89 >= 88% of 100 with the core default; the old 0.9 would NOT fire.
  assert_eq(model.inner.compact_scopes().length(), 1)
}

///|
async test "policy/cumulative usage does not trigger, latest occupancy does" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(60)),
        Respond(scope_test_tool_call_with_usage(60)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_cumulative"))
  // Two 60/100 calls sum to 120 but each call's own occupancy is 60: the
  // run-wide cumulative total must not fire the trigger.
  assert_eq(model.inner.compact_scopes().length(), 0)
}

///|
async test "policy/same task crossing twice compacts twice" {
  let model = PolicyModel::{
    inner: ScopeRecordingModel(
      [
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(tk_stop_response("done")),
      ],
      compact_result=policy_replace_result(),
    ),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_double_fire"))
  assert_eq(model.inner.compact_scopes().length(), 2)
}

///|
async test "policy/auto-compact failure stops the turn immediately and is reported" {
  let observer = RecordingObserver()
  // compact_result absent: ScopeRecordingModel::compact raises, standing in
  // for a modelport that does not implement compact.
  let model = PolicyModel::{
    inner: ScopeRecordingModel([
      Respond(scope_test_tool_call_with_usage(95)),
      Respond(tk_stop_response("done")),
    ]),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hi"), "session_failed_compact"),
  ) catch {
    error => Err(error)
  }
  guard result is Err(@error.AgentError::AutoCompactFailed(_)) else {
    fail("expected a typed AutoCompactFailed outcome, got \{repr(result)}")
  }
  assert_eq(model.inner.compact_scopes().length(), 1)
  assert_eq(model.inner.chat_scopes().length(), 1)
  let persisted = store.store["session_failed_compact"]
  assert_eq(persisted.messages.length(), 3)
  assert_true(persisted.messages[0] == tk_user_msg("hi"))
  assert_true(persisted.messages[2] is ToolMessage(..))
  let mut seen_failed = false
  for event in observer.events() {
    match event {
      TurnFailed(reason) =>
        if reason.contains("AutoCompactFailed") {
          seen_failed = true
        }
      _ => ()
    }
  }
  assert_true(seen_failed)
}

// ---------------------------------------------------------------------------
// End-to-end: the Replace rewrite must actually reach the next model call.
// The policy tests above pin WHEN auto-compact fires; these pin that the
// compacted transcript IS what the model sees afterwards — inside the same
// run and on the next turn of the same session.
// ---------------------------------------------------------------------------

///|
/// PolicyModel variant that also records every `chat` message array, so the
/// post-compact projection can be asserted exactly.
struct AutoCompactE2EModel {
  scripted : ScriptedModel
  compact_result : @kernel.CompactResult
  reported : @port.ProviderConfig
  seen : Array[Array[@kernel.Message]]
  compact_calls : Ref[Int]
}

///|
fn auto_compact_e2e_model(
  steps : Array[ScriptedModelStep],
  compacted_messages : Array[@kernel.Message],
) -> AutoCompactE2EModel {
  {
    scripted: ScriptedModel(steps),
    compact_result: { compacted_messages, mode: Replace, },
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
    seen: [],
    compact_calls: { val: 0, },
  }
}

///|
fn AutoCompactE2EModel::seen_chats(
  self : AutoCompactE2EModel,
) -> Array[Array[@kernel.Message]] {
  self.seen.copy()
}

///|
impl @port.ModelPort for AutoCompactE2EModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.seen.push(messages.to_owned())
  (self.scripted as &@port.ModelPort).chat(
    scope, messages, tools, options, stream,
  )
}

///|
impl @port.ModelPort for AutoCompactE2EModel with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  options : @types.ChatOptions,
  trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.compact_calls.val += 1
  ignore(scope)
  ignore(messages)
  ignore(options)
  ignore(trigger)
  self.compact_result
}

///|
impl @port.ModelPort for AutoCompactE2EModel with fn provider_config(self) -> @port.ProviderConfig {
  self.reported
}

///|
/// The kit-shaped Replace result: one summary user message followed by the
/// verbatim tail, exactly what `build_replace_result` produces.
fn auto_compact_kit_shaped_compacted() -> Array[@kernel.Message] {
  [
    tk_user_msg("summary of the earlier conversation"),
    tk_user_msg("recent question"),
    tk_assistant_msg_e2e("recent answer"),
  ]
}

///|
fn tk_assistant_msg_e2e(text : String) -> @kernel.Message {
  AssistantMessage(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
}

///|
async test "policy/e2e compacted transcript is what the next model call sees" {
  // usage 95/100 crosses 0.9 after the tool-call step; the follow-up stop
  // step must observe the compacted transcript, not the original one.
  let compacted = auto_compact_kit_shaped_compacted()
  let model = auto_compact_e2e_model(
    [
      Respond(scope_test_tool_call_with_usage(95)),
      Respond(tk_stop_response("done")),
    ],
    compacted,
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_e2e_projection"))
  assert_eq(model.compact_calls.val, 1)
  // Two chats: the tool-call step (pre-compact) and the stop step
  // (post-compact). The second must see exactly the compacted transcript.
  let seen = model.seen_chats()
  assert_eq(seen.length(), 2)
  let second = seen[1]
  assert_eq(second.length(), compacted.length())
  for i in 0..<compacted.length() {
    assert_true(second[i] == compacted[i])
  }
  // And it must NOT contain the original opening user message.
  for message in second {
    match message {
      UserMessage(content~) =>
        for block in content {
          match block {
            Text(text) => assert_true(text != "hi")
            _ => ()
          }
        }
      _ => ()
    }
  }
}

///|
fn policy_context_metadata(
  session_id~ : String,
  measured~ : Int,
  window~ : Int,
  reading_count~ : Int,
) -> Map[String, Json] {
  let state : @types.ContextState = {
    session_id,
    model_id: "agent",
    context_version: 0,
    last_measured_tokens: Some(measured),
    estimated_added_tokens: 0,
    window_tokens: Some(window),
    compact_threshold: 0.9,
    source: Measured,
    reading_message_count: reading_count,
  }
  Map::from_array([
    (@types.CONTEXT_STATE_METADATA_KEY, state.to_metadata_json()),
  ])
}

///|
async test "policy/pre-request check compacts before the first request" {
  let store = RecordingSessionStore()
  store.seed("session_pre", {
    messages: [tk_user_msg("hello")],
    metadata: policy_context_metadata(
      session_id="session_pre",
      measured=95,
      window=100,
      reading_count=1,
    ),
  })
  let model = auto_compact_e2e_model([Respond(tk_stop_response("done"))], [
    tk_user_msg("summary"),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi there"), "session_pre"))
  assert_eq(model.compact_calls.val, 1)
  let seen = model.seen_chats()
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].length(), 1)
  guard seen[0][0] is UserMessage(content=[Text(text)]) else {
    fail("expected the compacted summary as the first request body")
  }
  assert_eq(text, "summary")
}

///|
async test "policy/pre-request check stays quiet below the threshold" {
  let store = RecordingSessionStore()
  store.seed("session_pre_low", {
    messages: [tk_user_msg("hello")],
    metadata: policy_context_metadata(
      session_id="session_pre_low",
      measured=60,
      window=100,
      reading_count=1,
    ),
  })
  let model = auto_compact_e2e_model([Respond(tk_stop_response("done"))], [
    tk_user_msg("summary"),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi there"), "session_pre_low"))
  assert_eq(model.compact_calls.val, 0)
  let seen = model.seen_chats()
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].length(), 2)
}

///|
async test "policy/pre-request check ignores readings from another window" {
  let store = RecordingSessionStore()
  store.seed("session_pre_window", {
    messages: [tk_user_msg("hello")],
    metadata: policy_context_metadata(
      session_id="session_pre_window",
      measured=950,
      window=1000,
      reading_count=1,
    ),
  })
  let model = auto_compact_e2e_model([Respond(tk_stop_response("done"))], [
    tk_user_msg("summary"),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi there"), "session_pre_window"))
  assert_eq(model.compact_calls.val, 0)
  assert_eq(model.seen_chats().length(), 1)
}

///|
async test "policy/e2e compacted transcript persists into the next turn" {
  let compacted = auto_compact_kit_shaped_compacted()
  let model = auto_compact_e2e_model(
    [
      // Turn 1: cross the threshold, fire auto-compact, finish.
      Respond(scope_test_tool_call_with_usage(95)),
      Respond(tk_stop_response("turn1 done")),
      // Turn 2: a plain exchange on the same session.
      Respond(tk_stop_response("turn2 done")),
    ],
    compacted,
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "session_e2e_persist"))
  ignore(agent.run_turn(tk_user_msg("second turn"), "session_e2e_persist"))
  assert_eq(model.compact_calls.val, 1)
  let seen = model.seen_chats()
  // Turn 1: two chats; turn 2: one chat.
  assert_eq(seen.length(), 3)
  // The compact fired mid-turn-1, so turn 1's closing stop response appended
  // normally AFTER the compacted transcript. The next turn's request must be:
  // compacted transcript, then turn 1's assistant close, then the new user
  // message.
  let next_turn = seen[2]
  assert_eq(next_turn.length(), compacted.length() + 2)
  for i in 0..<compacted.length() {
    assert_true(next_turn[i] == compacted[i])
  }
  guard next_turn[compacted.length()]
    is AssistantMessage(content=close_content, ..) else {
    fail("expected turn 1's assistant close after the compacted transcript")
  }
  guard close_content[0] is Text(close_text) else {
    fail("expected text content")
  }
  assert_eq(close_text, "turn1 done")
  guard next_turn[next_turn.length() - 1] is UserMessage(content~) else {
    fail("expected the new user message at the end")
  }
  guard content[0] is Text(text) else { fail("expected text content") }
  assert_eq(text, "second turn")
}

///|
async test "policy/pre-request check covers the first request after resume" {
  let store = RecordingSessionStore()
  store.seed("session_pre_resume", {
    messages: [
      tk_user_msg("hello"),
      AssistantMessage(
        content=[Text("partial progress from the interrupted run")],
        reasoning=None,
        tool_calls=[],
        finish_reason=Stop,
      ),
    ],
    metadata: policy_context_metadata(
      session_id="session_pre_resume",
      measured=95,
      window=100,
      reading_count=1,
    ),
  })
  let model = auto_compact_e2e_model([Respond(tk_stop_response("resumed"))], [
    tk_user_msg("summary"),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.resume_turn("session_pre_resume"))
  assert_eq(model.compact_calls.val, 1)
  let seen = model.seen_chats()
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].length(), 1)
}
