///|
/// Test-only reducer conformance fixture.
///
/// This file is compiled only for white-box tests. It mechanically drives
/// `reduce → scripted outcome → reduce` so the Kernel contract can be tested
/// without an I/O adapter. Product runs are driven only by `Puppet`.
///
/// Two variants:
/// - `ScriptedExecutor`: a fake registry that returns scripted outcomes by
///   effect id. Used by conformance tests (T09) and the reducer end-to-end
///   golden suite.
/// - `scripted_driver_run`: the mechanical pump. Given an initial state,
///   catalog and a scripted executor, drive the run to terminal.
///
/// Mechanical contract (verified by boundary lint):
/// - The driver loops ONLY over reducer-declared effects. It never looks at
///   `response.tool_calls` to decide the next phase.
/// - It owns no queue, no savepoint, no journal, no subscriber barrier.
/// - Each loop iteration: (a) collect reducer-declared effects, (b) execute
///   each via the scripted/real executor, (c) feed the resulting Input back
///   to the reducer. If the reducer declares zero new effects and is not
///   terminal, the host must explicitly call `run_model_step` to advance —
///   the driver does NOT decide to advance on its own.

// ──────────────────────────────────────────────────────────────────────────
// ScriptedExecutor — fake registry + scripted outcomes
// ──────────────────────────────────────────────────────────────────────────

///|
/// What the test fixture returns for a given effect id.
pub(all) enum ScriptedOutcome {
  /// ModelCompleted with the supplied completion.
  ScriptedModelCompleted(AssistantCompletion)
  /// ModelFailed with the supplied failure.
  ScriptedModelFailed(ModelFailure)
  /// ToolCompleted with the supplied outcome.
  ScriptedToolCompleted(ToolOutcome)
  /// ToolFailed with runtime detail.
  ScriptedToolRuntime(ModelFailure)
  /// ToolFailed with invariant category (simulates registry invariant
  /// failure reaching the reducer).
  ScriptedToolInvariant(InvariantCategory)
}

///|
/// Test-only outcome registry keyed by effect id.
pub struct ScriptedExecutor {
  outcomes : Map[String, ScriptedOutcome]
}

///|
pub fn ScriptedExecutor::ScriptedExecutor() -> ScriptedExecutor {
  { outcomes: Map::from_array([]) }
}

///|
/// Configure the outcome for a specific effect id (string form). The
/// fixture looks up by effect_id.to_string().
pub fn ScriptedExecutor::on(
  self : ScriptedExecutor,
  effect_id : EffectId,
  outcome : ScriptedOutcome,
) -> ScriptedExecutor {
  self.outcomes[effect_id.to_string()] = outcome
  self
}

