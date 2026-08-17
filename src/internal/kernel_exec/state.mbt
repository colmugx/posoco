///|
/// RunState — single source of truth for a Run (ADR §2.2, §2.6).
/// The reducer is the ONLY writer. Every transition produces a fresh RunState.
/// Phase invariants: Initializing/ReadyForModel/AwaitingModel/AwaitingTools/Suspended/Terminal.

///|
pub(all) enum Phase {
  Initializing
  ReadyForModel
  AwaitingModel
  AwaitingTools
  Suspended
  Terminal
} derive(Eq, Debug)

///|
pub impl Show for Phase with fn to_string(self : Phase) -> String {
  match self {
    Initializing => "Initializing"
    ReadyForModel => "ReadyForModel"
    AwaitingModel => "AwaitingModel"
    AwaitingTools => "AwaitingTools"
    Suspended => "Suspended"
    Terminal => "Terminal"
  }
}

///|
/// Terminal outcome of a Run (ADR §2.3). Exactly one per Run.
pub(all) enum RunOutcome {
  Completed(
    final_message~ : @kernel.Message,
    tool_results~ : FixedArray[@kernel.ToolOutcome]
  )
  Failed(reason~ : FailureReason)
  Cancelled(reason~ : CancelReason)
} derive(Eq, Debug)

///|
pub impl Show for RunOutcome with fn to_string(self : RunOutcome) -> String {
  match self {
    Completed(..) => "Completed"
    Failed(reason~) => "Failed(\{reason.to_string()})"
    Cancelled(reason~) => "Cancelled(\{reason.to_string()})"
  }
}

///|
/// The Run's full state. Field visibility is `priv` so callers cannot construct illegal combinations.
/// MoonBit struct fields default to package-private; constructors enforce invariants.
pub struct RunState {
  /// Run id. Survives suspend/resume.
  run_id : RunId
  /// Session id. Set by Start.
  session_id : SessionId
  /// Budget envelope. Constant after construction.
  budget : Budget
  /// Current phase.
  phase : Phase
  /// Canonical transcript.
  transcript : @kernel.Transcript
  /// Pending effects. Length is phase-dependent.
  /// `FixedArray` so the representation can carry proof contracts:
  /// the builder boundary (`mk`/`transition`) converts from `Array`.
  pending_effects : FixedArray[Effect]
  /// Monotonic event sequence for the next emitted event.
  next_event_sequence : EventSequence
  /// Next effect id.
  next_effect_id : EffectId
  /// Current model step id.
  current_model_step_id : ModelStepId
  /// Catalog version. Set by Start; unchanged within a Run.
  catalog_version : CatalogVersion
  /// Budget consumed so far.
  budget_consumed : BudgetConsumed
  /// Terminal outcome. `None` except in `Terminal`.
  outcome : RunOutcome?
  /// Tool outcomes kept separately from transcript.
  /// `FixedArray` for the same proof-contract reason as `pending_effects`.
  tool_results : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)]
  /// Suspension requirement. `None` outside `Suspended`.
  suspension_requirement : SuspensionRequirement?
} derive(Eq, Debug)

///|
/// Construct the initial `Initializing` state. Accepts only `Start` input.
/// Thin raising wrapper over `initial_core`: everything
/// except the defensive `validate` lives in the pure, contracted core. The
/// empty `Transcript` is built here because `@kernel.Transcript::empty`
/// carries no contract and therefore cannot appear in a contracted body.
pub fn RunState::initial(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
) -> RunState raise KernelError {
  RunState::initial_core(
    run_id~,
    session_id~,
    budget~,
    transcript=@kernel.Transcript::empty(),
  ).validate()
}

///|
/// Pure core of `initial`: assemble the `Initializing` seed state. Every
/// field value is either a literal (empty effect/tool ledgers, `None`
/// outcome/suspension) or a zero-argument contracted constructor
/// (`EventSequence::initial` / `EffectId::first` / `ModelStepId::first` /
/// `BudgetConsumed::zero` / `CatalogVersion(0)`), so the whole body
/// lowerers to the proof backend.
///
/// Contract: the seed state satisfies the phase invariant (empty pending
/// effects, no outcome, no suspension — the `Initializing` domain).
fn RunState::initial_core(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
  transcript~ : @kernel.Transcript,
) -> RunState where {
  proof_ensure: result => phase_inv(result),
} {
  RunState::mk_core(
    run_id,
    session_id,
    budget,
    Initializing,
    transcript,
    [],
    EventSequence::initial(),
    EffectId::first(),
    ModelStepId::first(),
    CatalogVersion(0),
    BudgetConsumed::zero(),
    None,
    [],
    None,
  )
}

