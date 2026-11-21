///|

///|
#derive(Eq, Debug)
pub(all) enum Phase {
  Initializing
  ReadyForModel
  AwaitingModel
  AwaitingTools
  Suspended
  Terminal
}

///|
pub extend Phase with Eq::{not_equal, equal}

///|
pub extend Phase with Debug::{to_repr}

///|
pub extend Phase with Show::{output}

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
/// Terminal outcome of a Run. Exactly one per Run.
#derive(Eq, Debug)
pub(all) enum RunOutcome {
  Completed(
    final_message~ : @kernel.Message,
    tool_results~ : FixedArray[@kernel.ToolOutcome],
  )
  Failed(reason~ : FailureReason)
  Cancelled(reason~ : CancelReason)
}

///|
pub extend RunOutcome with Eq::{not_equal, equal}

///|
pub extend RunOutcome with Debug::{to_repr}

///|
pub extend RunOutcome with Show::{output}

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
#derive(Eq, Debug)
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
  /// Staging buffer for tool outcomes that have completed within the current
  /// wave but are not yet committed to the transcript. Cleared at every wave
  /// boundary and phase change that leaves `AwaitingTools`.
  completed_tool_results : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int32),
  ]
  /// Incremental ledger mapping call id to its stable source position among
  /// all assistant messages in the transcript. Built when a tool batch is
  /// declared and rebuilt if a rewrite happens while awaiting tools.
  tool_call_positions : Map[String, Int32]
  /// Suspension requirement. `None` outside `Suspended`.
  suspension_requirement : SuspensionRequirement?
}

///|
/// Construct the initial `Initializing` state. Accepts only `Start` input.
/// Thin raising wrapper over `initial_core`: everything
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
fn RunState::initial_core(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
  transcript~ : @kernel.Transcript,
) -> RunState {
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
    Map::from_array([]),
    Map::from_array([]),
    None,
  )
}

///|
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
  completed_tool_results : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int32),
  ],
  tool_call_positions : Map[String, Int32],
  suspension_requirement : SuspensionRequirement?,
) -> RunState {
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
    completed_tool_results,
    tool_call_positions,
    suspension_requirement,
  }
}

///|
fn to_proof_phase(phase : Phase) -> @proof_phase.Phase {
  match phase {
    Initializing => Initializing
    ReadyForModel => ReadyForModel
    AwaitingModel => AwaitingModel
    AwaitingTools => AwaitingTools
    Suspended => Suspended
    Terminal => Terminal
  }
}

///|
fn RunState::validate(self : RunState) -> RunState raise KernelError {
  let pending_model = count_call_model(self.pending_effects)
  let pending_tools = count_execute_tool(self.pending_effects)
  if self.pending_effects.length() != pending_model + pending_tools {
    raise constructor_illegal_phase(
      self.phase.to_string(),
      "unexpected non-model/non-tool pending effect",
    )
  }
  let proof_state : @proof_phase.PhaseState = {
    phase: to_proof_phase(self.phase),
    pending_model,
    pending_tools,
    has_outcome: self.outcome is Some(_),
    has_suspension: self.suspension_requirement is Some(_),
    model_step_id: if self.phase is Initializing {
      0
    } else {
      self.current_model_step_id.to_int()
    },
    event_seq: self.next_event_sequence.to_int(),
  }
  if !@proof_phase.check_phase_inv(proof_state) {
    raise constructor_illegal_phase(
      self.phase.to_string(),
      "phase invariant violated (pending_model=\{pending_model}, pending_tools=\{pending_tools})",
    )
  }
  self
}

///|
fn constructor_illegal_phase(phase : String, detail : String) -> KernelError {
  ConstructorInvariant(category=IllegalPhase(phase~, detail~))
}

///|
fn count_call_model(effects : FixedArray[Effect]) -> Int32 {
  let mut acc = 0
  for effect in effects {
    if effect is CallModel(..) {
      acc += 1
    }
  }
  acc
}

///|
fn count_execute_tool(effects : FixedArray[Effect]) -> Int32 {
  let mut acc = 0
  for effect in effects {
    if effect is ExecuteTool(..) {
      acc += 1
    }
  }
  acc
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
pub extend RunState with Show::{output}

///|
pub extend RunState with Eq::{not_equal, equal}

///|
pub extend RunState with Debug::{to_repr}

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
  transcript~ : @kernel.Transcript,
  pending_effects~ : Array[Effect],
  next_event_sequence~ : EventSequence,
  next_effect_id~ : EffectId,
  current_model_step_id~ : ModelStepId,
  catalog_version~ : CatalogVersion?,
  budget_consumed~ : BudgetConsumed,
  outcome~ : RunOutcome?,
  completed_tool_results~ : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int32),
  ] = self.completed_tool_results.copy(),
  tool_call_positions~ : Map[String, Int32] = self.tool_call_positions.copy(),
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
    completed_tool_results~,
    tool_call_positions~,
    suspension_requirement~,
  ).validate()
}

///|
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
  completed_tool_results~ : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int32),
  ],
  tool_call_positions~ : Map[String, Int32],
  suspension_requirement~ : SuspensionRequirement?,
) -> RunState {
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
    completed_tool_results,
    tool_call_positions,
    suspension_requirement,
  )
}

///|
fn RunState::with_tool_results(
  self : RunState,
  tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
) -> RunState raise KernelError {
  RunState::with_tool_results_core(
    self,
    FixedArray::from_array(tool_results),
    completed_tool_results=self.completed_tool_results.copy(),
    tool_call_positions=self.tool_call_positions.copy(),
  ).validate()
}

///|
fn RunState::with_tool_results_core(
  self : RunState,
  tool_results : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)],
  completed_tool_results~ : Map[
    String,
    (@kernel.ToolName, @kernel.ToolOutcome, Int32),
  ],
  tool_call_positions~ : Map[String, Int32],
) -> RunState {
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
    completed_tool_results,
    tool_call_positions,
    self.suspension_requirement,
  )
}
