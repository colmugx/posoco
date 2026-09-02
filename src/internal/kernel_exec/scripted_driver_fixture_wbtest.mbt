///|
/// Test-only reducer conformance fixture (white-box test scope, never
/// shipped). Mechanically drives `reduce → scripted outcome → reduce` so the
/// Kernel contract can be tested without an I/O adapter. Product runs are
/// driven only by `Puppet`; this loop exists solely for the golden suite in
/// `conformance_wbtest.mbt`.

///|
/// What the scripted executor returns for a given effect id.
pub(all) enum ScriptedOutcome {
  /// ModelCompleted with the supplied completion.
  ScriptedModelCompleted(@kernel.Completion)
  /// ModelFailed with the supplied failure.
  ScriptedModelFailed(@kernel.ModelFailure)
  /// ToolCompleted with the supplied outcome.
  ScriptedToolCompleted(@kernel.ToolOutcome)
  /// ToolFailed with runtime detail.
  ScriptedToolRuntime(@kernel.ModelFailure)
  /// ToolFailed with invariant category.
  ScriptedToolInvariant(InvariantCategory)
}

///|
/// A fake executor: returns scripted outcomes by effect id. Used by T09
/// golden tests so they don't need a real ModelPort / ToolProvider.
pub struct ScriptedExecutor {
  outcomes : Map[String, ScriptedOutcome]
}

///|
pub fn ScriptedExecutor::ScriptedExecutor() -> ScriptedExecutor {
  { outcomes: Map::from_array([]), }
}

///|
/// Configure the outcome for a specific effect id (string form). The
/// scripted driver looks up by effect_id.to_string().
pub fn ScriptedExecutor::on(
  self : ScriptedExecutor,
  effect_id : EffectId,
  outcome : ScriptedOutcome,
) -> ScriptedExecutor {
  self.outcomes[effect_id.to_string()] = outcome
  self
}

///|
/// Look up the scripted outcome for an effect. Returns the configured
/// outcome or a default invariant failure.
pub fn ScriptedExecutor::lookup(
  self : ScriptedExecutor,
  effect_id : EffectId,
) -> ScriptedOutcome {
  match self.outcomes.get(effect_id.to_string()) {
    Some(o) => o
    None => ScriptedToolInvariant(StaleCorrelation(effect_id~))
  }
}

///|
/// Single step in the driver's mechanical execution log for conformance goldens.
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

///|
/// Drive a Run mechanically using the scripted executor: reduce(Start),
/// then loop over declared effects, feeding scripted outcomes back to
/// reduce until Terminal. Returns `DriverTrace` with steps, events,
/// and final state. `max_iterations` is a safety guard.
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
  while state.phase() != Terminal && iter < max_iterations {
    iter = iter + 1
    if state.phase() == ReadyForModel {
      let out_step = run_model_step(state, catalog, Json::null())
      state = out_step.next_state()
      for e in out_step.events() {
        events.push(e)
      }
      for eff in out_step.effects() {
        let input = input_for_effect(scripted, eff, steps)
        let out_reduce = reduce(state, catalog, input)
        state = out_reduce.next_state()
        for e in out_reduce.events() {
          events.push(e)
        }
      }
    } else if state.phase() == AwaitingModel || state.phase() == AwaitingTools {
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
      break
    }
  }
  { steps, events, final_state: state, }
}

///|
/// Build a RunInput from a scripted outcome for a given effect.
fn input_for_effect(
  scripted : ScriptedExecutor,
  eff : Effect,
  steps : Array[DriverStep],
) -> RunInput {
  let outcome = scripted.lookup(eff.effect_id())
  let (input, effect_kind, input_kind) = match (eff, outcome) {
    (CallModel(effect_id~, payload~), ScriptedModelCompleted(completion)) =>
      (
        ModelCompleted(payload={
          effect_id,
          model_step_id: payload.model_step_id,
          completion,
          processed_messages: Array::from_iter(payload.messages.iter()),
        }),
        "CallModel",
        "ModelCompleted",
      )
    (CallModel(effect_id~, payload~), ScriptedModelFailed(failure)) =>
      (
        ModelFailed(payload={
          effect_id,
          model_step_id: payload.model_step_id,
          failure,
        }),
        "CallModel",
        "ModelFailed",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolCompleted(outcome)) =>
      (
        ToolCompleted(payload={
          effect_id,
          call_id: payload.call_id,
          tool_name: payload.tool_name,
          arguments: payload.arguments,
          outcome,
        }),
        "ExecuteTool",
        "ToolCompleted",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolRuntime(failure)) =>
      (
        ToolFailed(payload={
          effect_id,
          call_id: payload.call_id,
          tool_name: payload.tool_name,
          arguments: payload.arguments,
          reason: "scripted runtime: " + failure.to_string(),
          runtime: Some(failure),
          invariant_failure: None,
        }),
        "ExecuteTool",
        "ToolFailed(runtime)",
      )
    (ExecuteTool(effect_id~, payload~), ScriptedToolInvariant(cat)) =>
      (
        ToolFailed(payload={
          effect_id,
          call_id: payload.call_id,
          tool_name: payload.tool_name,
          arguments: payload.arguments,
          reason: "scripted invariant: " + cat.to_string(),
          runtime: None,
          invariant_failure: Some(cat),
        }),
        "ExecuteTool",
        "ToolFailed(invariant)",
      )
    (CancelOutstanding(..), _) =>
      // CancelOutstanding is fire-and-forget; the reducer already terminalised.
      (
        ToolCompleted(payload={
          effect_id: EffectId::first(),
          call_id: @kernel.CallId::unchecked("__cancel_ack__"),
          tool_name: @kernel.ToolName::unchecked("__cancel__"),
          arguments: Json::null(),
          outcome: RuntimeFailure(
            error_category="CancelAck",
            message="cancel recorded",
          ),
        }),
        "CancelOutstanding",
        "ToolCompleted(cancel-ack)",
      )
    // Mismatched effect/outcome combinations: treat as invariant failure.
    (CallModel(effect_id~, payload~), _) =>
      (
        ModelFailed(payload={
          effect_id,
          model_step_id: payload.model_step_id,
          failure: Runtime(reason="scripted outcome mismatch for CallModel"),
        }),
        "CallModel",
        "ModelFailed(mismatch)",
      )
    (ExecuteTool(effect_id~, payload~), _) =>
      (
        ToolFailed(payload={
          effect_id,
          call_id: payload.call_id,
          tool_name: payload.tool_name,
          arguments: payload.arguments,
          reason: "scripted outcome mismatch",
          runtime: None,
          invariant_failure: Some(StaleCorrelation(effect_id~)),
        }),
        "ExecuteTool",
        "ToolFailed(mismatch)",
      )
  }
  steps.push({ effect_id: eff.effect_id(), effect_kind, input_kind, })
  input
}