///|
/// Pure construction core: build a RunState directly from `FixedArray`
/// fields, POSITIONALLY (contracted bodies may only make positional calls,
/// so the label-free parameter order — mirroring the struct field order
/// exactly — is part of this seam). No raise, no validation: the caller
/// supplies phase-consistent fields and the constructor law below turns
/// them into `phase_inv` of the result, plus a faithful move of the
/// budget-consumption snapshot. All raising entry points
/// (`initial`/`transition`/`with_tool_results`) go through the pure cores
/// and run `validate` defensively.
fn RunState::mk_core(
  run_id : RunId,
  session_id : SessionId,
  budget : Budget,
  phase : Phase,
  transcript : @kernel.Transcript,
  pending_effects : FixedArray[Effect],
  next_event_sequence : EventSequence,
  next_effect_id : EffectId,
  current_model_step_id : ModelStepId,
  catalog_version : CatalogVersion,
  budget_consumed : BudgetConsumed,
  outcome : RunOutcome?,
  tool_results : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)],
  suspension_requirement : SuspensionRequirement?,
) -> RunState where {
  proof_require: phase_fields_ok(
    phase, pending_effects, outcome, suspension_requirement,
  ),
  proof_ensure: result => {
    phase_inv(result) && consumed_eq(result.budget_consumed, budget_consumed)
  },
} {
  {
    run_id,
    session_id,
    budget,
    phase,
    transcript,
    pending_effects,
    next_event_sequence,
    next_effect_id,
    current_model_step_id,
    catalog_version,
    budget_consumed,
    outcome,
    tool_results,
    suspension_requirement,
  }
}

///|
/// Check phase/pending/outcome invariants (ADR §2.2). Raises `KernelError::ConstructorInvariant` on violation.
fn RunState::validate(self : RunState) -> RunState raise KernelError {
  match self.phase {
    Initializing => {
      if !self.pending_effects.is_empty() {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Initializing",
            detail="pending effects must be empty",
          ),
        )
      }
      if self.outcome is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Initializing",
            detail="outcome must be None",
          ),
        )
      }
    }
    ReadyForModel => {
      if !self.pending_effects.is_empty() {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="ReadyForModel",
            detail="pending effects must be empty",
          ),
        )
      }
      if self.outcome is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="ReadyForModel",
            detail="outcome must be None",
          ),
        )
      }
    }
    AwaitingModel => {
      let model_count = count_call_model(self.pending_effects)
      if model_count != 1 {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="AwaitingModel",
            detail="expected exactly 1 pending CallModel effect, found \{model_count}",
          ),
        )
      }
      if self.outcome is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="AwaitingModel",
            detail="outcome must be None",
          ),
        )
      }
    }
    AwaitingTools => {
      let exec_count = count_execute_tool(self.pending_effects)
      if exec_count == 0 {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="AwaitingTools",
            detail="expected at least 1 pending ExecuteTool effect, found 0",
          ),
        )
      }
      if self.outcome is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="AwaitingTools",
            detail="outcome must be None",
          ),
        )
      }
    }
    Suspended => {
      if !self.pending_effects.is_empty() {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Suspended",
            detail="pending effects must be empty",
          ),
        )
      }
      if self.outcome is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Suspended",
            detail="outcome must be None (Suspended is not terminal)",
          ),
        )
      }
      if self.suspension_requirement is None {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Suspended",
            detail="suspension_requirement must be Some",
          ),
        )
      }
    }
    Terminal => {
      if !self.pending_effects.is_empty() {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Terminal",
            detail="pending effects must be empty",
          ),
        )
      }
      if self.outcome is None {
        raise ConstructorInvariant(
          category=IllegalPhase(phase="Terminal", detail="outcome must be Some"),
        )
      }
      if self.suspension_requirement is Some(_) {
        raise ConstructorInvariant(
          category=IllegalPhase(
            phase="Terminal",
            detail="suspension_requirement must be None at Terminal",
          ),
        )
      }
    }
  }
  self
}

