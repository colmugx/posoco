///|
/// Whitebox conformance tests for composition-time capability delivery
/// (manifest `requires` → gated `CompositionView`) and the three-phase
/// Lifecycle contract (on_compose / on_start / on_shutdown).

///|
/// A lifecycle contributor whose on_compose always raises — stands in for an
/// extension that finds its required capability missing from the view.
priv struct FailCompose {
  id : String
}

///|
impl @port.Lifecycle for FailCompose with fn on_compose(self, _ctx) -> Unit raise @error.CompositionError {
  raise @error.CompositionError::ExtensionComposeFailed(
    manifest_id=self.id,
    detail="declared nothing but needs the composed capability",
  )
}

///|
impl @port.Lifecycle for FailCompose with fn on_shutdown(_self) {
  ()
}

///|
/// A legacy-style contributor that implements only `on_shutdown` — the
/// defaulted `on_compose`/`on_start` phases must be satisfied without
/// overrides (back-compat with pre-three-phase extensions).
priv struct LegacyLifecycle {
  log : Array[String]
}

///|
impl @port.Lifecycle for LegacyLifecycle with fn on_shutdown(self) {
  self.log.push("legacy:shutdown")
}

///|
/// An observer writing a shared sequence log, for cross-component ordering
/// assertions against RecordingLifecycle entries.
priv struct LogObserver {
  log : Array[String]
}

///|
impl @port.Observer for LogObserver with fn on_event(self, event) {
  self.log.push("obs:" + event.to_string())
}

///|
fn scripted_model_ext(steps : Array[ScriptedModelStep]) -> ManifestOnly {
  tk_ext(id="model", model=Some(ScriptedModel(steps)))
}

///|
fn io_ext() -> ManifestOnly {
  tk_ext(id="io", sessions=[RecordingSessionStore()])
}

///|
test "compose/view_gated_by_declared_requires" {
  let log : Array[String] = []
  let both = RecordingLifecycle(id="both", log~)
  let none = RecordingLifecycle(id="none", log~)
  let model_only = RecordingLifecycle(id="model_only", log~)
  ignore(
    Agent(
      exts=[
        scripted_model_ext([Respond(tk_stop_response("ok"))]),
        io_ext(),
        tk_ext(id="both", lifecycle=[both as &@port.Lifecycle], requires=[
          @port.Capability::Model,
          @port.Capability::Ui,
        ]),
        tk_ext(id="none", lifecycle=[none as &@port.Lifecycle]),
        tk_ext(id="model_only", lifecycle=[model_only as &@port.Lifecycle], requires=[
          @port.Capability::Model,
        ]),
      ],
      config=tk_config(),
    ),
  )
  assert_true(both.seen_model)
  assert_true(both.seen_ui)
  assert_false(none.seen_model)
  assert_false(none.seen_ui)
  assert_true(model_only.seen_model)
  assert_false(model_only.seen_ui)
  // Delivery order follows extension registration order.
  assert_eq(log[0], "both:compose(model=true,ui=true)")
  assert_eq(log[1], "none:compose(model=false,ui=false)")
  assert_eq(log[2], "model_only:compose(model=true,ui=false)")
}

///|
test "compose/extension_compose_failure_is_loud" {
  try
    Agent(
      exts=[
        scripted_model_ext([Respond(tk_stop_response("ok"))]),
        io_ext(),
        tk_ext(id="bad_ext", lifecycle=[
          FailCompose::{ id: "bad_ext" } as &@port.Lifecycle,
        ]),
      ],
      config=tk_config(),
    )
  catch {
    @error.CompositionError::ExtensionComposeFailed(manifest_id~, ..) =>
      assert_eq(manifest_id, "bad_ext")
    e => fail("expected ExtensionComposeFailed, got \{e}")
  } noraise {
    _ => fail("expected composition to fail")
  }
}

///|
async test "compose/start_once_before_first_turn_started" {
  let log : Array[String] = []
  let lc = RecordingLifecycle(id="lc", log~)
  let legacy = LegacyLifecycle::{ log, }
  let obs = LogObserver::{ log, }
  let model = ScriptedModel([
    Respond(tk_stop_response("a")),
    Respond(tk_stop_response("b")),
    Respond(tk_stop_response("c")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="lc", lifecycle=[
        lc as &@port.Lifecycle,
        legacy as &@port.Lifecycle,
      ]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("one"), "s1"))
  ignore(agent.run_turn(tk_user_msg("two"), "s1"))
  ignore(agent.run_turn(tk_user_msg("three"), "s1"))
  // Compose delivery happened at construction; on_start fired exactly once,
  // before the first TurnStarted; legacy defaults logged nothing.
  assert_eq(log[0], "lc:compose(model=false,ui=false)")
  assert_eq(log[1], "lc:start")
  assert_eq(log[2], "obs:TurnStarted")
  assert_eq(log.filter(fn(e) { e == "lc:start" }).length(), 1)
  assert_eq(log.filter(fn(e) { e == "obs:TurnStarted" }).length(), 3)
  assert_eq(log.filter(fn(e) { e == "obs:TurnCompleted" }).length(), 3)
  agent.shutdown()
  // Shutdown drains in reverse registration order: legacy after lc.
  assert_eq(log[log.length() - 2], "legacy:shutdown")
  assert_eq(log[log.length() - 1], "lc:shutdown")
}

///|
test "compose/tk_view_gates_like_composition" {
  let model : &@port.ModelPort = ScriptedModel([])
  let ui : &@port.UiPort = RecordingUiPort::new_unsupported()
  let v = tk_view(requires=[@port.Capability::Model], model~, ui~)
  assert_true(v.model() is Some(_))
  assert_true(v.ui() is None)
  let v2 = tk_view(requires=[], model~, ui~)
  assert_true(v2.model() is None)
  assert_true(v2.ui() is None)
}
