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
  let log = @test_support.RecordingLogPort()
  ignore(
    Agent(
      events=EventSystem(),
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(
            @test_support.ScriptedModel([
              @test_support.ScriptedModelStep::Respond(
                @test_support.tk_stop_response("ok"),
              ),
            ]),
          ),
        ),
        @test_support.tk_ext(id="io", sessions=[
          @test_support.RecordingSessionPort(),
        ]),
        @test_support.tk_ext(id="log", log=Some(log)),
        @test_support.tk_ext(
          id="consumer",
          lifecycle=[probe_with as &@port.Lifecycle],
          requires=[@port.Capability::Log],
        ),
        @test_support.tk_ext(id="undeclared", lifecycle=[
          probe_without as &@port.Lifecycle,
        ]),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    ),
  )
  assert_true(probe_with.seen)
  assert_false(probe_without.seen)
  let model : &@port.ModelPort = @test_support.ScriptedModel([])
  let ui : &@port.UiPort = @test_support.RecordingUiPort::new_unsupported()
  let absent = @test_support.tk_view(
    requires=[@port.Capability::Log],
    model~,
    ui~,
  )
  assert_true(absent.log() is None)
}

///|
test "log/composition_rejects_multiple_providers" {
  let a = @test_support.RecordingLogPort()
  let b = @test_support.RecordingLogPort()
  try
    Agent(
      events=EventSystem(),
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(
            @test_support.ScriptedModel([
              @test_support.ScriptedModelStep::Respond(
                @test_support.tk_stop_response("ok"),
              ),
            ]),
          ),
        ),
        @test_support.tk_ext(id="io", sessions=[
          @test_support.RecordingSessionPort(),
        ]),
        @test_support.tk_ext(id="log-a", log=Some(a)),
        @test_support.tk_ext(id="log-b", log=Some(b)),
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