///|
/// Count pending `CallModel` effects.
///
/// Contract: the runtime counter agrees with the logic-side prefix counter
/// `count_call_model_upto` (state_proof.mbtp) over the full array. The
/// functional loop carries `acc == count_call_model_upto(effects, i)` as
/// its invariant; `validate` (an uncontracted caller) keeps using this as
/// its phase-domain check. (Body patterns use explicit `label = _`
/// wildcards — the proof frontend rejects `..` rest patterns inside
/// contracted function bodies.)
fn count_call_model(
  effects : FixedArray[Effect],
) -> Int where {
  proof_ensure: result => {
    result == count_call_model_upto(effects, effects.length())
  },
} {
  for i = 0, acc = 0; i < effects.length(); {
    match effects[i] {
      CallModel(effect_id=_, payload=_) => continue i + 1, acc + 1
      _ => continue i + 1, acc
    }
  } nobreak {
    acc
  } where {
    proof_invariant: 0 <= i,
    proof_invariant: i <= effects.length(),
    proof_invariant: acc == count_call_model_upto(effects, i),
    proof_yield: res => res == count_call_model_upto(effects, effects.length()),
  }
}

///|
/// Count pending `ExecuteTool` effects.
///
/// Contract: the runtime counter agrees with the logic-side prefix counter
/// `count_execute_tool_upto` over the full array.
fn count_execute_tool(
  effects : FixedArray[Effect],
) -> Int where {
  proof_ensure: result => {
    result == count_execute_tool_upto(effects, effects.length())
  },
} {
  for i = 0, acc = 0; i < effects.length(); {
    match effects[i] {
      ExecuteTool(effect_id=_, payload=_) => continue i + 1, acc + 1
      _ => continue i + 1, acc
    }
  } nobreak {
    acc
  } where {
    proof_invariant: 0 <= i,
    proof_invariant: i <= effects.length(),
    proof_invariant: acc == count_execute_tool_upto(effects, i),
    proof_yield: res => {
      res == count_execute_tool_upto(effects, effects.length())
    },
  }
}

///|
pub fn RunState::run_id(self : RunState) -> RunId {
  self.run_id
}

///|
pub fn RunState::session_id(self : RunState) -> SessionId {
  self.session_id
}

///|
pub fn RunState::phase(self : RunState) -> Phase {
  self.phase
}

///|
pub fn RunState::transcript(self : RunState) -> @kernel.Transcript {
  self.transcript
}

///|
pub fn RunState::pending_effects(self : RunState) -> Array[Effect] {
  Array::from_iter(self.pending_effects.iter())
}

///|
/// Internal read-only snapshot of the tool-result ledger as an `Array`.
/// `tool_results` stays `FixedArray` internally (proof representation);
/// reducer-side builders keep working on `Array` and convert at this boundary.
fn RunState::tool_results_snapshot(
  self : RunState,
) -> Array[(@kernel.CallId, @kernel.ToolOutcome)] {
  Array::from_iter(self.tool_results.iter())
}

///|
pub fn RunState::next_event_sequence(self : RunState) -> EventSequence {
  self.next_event_sequence
}

///|
pub fn RunState::next_effect_id(self : RunState) -> EffectId {
  self.next_effect_id
}

///|
pub fn RunState::current_model_step_id(self : RunState) -> ModelStepId {
  self.current_model_step_id
}

///|
pub fn RunState::catalog_version(self : RunState) -> CatalogVersion {
  self.catalog_version
}

///|
pub fn RunState::budget_consumed(self : RunState) -> BudgetConsumed {
  self.budget_consumed
}

///|
pub fn RunState::outcome(self : RunState) -> RunOutcome? {
  self.outcome
}

///|
pub fn RunState::suspension_requirement(
  self : RunState,
) -> SuspensionRequirement? {
  self.suspension_requirement
}

///|
pub fn RunState::budget(self : RunState) -> Budget {
  self.budget
}

///|
pub impl Show for RunState with fn to_string(self : RunState) -> String {
  let outcome_str = match self.outcome {
    Some(o) => o.to_string()
    None => "None"
  }
  let req_str = match self.suspension_requirement {
    Some(r) => r.kind
    None => "None"
  }
  "RunState(run=\{self.run_id.to_string()}, phase=\{self.phase.to_string()}, messages=\{self.transcript.length()}, pending=\{self.pending_effects.length()}, seq=\{self.next_event_sequence.to_int()}, outcome=\{outcome_str}, suspended_req=\{req_str})"
}

