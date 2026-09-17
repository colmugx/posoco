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
fn decision_result() -> @port.DecisionResult {
  {
    answers: [
      @port.DecisionAnswer::BooleanAnswer(id="read_only", probability_true=0.98),
    ],
    model: Some("scripted"),
    usage: Some({ input_tokens: Some(7), output_tokens: Some(1), }),
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
test "decision/request_and_result_validate" {
  let request = decision_request()
  let result = decision_result()
  request.validate()
  result.validate_for(request)
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
async test "decision/testkit_records_and_replays" {
  let port = ScriptedDecisionPort([Return(decision_result())])
  let request = decision_request()
  let result = port.evaluate_direct(request)
  result.validate_for(request)
  assert_eq(port.call_count(), 1)
  assert_eq(port.received_requests(), [request])
}

///|
test "decision/composition_is_optional_and_gated" {
  let probe_with = DecisionLifecycleProbe::{ seen: false, }
  let probe_without = DecisionLifecycleProbe::{ seen: false, }
  let decision = ScriptedDecisionPort([])
  ignore(
    Agent(
      exts=[
        tk_ext(
          id="model",
          model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
        ),
        tk_ext(id="io", sessions=[RecordingSessionStore()]),
        tk_ext(id="decision", decision=Some(decision)),
        tk_ext(id="consumer", lifecycle=[probe_with as &@port.Lifecycle], requires=[
          @port.Capability::Decision,
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
  let absent = tk_view(requires=[@port.Capability::Decision], model~, ui~)
  assert_true(absent.decision() is None)
}

///|
test "decision/composition_rejects_multiple_providers" {
  let a = ScriptedDecisionPort([])
  let b = ScriptedDecisionPort([])
  try
    Agent(
      exts=[
        tk_ext(
          id="model",
          model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
        ),
        tk_ext(id="io", sessions=[RecordingSessionStore()]),
        tk_ext(id="decision-a", decision=Some(a)),
        tk_ext(id="decision-b", decision=Some(b)),
      ],
      config=tk_config(),
    )
  catch {
    @error.CompositionError::MultipleDecisions(manifests~) =>
      assert_eq(manifests, ["decision-a", "decision-b"])
    error => fail("expected MultipleDecisions, got \{error}")
  } noraise {
    _ => fail("expected composition to reject multiple DecisionPorts")
  }
}
