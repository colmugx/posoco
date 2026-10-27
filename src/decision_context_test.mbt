///|
struct ContextDecisionProbe {
  mut evaluate_calls : Int32
  contexts : Array[@port.DecisionCallContext]
}

///|
impl @port.DecisionPort for ContextDecisionProbe with fn evaluate(
  self,
  _request : @port.DecisionRequest,
  context~,
) -> @port.DecisionResult raise @error.DecisionError {
  self.contexts.push(context)
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
async test "decision/evaluate_receives_exact_context" {
  let adapter : ContextDecisionProbe = { evaluate_calls: 0, contexts: [], }
  let context = @port.DecisionCallContext::make(
    purpose="typecheck",
    scope={ session: "session_1", },
    timeout_ms=500,
    failure_mode=@port.FailClosed,
  )
  let result = (adapter as &@port.DecisionPort).evaluate(
    context_test_request(),
    context~,
  )
  guard! result.answers.length() == 1
  guard! result.answers[0]
    is @port.DecisionAnswer::BooleanAnswer(id="read_only", probability_true=0.5)
  guard! result.model is Some("legacy")
  assert_eq(adapter.contexts, [context])
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
test "decision/timed_out_show" {
  let error : @error.DecisionError = @error.DecisionError::TimedOut(
    timeout_ms=1500,
  )
  inspect(error.to_string(), content="DecisionError::TimedOut(timeout_ms=1500)")
}