///|
/// Produce the next state from raw fields, running invariants.
/// Exposed at package level for the reducer.
/// Thin raising wrapper over `transition_core`: the
/// `Array` boundary converts to `FixedArray` exactly once here, and
/// `tool_results` moves into the next state as the same `FixedArray`.
/// `validate` stays as the defensive bottom layer.
pub fn RunState::transition(
  self : RunState,
  phase~ : Phase,
  transcript~ : @kernel.Transcript,
  pending_effects~ : Array[Effect],
  next_event_sequence~ : EventSequence,
  next_effect_id~ : EffectId,
  current_model_step_id~ : ModelStepId,
  catalog_version~ : CatalogVersion?,
  budget_consumed~ : BudgetConsumed,
  outcome~ : RunOutcome?,
  suspension_requirement~ : SuspensionRequirement?,
) -> RunState raise KernelError {
  RunState::transition_core(
    self,
    phase~,
    transcript~,
    pending_effects=FixedArray::from_array(pending_effects),
    next_event_sequence~,
    next_effect_id~,
    current_model_step_id~,
    catalog_version~,
    budget_consumed~,
    outcome~,
    suspension_requirement~,
  ).validate()
}

///|
/// Pure core of `transition`: reassemble the state from explicit
/// next-step fields while carrying `run_id`/`session_id`/`budget` and the
/// tool-result ledger over from `self` unchanged.
///
/// Contract: given a phase-invariant `self`, phase-consistent next fields
/// (`phase_fields_ok`) and non-decreasing consumption
/// (`consumed_le`), the result satisfies `phase_inv` and is
/// budget-monotone (`budget_monotone`) — the constructive preservation
/// law that lets runtime `validate` degrade to a defensive layer.
fn RunState::transition_core(
  self : RunState,
  phase~ : Phase,
  transcript~ : @kernel.Transcript,
  pending_effects~ : FixedArray[Effect],
  next_event_sequence~ : EventSequence,
  next_effect_id~ : EffectId,
  current_model_step_id~ : ModelStepId,
  catalog_version~ : CatalogVersion?,
  budget_consumed~ : BudgetConsumed,
  outcome~ : RunOutcome?,
  suspension_requirement~ : SuspensionRequirement?,
) -> RunState where {
  proof_require: phase_inv(self) &&
  phase_fields_ok(phase, pending_effects, outcome, suspension_requirement) &&
  consumed_le(self.budget_consumed, budget_consumed),
  proof_ensure: result => phase_inv(result) && budget_monotone(self, result),
} {
  let cv = match catalog_version {
    Some(v) => v
    None => self.catalog_version
  }
  RunState::mk_core(
    self.run_id,
    self.session_id,
    self.budget,
    phase,
    transcript,
    pending_effects,
    next_event_sequence,
    next_effect_id,
    current_model_step_id,
    cv,
    budget_consumed,
    outcome,
    self.tool_results,
    suspension_requirement,
  )
}

///|
/// Replace the run-local tool-result ledger while preserving other state fields.
/// Thin raising wrapper over `with_tool_results_core`: the
/// `Array` boundary converts once; every other field — including the
/// pending-effects `FixedArray` — moves without copying.
fn RunState::with_tool_results(
  self : RunState,
  tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
) -> RunState raise KernelError {
  RunState::with_tool_results_core(self, FixedArray::from_array(tool_results)).validate()
}

///|
/// Pure core of `with_tool_results`: same phase domain, fresh ledger.
/// The tool-result ledger is not part of `phase_inv`, so preserving every
/// phase-relevant field verbatim preserves the invariant.
fn RunState::with_tool_results_core(
  self : RunState,
  tool_results : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)],
) -> RunState where {
  proof_require: phase_inv(self),
  proof_ensure: result => phase_inv(result),
} {
  RunState::mk_core(
    self.run_id,
    self.session_id,
    self.budget,
    self.phase,
    self.transcript,
    self.pending_effects,
    self.next_event_sequence,
    self.next_effect_id,
    self.current_model_step_id,
    self.catalog_version,
    self.budget_consumed,
    self.outcome,
    tool_results,
    self.suspension_requirement,
  )
}
