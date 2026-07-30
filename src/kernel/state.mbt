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
  Completed(final_message~ : Message, tool_results~ : Array[ToolOutcome])
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
  transcript : Transcript
  /// Pending effects. Length is phase-dependent.
  pending_effects : Array[Effect]
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
  tool_results : Array[(CallId, ToolOutcome)]
  /// Suspension requirement. `None` outside `Suspended`.
  suspension_requirement : SuspensionRequirement?
} derive(Eq, Debug)

///|
/// Construct the initial `Initializing` state. Accepts only `Start` input.
pub fn RunState::initial(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
) -> RunState raise KernelError {
  let st : RunState = {
    run_id,
    session_id,
    budget,
    phase: Initializing,
    transcript: Transcript::empty(),
    pending_effects: [],
    next_event_sequence: EventSequence::initial(),
    next_effect_id: EffectId::first(),
    current_model_step_id: ModelStepId::first(),
    catalog_version: CatalogVersion(0),
    budget_consumed: BudgetConsumed::zero(),
    outcome: None,
    tool_results: [],
    suspension_requirement: None,
  }
  st.validate()
}

///|
/// Internal: build a RunState from raw fields and run invariants.
fn RunState::mk(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
  phase~ : Phase,
  transcript~ : Transcript,
  pending_effects~ : Array[Effect],
  next_event_sequence~ : EventSequence,
  next_effect_id~ : EffectId,
  current_model_step_id~ : ModelStepId,
  catalog_version~ : CatalogVersion,
  budget_consumed~ : BudgetConsumed,
  outcome~ : RunOutcome?,
  tool_results~ : Array[(CallId, ToolOutcome)],
  suspension_requirement~ : SuspensionRequirement?,
) -> RunState raise KernelError {
  let st : RunState = {
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
  st.validate()
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
fn count_call_model(effects : Array[Effect]) -> Int {
  let mut n = 0
  for e in effects {
    match e {
      CallModel(..) => n = n + 1
      _ => ()
    }
  }
  n
}

///|
fn count_execute_tool(effects : Array[Effect]) -> Int {
  let mut n = 0
  for e in effects {
    match e {
      ExecuteTool(..) => n = n + 1
      _ => ()
    }
  }
  n
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
pub fn RunState::transcript(self : RunState) -> Transcript {
  self.transcript
}

///|
pub fn RunState::pending_effects(self : RunState) -> Array[Effect] {
  self.pending_effects.copy()
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
pub fn RunState::transition(
  self : RunState,
  phase~ : Phase,
  transcript~ : Transcript,
  pending_effects~ : Array[Effect],
  next_event_sequence~ : EventSequence,
  next_effect_id~ : EffectId,
  current_model_step_id~ : ModelStepId,
  catalog_version~ : CatalogVersion?,
  budget_consumed~ : BudgetConsumed,
  outcome~ : RunOutcome?,
  suspension_requirement~ : SuspensionRequirement?,
) -> RunState raise KernelError {
  let cv = match catalog_version {
    Some(v) => v
    None => self.catalog_version
  }
  RunState::mk(
    run_id=self.run_id,
    session_id=self.session_id,
    budget=self.budget,
    phase~,
    transcript~,
    pending_effects~,
    next_event_sequence~,
    next_effect_id~,
    current_model_step_id~,
    catalog_version=cv,
    budget_consumed~,
    outcome~,
    tool_results=self.tool_results.copy(),
    suspension_requirement~,
  )
}

///|
/// Replace the run-local tool-result ledger while preserving other state fields.
fn RunState::with_tool_results(
  self : RunState,
  tool_results : Array[(CallId, ToolOutcome)],
) -> RunState raise KernelError {
  RunState::mk(
    run_id=self.run_id,
    session_id=self.session_id,
    budget=self.budget,
    phase=self.phase,
    transcript=self.transcript,
    pending_effects=self.pending_effects,
    next_event_sequence=self.next_event_sequence,
    next_effect_id=self.next_effect_id,
    current_model_step_id=self.current_model_step_id,
    catalog_version=self.catalog_version,
    budget_consumed=self.budget_consumed,
    outcome=self.outcome,
    tool_results=tool_results.copy(),
    suspension_requirement=self.suspension_requirement,
  )
}