///|
/// Look up the configured outcome for an effect. A missing entry is a test
/// setup failure; it must never be turned into a synthetic runtime result.
pub fn ScriptedExecutor::lookup(
  self : ScriptedExecutor,
  effect_id : EffectId,
) -> ScriptedOutcome raise KernelError {
  match self.outcomes.get(effect_id.to_string()) {
    Some(o) => o
    None =>
      raise IllegalTransition(
        run_id=RunId::unchecked("__scripted_fixture__"),
        phase="fixture",
        input_kind="lookup",
        detail="missing scripted outcome for effect " + effect_id.to_string(),
      )
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Driver trace record (for conformance goldens)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Single step in the driver's mechanical execution log. Used by T09
/// goldens to assert ordering and content without exposing payloads.
pub(all) struct DriverStep {
  effect_id : EffectId
  effect_kind : String
  input_kind : String
} derive(Eq, Debug)

///|
pub impl Show for DriverStep with fn to_string(self : DriverStep) -> String {
  "DriverStep(\{self.effect_kind} \{self.effect_id.to_int()} → \{self.input_kind})"
}

///|
pub(all) struct DriverTrace {
  steps : Array[DriverStep]
  events : Array[KernelEvent]
  final_state : RunState
} derive(Debug)

///|
pub fn DriverTrace::steps(self : DriverTrace) -> Array[DriverStep] {
  self.steps.copy()
}

///|
pub fn DriverTrace::events(self : DriverTrace) -> Array[KernelEvent] {
  self.events.copy()
}

///|
pub fn DriverTrace::final_state(self : DriverTrace) -> RunState {
  self.final_state
}

// ──────────────────────────────────────────────────────────────────────────
// Mechanical scripted driver
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a Run mechanically using the scripted fixture. The driver:
/// 1. Calls `reduce(state, catalog, Start)` to seed the run.
/// 2. Repeats until state is Terminal OR no further model step is requested:
///    a. If state is ReadyForModel, call `run_model_step` to declare a
///       CallModel effect.
///    b. For each declared effect, look up the scripted outcome and feed
///       the resulting Input back to `reduce`.
/// 3. Returns a `DriverTrace` with steps, events and the final state.
///
/// `max_iterations` is a safety guard: if the run does not terminate, the
/// driver aborts by returning the last state.
pub fn scripted_driver_run(
  initial_state : RunState,
  catalog : ToolCatalogSnapshot,
  scripted : ScriptedExecutor,
  start : StartPayload,
  max_iterations : Int,
) -> DriverTrace raise KernelError {
  let start_input : RunInput = Start(payload=start)
  let out0 = reduce(initial_state, catalog, start_input)
  let mut state = out0.next_state()
  let events : Array[KernelEvent] = []
  for e in out0.events() {
    events.push(e)
  }
  let steps : Array[DriverStep] = []
  let mut iter = 0
  // Drive: while state is not Terminal and iterations remain.
  while state.phase() != Terminal && iter < max_iterations {
    iter = iter + 1
    // If ReadyForModel, the host must request the next model step.
    if state.phase() == ReadyForModel {
      let out_step = run_model_step(state, catalog, Json::null())
      state = out_step.next_state()
      for e in out_step.events() {
        events.push(e)
      }
      // Collect declared effects (just CallModel here).
      for eff in out_step.effects() {
        let input = input_for_effect(scripted, eff, steps)
        let out_reduce = reduce(state, catalog, input)
        state = out_reduce.next_state()
        for e in out_reduce.events() {
          events.push(e)
        }
      }
    } else if state.phase() == AwaitingModel || state.phase() == AwaitingTools {
      // Process each pending effect.
      let pending = state.pending_effects()
      for eff in pending {
        let input = input_for_effect(scripted, eff, steps)
        let out_reduce = reduce(state, catalog, input)
        state = out_reduce.next_state()
        for e in out_reduce.events() {
          events.push(e)
        }
      }
    } else {
      // Suspended or unknown: stop.
      break
    }
  }
  { steps, events, final_state: state }
}

///|
/// Build a RunInput from a scripted outcome for a given effect.
fn input_for_effect(
  scripted : ScriptedExecutor,
  eff : Effect,
  steps : Array[DriverStep],
) -> RunInput raise KernelError {
  let outcome = scripted.lookup(eff.effect_id())
  let (input, effect_kind, input_kind) = match (eff, outcome) {
    (CallModel(effect_id~, payload~), ScriptedModelCompleted(completion)) =>
      (
        @kernel.ModelCompleted(payload=ModelCompletedPayload::{
          effect_id,
          model_step_id: payload.model_step_id,
          completion,
        }),
        "CallModel",
        "ModelCompleted",
      )
    (CallModel(effect_id~, payload~), ScriptedModelFailed(failure)) =>
      (
        @kernel.ModelFailed(payload=ModelFailedPayload::{
          effect_id,
          model_step_id: payload.model_step_id,
          failure,
        }),
        "CallModel",
        "ModelFailed",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolCompleted(outcome)) =>
      (
        @kernel.ToolCompleted(payload=ToolCompletedPayload::{
          effect_id,
          call_id: payload.call_id,
          outcome,
        }),
        "ExecuteTool",
        "ToolCompleted",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolRuntime(failure)) =>
      (
        @kernel.ToolFailed(payload=ToolFailedPayload::{
          effect_id,
          call_id: payload.call_id,
          runtime: Some(failure),
          invariant_failure: None,
        }),
        "ExecuteTool",
        "ToolFailed(runtime)",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolInvariant(cat)) =>
      (
        @kernel.ToolFailed(payload=ToolFailedPayload::{
          effect_id,
          call_id: payload.call_id,
          runtime: None,
          invariant_failure: Some(cat),
        }),
        "ExecuteTool",
        "ToolFailed(invariant)",
      )
    (CancelOutstanding(effect_id~, ..), _) =>
      raise IllegalTransition(
        run_id=RunId::unchecked("__scripted_fixture__"),
        phase="fixture",
        input_kind="CancelOutstanding",
        detail="terminal cancellation effect must not be executed by the scripted fixture: " +
          effect_id.to_string(),
      )
    (CallModel(effect_id~, ..), _) =>
      raise IllegalTransition(
        run_id=RunId::unchecked("__scripted_fixture__"),
        phase="fixture",
        input_kind="CallModel",
        detail="scripted outcome does not match effect " + effect_id.to_string(),
      )
    (ExecuteTool(effect_id~, ..), _) =>
      raise IllegalTransition(
        run_id=RunId::unchecked("__scripted_fixture__"),
        phase="fixture",
        input_kind="ExecuteTool",
        detail="scripted outcome does not match effect " + effect_id.to_string(),
      )
  }
  steps.push({ effect_id: eff.effect_id(), effect_kind, input_kind })
  input
}
