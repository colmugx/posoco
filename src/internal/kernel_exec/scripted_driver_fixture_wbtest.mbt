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
pub extend DriverStep with Eq::{not_equal, equal}

///|
pub extend DriverStep with Debug::{to_repr}

///|
pub extend DriverStep with Show::{to_string, output}

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
pub extend DriverTrace with Debug::{to_repr}

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

// ──────────────────────────────────────────────────────────────────────────
// Dead-branch coverage. input_for_effect has two arms that no golden test
// reaches: the CancelOutstanding ack arm and the (effect, outcome) kind-
// mismatch arms. The tests below drive all three.
// ──────────────────────────────────────────────────────────────────────────

///|
fn fixture_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  let _ = builder.add(
    ToolDef(
      name=@kernel.ToolName::unchecked("read"),
      description="read file",
      input_schema=Json::object(
        Map::from_array([("type", Json::string("object"))]),
      ),
      owner=@kernel.OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fixture"),
    ),
  )
  builder.finish(version=CatalogVersion(1))
}

///|
fn fixture_initial_state() -> RunState raise KernelError {
  RunState::initial(
    run_id=RunId::unchecked("fixture_run"),
    session_id=SessionId::unchecked("fixture_sess"),
    budget=Budget::default_run(),
  )
}

///|
fn fixture_start() -> StartPayload {
  { initial_messages: [], catalog_version: CatalogVersion(1), }
}

///|
test "FIXTURE-MISMATCH-CALL-MODEL: CallModel effect scripted with a tool outcome → ModelFailed(mismatch) terminal" {
  let catalog = fixture_catalog()
  let st0 = fixture_initial_state()
  // The run's first effect is a CallModel; scripting a TOOL outcome for it
  // makes input_for_effect fall into the CallModel mismatch arm.
  let scripted = ScriptedExecutor().on(
    EffectId::first(),
    ScriptedToolCompleted(Success(content="irrelevant", structured=None)),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, fixture_start(), 20)
  // The driver step log records the mismatch arm verbatim.
  let steps = trace.steps()
  assert_eq(steps.length(), 1)
  assert_eq(steps[0].effect_kind, "CallModel")
  assert_eq(steps[0].input_kind, "ModelFailed(mismatch)")
  // The mismatch input is a Runtime ModelFailure → Terminal(Failed).
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Failed(reason=ModelRuntime(detail~))) =>
      assert_eq(detail, "scripted outcome mismatch for CallModel")
    _ => fail("expected Failed(ModelRuntime) from the mismatch branch")
  }
}

///|
test "FIXTURE-MISMATCH-EXECUTE-TOOL: ExecuteTool effect scripted with a model outcome → StaleCorrelation terminal" {
  let catalog = fixture_catalog()
  let st0 = fixture_initial_state()
  let scripted = ScriptedExecutor()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(completion_with_tool_call_read("/x")),
    )
    .on(
      // The resulting ExecuteTool effect (id 2) is scripted with a MODEL
      // outcome — kind mismatch → ToolFailed(invariant=StaleCorrelation).
      EffectId::first().next(),
      ScriptedModelCompleted(
        Completion(
          content=[Text("wrong kind")],
          tool_calls=[],
          reasoning=None,
          finish_reason=Stop,
          usage=None,
        ),
      ),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, fixture_start(), 30)
  let steps = trace.steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps[0].effect_kind, "CallModel")
  assert_eq(steps[0].input_kind, "ModelCompleted")
  assert_eq(steps[1].effect_kind, "ExecuteTool")
  assert_eq(steps[1].input_kind, "ToolFailed(mismatch)")
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(effect_id~) =>
          assert_eq(effect_id, EffectId::first().next())
        _ => fail("expected StaleCorrelation, got \{category.to_string()}")
      }
    _ => fail("expected Failed(InvariantViolation(StaleCorrelation))")
  }
}

///|
fn completion_with_tool_call_read(path : String) -> @kernel.Completion {
  Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("c1"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string(path))])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
test "FIXTURE-CANCEL-ACK: CancelOutstanding effect maps to the fire-and-forget cancel-ack ToolCompleted" {
  // scripted_driver_run can never reach the CancelOutstanding arm: the
  // driver never issues CancelRequested (cancel is a host-driven input, not
  // something the scripted loop produces), and when a host-driven cancel
  // terminalises the Run the driver's `while phase != Terminal` loop exits
  // before any declared CancelOutstanding effect would be consumed. The arm
  // is therefore driven directly through input_for_effect.
  let steps : Array[DriverStep] = []
  let cancel_effect : Effect = CancelOutstanding(effect_id=EffectId::first(), payload={
    effect_ids: FixedArray::from_array([]),
    reason: HostRequested(detail=None),
  })
  let input = input_for_effect(ScriptedExecutor(), cancel_effect, steps)
  // The step log pins the arm's labels.
  assert_eq(steps.length(), 1)
  assert_eq(steps[0].effect_kind, "CancelOutstanding")
  assert_eq(steps[0].input_kind, "ToolCompleted(cancel-ack)")
  // The fire-and-forget ack input: a synthetic ToolCompleted that the
  // reducer never folds (the Run is already Terminal by then).
  match input {
    ToolCompleted(payload~) => {
      assert_eq(payload.effect_id, EffectId::first())
      assert_eq(payload.call_id.to_string(), "__cancel_ack__")
      assert_eq(payload.tool_name.to_string(), "__cancel__")
      assert_true(payload.arguments is Json::Null)
      match payload.outcome {
        RuntimeFailure(error_category~, message~) => {
          assert_eq(error_category, "CancelAck")
          assert_eq(message, "cancel recorded")
        }
        _ => fail("expected RuntimeFailure cancel ack outcome")
      }
    }
    _ => fail("expected a ToolCompleted cancel-ack input")
  }
}
