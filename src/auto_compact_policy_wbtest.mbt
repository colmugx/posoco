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
  @port.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window~,
    compact_threshold~,
  )
}

///|
fn policy_tools() -> RecordingToolProvider {
  RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
}

///|
fn policy_replace_result() -> @kernel.CompactResult {
  { compacted_messages: [tk_user_msg("summary")], mode: @kernel.Replace, }
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
            Json::Object(fields) =>
              match fields.get("hook_point") {
                Some(Json::String(point)) if point == "auto_compact" =>
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
