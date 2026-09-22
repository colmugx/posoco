///|
/// Provider-neutral semantic judgement primitives. A DecisionPort evaluates
/// structured state against independent typed questions and returns
/// probabilities; policy, authority, and execution stay with the consuming
/// extension.

///|
/// One named alternative for a `Choice` question.
pub(all) struct DecisionOption {
  id : String
  description : Json?
} derive(Eq, Debug)

///|
pub extend DecisionOption with Eq::{not_equal, equal}

///|
pub extend DecisionOption with Debug::{to_repr}

///|
/// Typed question understood by a `DecisionPort`.
pub(all) enum DecisionQuestion {
  /// Probability that the proposition is true. Criteria are optional outcome
  /// descriptions, not policy thresholds.
  Boolean(
    id~ : String,
    instructions~ : Json,
    true_criteria~ : Json?,
    false_criteria~ : Json?
  )
  /// Select one named alternative and return the complete probability
  /// distribution over the supplied options.
  Choice(id~ : String, instructions~ : Json, options~ : Array[DecisionOption])
  /// Score against an ordered rubric. Level index is the score coordinate;
  /// at least two levels are required by conforming adapters.
  Score(id~ : String, instructions~ : Json, levels~ : Array[Json])
} derive(Eq, Debug)

///|
pub extend DecisionQuestion with Eq::{not_equal, equal}

///|
pub extend DecisionQuestion with Debug::{to_repr}

///|
/// Structured state plus a non-empty set of independent semantic questions.
pub(all) struct DecisionRequest {
  state : Json
  questions : Array[DecisionQuestion]
} derive(Eq, Debug)

///|
pub extend DecisionRequest with Eq::{not_equal, equal}

///|
pub extend DecisionRequest with Debug::{to_repr}

///|
/// One named probability in a choice distribution.
pub(all) struct DecisionNamedProbability {
  id : String
  probability : Double
} derive(Eq, Debug)

///|
pub extend DecisionNamedProbability with Eq::{not_equal, equal}

///|
pub extend DecisionNamedProbability with Debug::{to_repr}

///|
/// Provider-neutral typed answer. The question id is repeated so adapters can
/// be validated without relying on response ordering.
pub(all) enum DecisionAnswer {
  BooleanAnswer(id~ : String, probability_true~ : Double)
  ChoiceAnswer(
    id~ : String,
    selected~ : String,
    probabilities~ : Array[DecisionNamedProbability],
    confidence~ : Double?
  )
  ScoreAnswer(
    id~ : String,
    score~ : Double,
    probabilities~ : Array[Double],
    confidence~ : Double?
  )
} derive(Eq, Debug)

///|
pub extend DecisionAnswer with Eq::{not_equal, equal}

///|
pub extend DecisionAnswer with Debug::{to_repr}

///|
/// Optional token accounting supplied by decision providers.
pub(all) struct DecisionUsage {
  input_tokens : Int?
  output_tokens : Int?
} derive(Eq, Debug)

///|
pub extend DecisionUsage with Eq::{not_equal, equal}

///|
pub extend DecisionUsage with Debug::{to_repr}

///|
/// Typed answers plus provider-reported model/usage metadata. `model` is
/// descriptive observability only; consumers must not branch policy on a
/// provider identity hidden behind this port.
pub(all) struct DecisionResult {
  answers : Array[DecisionAnswer]
  model : String?
  usage : DecisionUsage?
} derive(Eq, Debug)

///|
pub extend DecisionResult with Eq::{not_equal, equal}

///|
pub extend DecisionResult with Debug::{to_repr}

///|
/// A low-cost semantic judgement capability. The port does not decide final
/// business policy: consumers map the returned probabilities into their own
/// deterministic policy and authority flow.
pub(open) trait DecisionPort {
  async fn evaluate(Self, request : DecisionRequest) -> DecisionResult raise @error.DecisionError
}

///|
fn DecisionQuestion::id(self : DecisionQuestion) -> String {
  match self {
    Boolean(id~, ..) | Choice(id~, ..) | Score(id~, ..) => id
  }
}

///|
fn DecisionAnswer::id(self : DecisionAnswer) -> String {
  match self {
    BooleanAnswer(id~, ..) | ChoiceAnswer(id~, ..) | ScoreAnswer(id~, ..) => id
  }
}

///|
fn valid_probability(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf() && value >= 0.0 && value <= 1.0
}

///|
fn validate_confidence(
  question_id : String,
  confidence : Double?,
) -> Unit raise @error.DecisionError {
  match confidence {
    Some(value) if !valid_probability(value) =>
      raise @error.DecisionError::ResponseParse(
        "confidence for question '" +
        question_id +
        "' must be finite and in [0,1]",
      )
    _ => ()
  }
}

