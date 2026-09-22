// ---------------------------------------------------------------------------
// ScriptedDecisionPort — fixed semantic-judgement script + request recording.
// ---------------------------------------------------------------------------

///|
pub(all) enum ScriptedDecisionStep {
  Return(@port.DecisionResult)
  Fail(@error.DecisionError)
}

///|
fn snapshot_optional_json(value : Json?) -> Json? {
  match value {
    Some(value) => Some(snapshot_json(value))
    None => None
  }
}

///|
fn snapshot_decision_question(
  question : @port.DecisionQuestion,
) -> @port.DecisionQuestion {
  match question {
    Boolean(id~, instructions~, true_criteria~, false_criteria~) =>
      Boolean(
        id~,
        instructions=snapshot_json(instructions),
        true_criteria=snapshot_optional_json(true_criteria),
        false_criteria=snapshot_optional_json(false_criteria),
      )
    Choice(id~, instructions~, options~) =>
      Choice(
        id~,
        instructions=snapshot_json(instructions),
        options=options.map(fn(option) {
          {
            id: option.id,
            description: snapshot_optional_json(option.description),
          }
        }),
      )
    Score(id~, instructions~, levels~) =>
      Score(
        id~,
        instructions=snapshot_json(instructions),
        levels=levels.map(snapshot_json),
      )
  }
}

///|
fn snapshot_decision_request(
  request : @port.DecisionRequest,
) -> @port.DecisionRequest {
  {
    state: snapshot_json(request.state),
    questions: request.questions.map(snapshot_decision_question),
  }
}

///|
fn snapshot_decision_answer(
  answer : @port.DecisionAnswer,
) -> @port.DecisionAnswer {
  match answer {
    BooleanAnswer(id~, probability_true~) =>
      BooleanAnswer(id~, probability_true~)
    ChoiceAnswer(id~, selected~, probabilities~, confidence~) =>
      ChoiceAnswer(
        id~,
        selected~,
        probabilities=probabilities.map(fn(entry) {
          { id: entry.id, probability: entry.probability, }
        }),
        confidence~,
      )
    ScoreAnswer(id~, score~, probabilities~, confidence~) =>
      ScoreAnswer(id~, score~, probabilities=probabilities.copy(), confidence~)
  }
}

///|
fn snapshot_decision_result(
  result : @port.DecisionResult,
) -> @port.DecisionResult {
  {
    answers: result.answers.map(snapshot_decision_answer),
    model: result.model,
    usage: result.usage,
  }
}

///|
fn snapshot_decision_step(step : ScriptedDecisionStep) -> ScriptedDecisionStep {
  match step {
    Return(result) => Return(snapshot_decision_result(result))
    Fail(error) => Fail(error)
  }
}

///|
/// DecisionPort fake that consumes one scripted step per evaluation and
/// records a deep snapshot of every request. Exhaustion is loud.
pub(all) struct ScriptedDecisionPort {
  steps : Array[ScriptedDecisionStep]
  mut index : Int
  received : Array[@port.DecisionRequest]
}

///|
pub fn ScriptedDecisionPort::ScriptedDecisionPort(
  steps : Array[ScriptedDecisionStep],
) -> ScriptedDecisionPort {
  { steps: steps.map(snapshot_decision_step), index: 0, received: [], }
}

///|
pub fn ScriptedDecisionPort::call_count(self : ScriptedDecisionPort) -> Int {
  self.received.length()
}

///|
pub fn ScriptedDecisionPort::received_requests(
  self : ScriptedDecisionPort,
) -> Array[@port.DecisionRequest] {
  self.received.map(snapshot_decision_request)
}

///|
pub async fn ScriptedDecisionPort::evaluate_direct(
  self : ScriptedDecisionPort,
  request : @port.DecisionRequest,
) -> @port.DecisionResult raise @error.DecisionError {
  (self as &@port.DecisionPort).evaluate(request)
}

///|
pub extend ScriptedDecisionPort with @port.DecisionPort::{evaluate}

///|
pub impl @port.DecisionPort for ScriptedDecisionPort with fn evaluate(
  self,
  request,
) -> @port.DecisionResult raise @error.DecisionError {
  self.received.push(snapshot_decision_request(request))
  if self.index >= self.steps.length() {
    raise @error.DecisionError::Transport(
      "scripted_decision_exhausted at call \{self.received.length()} (script had \{self.steps.length()} steps)",
    )
  }
  let step = self.steps[self.index]
  self.index = self.index + 1
  match step {
    Return(result) => snapshot_decision_result(result)
    Fail(error) => raise error
  }
}
