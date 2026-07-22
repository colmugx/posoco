///|
/// RunState — the single source of truth for a Run (ADR §2.2, §2.6).
///
/// The reducer is the ONLY writer of RunState. Every transition produces a
/// fresh RunState; the caller's input arrays/maps are never mutated.
///
/// Construction invariants (ADR §2.2):
/// - `Initializing` → no pending effects, no outcome, sequence starts at 0.
/// - `ReadyForModel` → zero pending effects.
/// - `AwaitingModel` → exactly one pending `CallModel` effect.
/// - `AwaitingTools` → at least one pending `ExecuteTool` effect.
/// - `Suspended` → zero pending effects, no terminal outcome.
/// - `Terminal` → zero pending effects, exactly one `RunOutcome`.
///
/// Phase type is `pub(all)` so conformance tests can pattern-match; the
/// constructors below enforce the invariants and are the only sanctioned way
/// to build a state.

// ──────────────────────────────────────────────────────────────────────────
// Phase
// ──────────────────────────────────────────────────────────────────────────

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

// ──────────────────────────────────────────────────────────────────────────
// RunOutcome (terminal only — Suspended is NOT an outcome)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Terminal outcome of a Run (ADR §2.3). Exactly one per Run; carried by
/// the Terminal phase.
pub(all) enum RunOutcome {
  Completed(
    final_message~ : CanonicalMessage,
    tool_results~ : Array[ToolOutcome]
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

// ──────────────────────────────────────────────────────────────────────────
// RunState
// ──────────────────────────────────────────────────────────────────────────

///|
/// The Run's full state. Field visibility is `priv` (no `pub(all)` on the
/// struct itself) so callers cannot construct illegal combinations; the
/// constructors below enforce invariants.
///
/// Note: MoonBit struct fields default to package-private, so within `src/`
/// tests can still read them via accessors. The constructors are the only
/// sanctioned way to produce a legal state.
pub struct RunState {
  /// Constant after construction (until Terminal). The same id survives
  /// Suspended/resume.
  run_id : RunId
  /// Constant after Start.
  session_id : SessionId
  /// Constant budget envelope.
  budget : Budget
  /// Current phase. Mutated by reducer only.
  phase : Phase
  /// Canonical transcript. Appended by reducer only.
  transcript : CanonicalTranscript
  /// Pending effects awaiting completion inputs. Length is phase-dependent
  /// (see invariants above).
  pending_effects : Array[Effect]
  /// Monotonic event sequence for the next emitted event.
  next_event_sequence : EventSequence
  /// Next effect id to allocate. Incremented by reducer.
  next_effect_id : EffectId
  /// Current model step id. Incremented by reducer when emitting CallModel.
  current_model_step_id : ModelStepId
  /// Catalog version in force. Set by Start; the reducer never changes it
  /// within a Run (dynamic refresh is M2).
  catalog_version : CatalogVersion
  /// Budget consumed so far.
  budget_consumed : BudgetConsumed
  /// Terminal outcome. `None` in every phase except `Terminal`.
  outcome : RunOutcome?
  /// Tool outcomes produced by this Run, kept separately from the full
  /// transcript so a terminal outcome never replays historical session
  /// messages as current-turn results.
  tool_results : Array[(CallId, ToolOutcome)]
  /// Requirement carried across the Suspended phase. `None` outside Suspended.
  suspension_requirement : SuspensionRequirement?
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Constructor: Initializing
// ──────────────────────────────────────────────────────────────────────────

///|
/// Construct the initial `Initializing` state. The reducer accepts exactly
/// one input against this state: `Start`. Any other input is a typed
/// rejection.
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
    transcript: CanonicalTranscript::empty(),
    pending_effects: [],
    next_event_sequence: EventSequence::initial(),
    next_effect_id: EffectId::first(),
    current_model_step_id: ModelStepId::first(),
    catalog_version: CatalogVersion::new(0),
    budget_consumed: BudgetConsumed::zero(),
    outcome: None,
    tool_results: [],
    suspension_requirement: None,
  }
  st.validate()
}

// ──────────────────────────────────────────────────────────────────────────
// Internal constructor used by reducer transitions
// ──────────────────────────────────────────────────────────────────────────

///|
/// Internal: build a RunState from raw fields and run invariants. The
/// reducer uses this after computing the next-state values; if invariants
/// fail, the function raises `KernelError::ConstructorInvariant`.
fn RunState::mk(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
  phase~ : Phase,
  transcript~ : CanonicalTranscript,
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

// ──────────────────────────────────────────────────────────────────────────
// Invariant validation
// ──────────────────────────────────────────────────────────────────────────

///|
/// Check phase/pending/outcome invariants (ADR §2.2). Raises
/// `KernelError::ConstructorInvariant` on violation. Returns `self` on
/// success so callers can chain.
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

// ──────────────────────────────────────────────────────────────────────────
// Accessors (read-only) — used by tests, executor, driver
// ──────────────────────────────────────────────────────────────────────────

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
pub fn RunState::transcript(self : RunState) -> CanonicalTranscript {
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

// ──────────────────────────────────────────────────────────────────────────
// Show (debug) — compact, payload-free
// ──────────────────────────────────────────────────────────────────────────

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

// ──────────────────────────────────────────────────────────────────────────
// Re-export constructors the reducer needs (so reducer only imports
// `RunState` and `KernelError`, not internal helpers)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Internal: produce the next state from raw fields, running invariants.
/// Exposed at package level so the reducer (in `kernel_reducer.mbt`) can use
/// it without re-implementing validation.
pub fn RunState::transition(
  self : RunState,
  phase~ : Phase,
  transcript~ : CanonicalTranscript,
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
/// Internal reducer helper: replace the run-local tool-result ledger while
/// preserving every other validated state field. The ledger is deliberately
/// not part of the public transition contract; callers can only change it
/// through reducer-owned code.
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