///|
/// Validate provider-neutral request invariants before an adapter builds its
/// wire request. Providers may impose additional limits, but must not accept
/// requests that violate these base invariants.
pub fn DecisionRequest::validate(
  self : DecisionRequest,
) -> Unit raise @error.DecisionError {
  if self.questions.is_empty() {
    raise @error.DecisionError::InvalidRequest(
      "at least one decision question is required",
    )
  }
  let ids : Map[String, Bool] = Map::from_array([])
  for question in self.questions {
    let id = question.id()
    if id == "" {
      raise @error.DecisionError::InvalidRequest(
        "decision question id must not be empty",
      )
    }
    if ids.contains(id) {
      raise @error.DecisionError::InvalidRequest(
        "duplicate decision question id '" + id + "'",
      )
    }
    ids[id] = true
    match question {
      Boolean(..) => ()
      Choice(id~, options~, ..) => {
        if options.length() < 2 {
          raise @error.DecisionError::InvalidRequest(
            "choice question '" + id + "' requires at least two options",
          )
        }
        let option_ids : Map[String, Bool] = Map::from_array([])
        for option in options {
          if option.id == "" {
            raise @error.DecisionError::InvalidRequest(
              "choice question '" + id + "' has an empty option id",
            )
          }
          if option_ids.contains(option.id) {
            raise @error.DecisionError::InvalidRequest(
              "choice question '" +
              id +
              "' has duplicate option '" +
              option.id +
              "'",
            )
          }
          option_ids[option.id] = true
        }
      }
      Score(id~, levels~, ..) =>
        if levels.length() < 2 {
          raise @error.DecisionError::InvalidRequest(
            "score question '" + id + "' requires at least two levels",
          )
        }
    }
  }
}

///|
/// Validate a provider result against the request that produced it. Adapters
/// should call this before returning so malformed or semantically mismatched
/// provider payloads fail loudly as `DecisionError::ResponseParse`.
pub fn DecisionResult::validate_for(
  self : DecisionResult,
  request : DecisionRequest,
) -> Unit raise @error.DecisionError {
  request.validate()
  if self.answers.length() != request.questions.length() {
    raise @error.DecisionError::ResponseParse(
      "decision answer count does not match question count",
    )
  }
  let questions : Map[String, DecisionQuestion] = Map::from_array([])
  for question in request.questions {
    questions[question.id()] = question
  }
  let seen : Map[String, Bool] = Map::from_array([])
  for answer in self.answers {
    let id = answer.id()
    if seen.contains(id) {
      raise @error.DecisionError::ResponseParse(
        "duplicate decision answer id '" + id + "'",
      )
    }
    seen[id] = true
    if !questions.contains(id) {
      raise @error.DecisionError::ResponseParse(
        "decision answer id '" + id + "' was not requested",
      )
    }
    match (questions[id], answer) {
      (Boolean(..), BooleanAnswer(probability_true~, ..)) =>
        if !valid_probability(probability_true) {
          raise @error.DecisionError::ResponseParse(
            "boolean probability for question '" +
            id +
            "' must be finite and in [0,1]",
          )
        }
      (
        Choice(options~, ..),
        ChoiceAnswer(selected~, probabilities~, confidence~, ..),
      ) => {
        validate_confidence(id, confidence)
        if probabilities.length() != options.length() {
          raise @error.DecisionError::ResponseParse(
            "choice probabilities for question '" +
            id +
            "' do not match option count",
          )
        }
        let allowed : Map[String, Bool] = Map::from_array([])
        for option in options {
          allowed[option.id] = true
        }
        if !allowed.contains(selected) {
          raise @error.DecisionError::ResponseParse(
            "choice answer for question '" +
            id +
            "' selected unknown option '" +
            selected +
            "'",
          )
        }
        let probability_ids : Map[String, Bool] = Map::from_array([])
        let mut sum = 0.0
        for entry in probabilities {
          if !allowed.contains(entry.id) || probability_ids.contains(entry.id) {
            raise @error.DecisionError::ResponseParse(
              "choice probabilities for question '" +
              id +
              "' contain an unknown or duplicate option",
            )
          }
          if !valid_probability(entry.probability) {
            raise @error.DecisionError::ResponseParse(
              "choice probability for question '" +
              id +
              "' must be finite and in [0,1]",
            )
          }
          probability_ids[entry.id] = true
          sum = sum + entry.probability
        }
        if (sum - 1.0).abs() > 0.000001 {
          raise @error.DecisionError::ResponseParse(
            "choice probabilities for question '" + id + "' must sum to 1",
          )
        }
      }
      (Score(levels~, ..), ScoreAnswer(score~, probabilities~, confidence~, ..)) => {
        validate_confidence(id, confidence)
        if probabilities.length() != levels.length() {
          raise @error.DecisionError::ResponseParse(
            "score probabilities for question '" +
            id +
            "' do not match level count",
          )
        }
        if score.is_nan() ||
          score.is_inf() ||
          score < 0.0 ||
          score > (levels.length() - 1).to_double() {
          raise @error.DecisionError::ResponseParse(
            "score for question '" + id + "' is outside the rubric range",
          )
        }
        let mut sum = 0.0
        for probability in probabilities {
          if !valid_probability(probability) {
            raise @error.DecisionError::ResponseParse(
              "score probability for question '" +
              id +
              "' must be finite and in [0,1]",
            )
          }
          sum = sum + probability
        }
        if (sum - 1.0).abs() > 0.000001 {
          raise @error.DecisionError::ResponseParse(
            "score probabilities for question '" + id + "' must sum to 1",
          )
        }
      }
      _ =>
        raise @error.DecisionError::ResponseParse(
          "decision answer kind does not match question '" + id + "'",
        )
    }
  }
}
