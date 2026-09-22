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
async test "log/testkit_records_durability_and_flush" {
  let port = RecordingLogPort()
  let record = test_log_record()
  port.write_direct(record, @port.LogDurability::Durable)
  (port as &@port.LogPort).flush()
  assert_eq(port.writes(), [
    { record, durability: @port.LogDurability::Durable, },
  ])
  assert_eq(port.flush_count(), 1)
}

///|
test "log/composition_is_optional_and_gated" {
  let probe_with = LogLifecycleProbe::{ seen: false, }
  let probe_without = LogLifecycleProbe::{ seen: false, }
  let log = RecordingLogPort()
  ignore(
    Agent(
      exts=[
        tk_ext(
          id="model",
          model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
        ),
        tk_ext(id="io", sessions=[RecordingSessionStore()]),
        tk_ext(id="log", log=Some(log)),
        tk_ext(id="consumer", lifecycle=[probe_with as &@port.Lifecycle], requires=[
          @port.Capability::Log,
        ]),
        tk_ext(id="undeclared", lifecycle=[probe_without as &@port.Lifecycle]),
      ],
      config=tk_config(),
    ),
  )
  assert_true(probe_with.seen)
  assert_false(probe_without.seen)
  let model : &@port.ModelPort = ScriptedModel([])
  let ui : &@port.UiPort = RecordingUiPort::new_unsupported()
  let absent = tk_view(requires=[@port.Capability::Log], model~, ui~)
  assert_true(absent.log() is None)
}

///|
test "log/composition_rejects_multiple_providers" {
  let a = RecordingLogPort()
  let b = RecordingLogPort()
  try
    Agent(
      exts=[
        tk_ext(
          id="model",
          model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
        ),
        tk_ext(id="io", sessions=[RecordingSessionStore()]),
        tk_ext(id="log-a", log=Some(a)),
        tk_ext(id="log-b", log=Some(b)),
      ],
      config=tk_config(),
    )
  catch {
    @error.CompositionError::MultipleLogs(manifests~) =>
      assert_eq(manifests, ["log-a", "log-b"])
    error => fail("expected MultipleLogs, got \{error}")
  } noraise {
    _ => fail("expected composition to reject multiple LogPorts")
  }
}
