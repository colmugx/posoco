///|
/// R3 M3.7 ConfigChanged + ConfigWarning tests.
///
/// When the user changes a runtime config value (model name, reasoning_effort)
/// via UI or slash command, posoco:
///   1. Validates against the active ModelPort's `ProviderConfig`.
///   2. Emits `TurnEvent::ConfigChanged` to Observer fan-out (cetas persistence,
///      UI, ...).
///   3. If validation fails, emits `TurnEvent::ConfigWarning` instead and
///      rejects the change (or auto-resets on model switch).
///
/// The ModelPort itself learns about config changes **pull-based** via
/// `call_options` JSON in the next `chat()` call — no subscription, no
/// `on_config_change` trait method.

///|
/// ModelPort fake that declares a fixed set of accepted reasoning_effort
/// values. Returns the configured list from `provider_config()`.
struct FixedEffortModel {
  accepted_efforts : Array[String]
}

///|
impl @port.ModelPort for FixedEffortModel with fn chat(
  _self,
  _messages : Array[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  raise @error.ModelError::Transport(
    "FixedEffortModel.chat not used in this test",
  )
}

///|
impl @port.ModelPort for FixedEffortModel with fn compact(
  _self,
  _messages : Array[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse("FixedEffortModel.compact not used")
}

///|
impl @port.ModelPort for FixedEffortModel with fn provider_config(self) -> @port.ProviderConfig {
  { reasoning_effort_values: self.accepted_efforts.copy() }
}

///|
test "update_reasoning_effort_accepts_value_in_provider_config" {
  let model = FixedEffortModel::{ accepted_efforts: ["low", "medium", "high"] }
  let observer = MockObserver::{ events: [] }
  let config = make_config()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", observers=[observer]),
    ],
    config~,
  )
  agent.update_reasoning_effort("high")
  assert_true(agent.config.reasoning_effort is Some("high"))
  // Exactly one ConfigChanged event, no warnings.
  assert_eq(observer.events.length(), 1)
  match observer.events[0] {
    @types.ConfigChanged(field~, new_value~, ..) => {
      assert_eq(field, "reasoning_effort")
      assert_eq(new_value, "high")
    }
    _ => fail("expected ConfigChanged event")
  }
}

///|
test "update_reasoning_effort_rejects_value_not_in_provider_config" {
  let model = FixedEffortModel::{ accepted_efforts: ["low", "medium", "high"] }
  let observer = MockObserver::{ events: [] }
  let config = make_config()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", observers=[observer]),
    ],
    config~,
  )
  agent.update_reasoning_effort("xhigh")
  // Field stays None (set was rejected).
  assert_true(agent.config.reasoning_effort is None)
  // Observer received exactly one ConfigWarning event.
  assert_eq(observer.events.length(), 1)
  match observer.events[0] {
    @types.ConfigWarning(field~, value~, reason~) => {
      assert_eq(field, "reasoning_effort")
      assert_eq(value, "xhigh")
      assert_true(reason.contains("low"))
      assert_true(reason.contains("high"))
    }
    _ => fail("expected ConfigWarning event")
  }
}

///|
test "update_model_emits_config_changed_and_broadcasts" {
  // R3 M3.7: update_model is by-NAME, not by-instance. The ModelPort itself
  // doesn't swap — the new name propagates pull-based via call_options JSON.
  // This test verifies the broadcast half: observers receive ConfigChanged.
  let model = FixedEffortModel::{ accepted_efforts: ["high", "max"] }
  let observer = MockObserver::{ events: [] }
  let config : AgentConfig = {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: Some("high"),
    model_context_window: None,
    model: None,
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", observers=[observer]),
    ],
    config~,
  )
  agent.update_model("kimi")
  // Field updated.
  assert_eq(agent.config.model, Some("kimi"))
  // Exactly one ConfigChanged event.
  assert_eq(observer.events.length(), 1)
  match observer.events[0] {
    @types.ConfigChanged(field~, new_value~, ..) => {
      assert_eq(field, "model")
      assert_eq(new_value, "kimi")
    }
    _ => fail("expected ConfigChanged event after update_model")
  }
}

///|
test "update_model_auto_resets_reasoning_effort_when_invalid" {
  // ModelPort only accepts "max" — the prior "high" config is now invalid.
  // After update_model, posoco should:
  //   1. emit ConfigChanged(model)
  //   2. emit ConfigWarning(reasoning_effort)
  //   3. emit ConfigChanged(reasoning_effort, reset to None)
  let model = FixedEffortModel::{ accepted_efforts: ["max"] }
  let observer = MockObserver::{ events: [] }
  let config : AgentConfig = {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: Some("high"),
    model_context_window: None,
    model: None,
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", observers=[observer]),
    ],
    config~,
  )
  agent.update_model("o1")
  // reasoning_effort auto-reset.
  assert_true(agent.config.reasoning_effort is None)
  // Three events: ConfigChanged(model) + ConfigWarning(reasoning_effort) +
  // ConfigChanged(reasoning_effort reset).
  assert_eq(observer.events.length(), 3)
  let mut saw_model_change = false
  let mut saw_warning = false
  let mut saw_effort_reset = false
  for event in observer.events {
    match event {
      @types.ConfigChanged(field~, ..) if field == "model" =>
        saw_model_change = true
      @types.ConfigWarning(field~, ..) if field == "reasoning_effort" =>
        saw_warning = true
      @types.ConfigChanged(field~, new_value~, ..) if field ==
        "reasoning_effort" &&
        new_value == "" => saw_effort_reset = true
      _ => ()
    }
  }
  assert_true(saw_model_change)
  assert_true(saw_warning)
  assert_true(saw_effort_reset)
}

///|
test "update_model_keeps_reasoning_effort_when_still_valid" {
  let model = FixedEffortModel::{ accepted_efforts: ["high", "max"] }
  let observer = MockObserver::{ events: [] }
  let config : AgentConfig = {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: Some("high"),
    model_context_window: None,
    model: None,
  }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", observers=[observer]),
    ],
    config~,
  )
  agent.update_model("kimi")
  // reasoning_effort kept — only one ConfigChanged(model) event.
  assert_eq(agent.config.reasoning_effort, Some("high"))
  assert_eq(observer.events.length(), 1)
}
