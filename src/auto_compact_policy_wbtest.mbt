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
async test "policy/one auto-compact per run even when occupancy stays over" {
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
  ignore(agent.run_turn(tk_user_msg("hi"), "session_single_fire"))
  // The first crossing fires; the post-Replace observation crosses again but
  // the per-run latch must hold it at exactly one attempt.
  assert_eq(model.inner.compact_scopes().length(), 1)
}

///|
async test "policy/auto-compact failure skips observably and the turn survives" {
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
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[observer]),
    ],
    config=tk_config(),
  )
  // Must not raise: a best-effort auto-compact failure continues the turn.
  ignore(agent.run_turn(tk_user_msg("hi"), "session_failed_compact"))
  assert_eq(model.inner.compact_scopes().length(), 1)
  let mut seen_secondary = false
  for event in observer.events() {
    match event {
      Custom(source~, label~, data~) =>
        if source == "posoco.core" && label == "secondary_failure" {
          match data {
            Object(fields) =>
              match fields.get("hook_point") {
                Some(String(point)) if point == "auto_compact" =>
                  seen_secondary = true
                _ => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(seen_secondary)
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
