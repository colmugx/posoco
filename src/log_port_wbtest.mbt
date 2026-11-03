///|
/// Whitebox conformance tests for LogPort protocol invariants, composition
/// cardinality/gating, and the recording testkit fake.
fn test_log_record() -> @port.LogRecord {
  {
    level: @port.LogLevel::Info,
    source: "test_extension",
    channel: "audit",
    event: "thing.completed",
    message: Some("completed"),
    scope: None,
    data: { "value": 7 },
  }
}

///|
priv struct LogLifecycleProbe {
  mut seen : Bool
}

///|
impl @port.Lifecycle for LogLifecycleProbe with fn on_compose(self, ctx) {
  self.seen = ctx.log() is Some(_)
}

///|
impl @port.Lifecycle for LogLifecycleProbe with fn on_shutdown(_self) {
  ()
}

///|
test "log/record_validation_rejects_empty_machine_fields" {
  let record = test_log_record()
  record.validate()
  let bad : @port.LogRecord = { ..record, event: "  ", }
  try bad.validate() catch {
    @error.LogError::InvalidRecord(_) => ()
    error => fail("expected LogError::InvalidRecord, got \{error}")
  } noraise {
    _ => fail("expected empty event to fail validation")
  }
}

///|
test "log/composition_is_optional_and_gated" {
  let probe_with = LogLifecycleProbe::{ seen: false, }
  let probe_without = LogLifecycleProbe::{ seen: false, }
  let log = @testkit.RecordingLogPort()
  ignore(
    Agent(
      exts=[
        @testkit.tk_ext(
          id="model",
          model=Some(
            @testkit.ScriptedModel([
              @testkit.ScriptedModelStep::Respond(
                @testkit.tk_stop_response("ok"),
              ),
            ]),
          ),
        ),
        @testkit.tk_ext(id="io", sessions=[@testkit.RecordingSessionPort()]),
        @testkit.tk_ext(id="log", log=Some(log)),
        @testkit.tk_ext(
          id="consumer",
          lifecycle=[probe_with as &@port.Lifecycle],
          requires=[@port.Capability::Log],
        ),
        @testkit.tk_ext(id="undeclared", lifecycle=[
          probe_without as &@port.Lifecycle,
        ]),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    ),
  )
  assert_true(probe_with.seen)
  assert_false(probe_without.seen)
  let model : &@port.ModelPort = @testkit.ScriptedModel([])
  let ui : &@port.UiPort = @testkit.RecordingUiPort::new_unsupported()
  let absent = @testkit.tk_view(requires=[@port.Capability::Log], model~, ui~)
  assert_true(absent.log() is None)
}

///|
test "log/composition_rejects_multiple_providers" {
  let a = @testkit.RecordingLogPort()
  let b = @testkit.RecordingLogPort()
  try
    Agent(
      exts=[
        @testkit.tk_ext(
          id="model",
          model=Some(
            @testkit.ScriptedModel([
              @testkit.ScriptedModelStep::Respond(
                @testkit.tk_stop_response("ok"),
              ),
            ]),
          ),
        ),
        @testkit.tk_ext(id="io", sessions=[@testkit.RecordingSessionPort()]),
        @testkit.tk_ext(id="log-a", log=Some(a)),
        @testkit.tk_ext(id="log-b", log=Some(b)),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    )
  catch {
    @error.CompositionError::MultipleLogs(manifests~) =>
      assert_eq(manifests, ["log-a", "log-b"])
    error => fail("expected MultipleLogs, got \{error}")
  } noraise {
    _ => fail("expected composition to reject multiple LogPorts")
  }
}
