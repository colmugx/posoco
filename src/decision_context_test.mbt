///|
/// Blackbox public-API tests for the backwards-compatible Decision call
/// context: default `evaluate_with_context` delegation for adapters that
/// only implement `evaluate`, context construction defaults, and the
/// `TimedOut` error surface. Deterministic; no external calls.

///|
/// Fixture standing in for an "older" adapter written before the context
/// API: it implements only `evaluate`.
struct LegacyOnlyDecisionPort {
  mut evaluate_calls : Int
}

///|
impl @port.DecisionPort for LegacyOnlyDecisionPort with fn evaluate(
  self,
  _request : @port.DecisionRequest,
) -> @port.DecisionResult raise @error.DecisionError {
  self.evaluate_calls = self.evaluate_calls + 1
  {
    answers: [
      @port.DecisionAnswer::BooleanAnswer(id="read_only", probability_true=0.5),
    ],
    model: Some("legacy"),
    usage: None,
  }
}

///|
fn context_test_request() -> @port.DecisionRequest {
  {
    state: { "tool": "bash" },
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
async test "decision/default_evaluate_with_context_delegates_for_legacy_adapter" {
  let adapter : LegacyOnlyDecisionPort = { evaluate_calls: 0, }
  let context = @port.DecisionCallContext::make(
    purpose="typecheck",
    scope={ session: "session_1", },
    timeout_ms=500,
    failure_mode=@port.FailClosed,
  )
  let result = (adapter as &@port.DecisionPort).evaluate_with_context(
    context_test_request(),
    context~,
  )
  guard! result.answers.length() == 1
  guard! result.answers[0]
    is @port.DecisionAnswer::BooleanAnswer(id="read_only", probability_true=0.5)
  guard! result.model is Some("legacy")
  // The context is accepted but delegation reaches the legacy evaluate.
  assert_eq(adapter.evaluate_calls, 1)
}

///|
test "decision/call_context_make_defaults" {
  let context = @port.DecisionCallContext::make(purpose="attribution")
  guard! context.scope is None
  guard! context.timeout_ms is None
  assert_eq(context.failure_mode, @port.DecisionFailureMode::Propagate)
}

///|
test "decision/call_context_make_keeps_explicit_fields" {
  let context = @port.DecisionCallContext::make(
    purpose="auto_permission",
    scope={ session: "session_2", },
    timeout_ms=1200,
    failure_mode=@port.Fallback,
  )
  guard! context.scope is Some({ session: "session_2", })
  assert_eq(context.timeout_ms, Some(1200))
  assert_eq(context.failure_mode, @port.DecisionFailureMode::Fallback)
}

///|
test "decision/failure_mode_is_diagnostics_only_enums" {
  // The declared failure mode is data the consumer interprets; the port
  // defines the three approved values and nothing else.
  let modes = [
    @port.DecisionFailureMode::Fallback,
    @port.DecisionFailureMode::FailClosed,
    @port.DecisionFailureMode::Propagate,
  ]
  assert_eq(modes.length(), 3)
}

///|
test "decision/timed_out_show" {
  let error : @error.DecisionError = @error.DecisionError::TimedOut(
    timeout_ms=1500,
  )
  inspect(error.to_string(), content="DecisionError::TimedOut(timeout_ms=1500)")
}
