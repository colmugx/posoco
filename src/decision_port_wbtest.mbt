///|
/// Whitebox conformance tests for DecisionPort protocol invariants,
/// composition cardinality, gated delivery, and the scripted testkit fake.
fn decision_request() -> @port.DecisionRequest {
  {
    state: { "tool": "bash", "command": "git status" },
    questions: [
      @port.DecisionQuestion::Boolean(
        id="read_only",
        instructions="Does this operation only inspect state?",
        true_criteria=None,
        false_criteria=None,
      ),
    ],
  }
}

///|
priv struct DecisionLifecycleProbe {
  mut seen : Bool
}

///|
impl @port.Lifecycle for DecisionLifecycleProbe with fn on_compose(self, ctx) {
  self.seen = ctx.decision() is Some(_)
}

///|
impl @port.Lifecycle for DecisionLifecycleProbe with fn on_shutdown(_self) {
  ()
}

///|
test "decision/validation_rejects_malformed_probability" {
  let request = decision_request()
  let bad : @port.DecisionResult = {
    answers: [
      @port.DecisionAnswer::BooleanAnswer(id="read_only", probability_true=1.5),
    ],
    model: None,
    usage: None,
  }
  try bad.validate_for(request) catch {
    @error.DecisionError::ResponseParse(_) => ()
    error => fail("expected DecisionError::ResponseParse, got \{error}")
  } noraise {
    _ => fail("expected malformed probability to fail validation")
  }
}

///|
test "decision/composition_is_optional_and_gated" {
  let probe_with = DecisionLifecycleProbe::{ seen: false, }
  let probe_without = DecisionLifecycleProbe::{ seen: false, }
  let decision = @testkit.ScriptedDecisionPort([])
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
        @testkit.tk_ext(id="decision", decision=Some(decision)),
        @testkit.tk_ext(
          id="consumer",
          lifecycle=[probe_with as &@port.Lifecycle],
          requires=[@port.Capability::Decision],
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
  let absent = @testkit.tk_view(
    requires=[@port.Capability::Decision],
    model~,
    ui~,
  )
  assert_true(absent.decision() is None)
}

///|
test "decision/composition_rejects_multiple_providers" {
  let a = @testkit.ScriptedDecisionPort([])
  let b = @testkit.ScriptedDecisionPort([])
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
        @testkit.tk_ext(id="decision-a", decision=Some(a)),
        @testkit.tk_ext(id="decision-b", decision=Some(b)),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    )
  catch {
    @error.CompositionError::MultipleDecisions(manifests~) =>
      assert_eq(manifests, ["decision-a", "decision-b"])
    error => fail("expected MultipleDecisions, got \{error}")
  } noraise {
    _ => fail("expected composition to reject multiple DecisionPorts")
  }
}
