///|
/// Whitebox tests for the M1-T02 Kernel contract types:
/// RunState, RunInput, Effect, KernelEvent, IDs, Budget.
///
/// These tests exercise the CONSTRUCTOR INVARIANTS only — they do NOT drive
/// the reducer (that is T03 / T09). Each test verifies that:
/// - a legal state can be built
/// - an illegal state combination raises KernelError::ConstructorInvariant
/// - the typed IDs and payload fields are accessible

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

fn make_call_model_effect(id : EffectId) -> Effect {
  let payload : CallModelPayload = {
    model_step_id: ModelStepId::first(),
    messages: [],
    catalog_version: CatalogVersion::new(1),
    call_options: Json::null(),
  }
  CallModel(effect_id=id, payload~)
}

///|
fn make_initial_state() -> RunState raise KernelError {
  RunState::initial(
    run_id=RunId::unchecked("run_1"),
    session_id=SessionId::unchecked("sess_1"),
    budget=Budget::default_run(),
  )
}

///|
/// Try a transition; return Ok(state) or Err(error).
fn try_transition(
  st : RunState,
  phase : Phase,
  pending : Array[Effect],
  outcome : RunOutcome?,
  suspension : SuspensionRequirement?,
) -> Result[RunState, KernelError] {
  try {
    let next = st.transition(
      phase~,
      transcript=CanonicalTranscript::empty(),
      pending_effects=pending,
      next_event_sequence=EventSequence::initial(),
      next_effect_id=EffectId::first(),
      current_model_step_id=ModelStepId::first(),
      catalog_version=None,
      budget_consumed=BudgetConsumed::zero(),
      outcome~,
      suspension_requirement=suspension,
    )
    Ok(next)
  } catch {
    e => Err(e)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// IDs
// ──────────────────────────────────────────────────────────────────────────

///|
test "CallId: rejects empty string" {
  let result = CallId::new("")
  match result {
    Err(msg) => assert_true(msg.contains("non-empty"))
    Ok(_) => fail("CallId::new(\"\") should reject")
  }
}

///|
test "CallId: accepts non-empty string" {
  let result = CallId::new("call_1")
  match result {
    Ok(id) => assert_eq(id.to_string(), "call_1")
    Err(_) => fail("CallId::new should accept non-empty")
  }
}

///|
test "ToolName: rejects empty string" {
  let result = ToolName::new("")
  match result {
    Err(_) => ()
    Ok(_) => fail("ToolName::new(\"\") should reject")
  }
}

///|
test "RunId: rejects empty string" {
  let result = RunId::new("")
  match result {
    Err(_) => ()
    Ok(_) => fail("RunId::new(\"\") should reject")
  }
}

///|
test "OwnerId: rejects empty string" {
  let result = OwnerId::new("")
  match result {
    Err(_) => ()
    Ok(_) => fail("OwnerId::new(\"\") should reject")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Initial state
// ──────────────────────────────────────────────────────────────────────────

///|
test "RunState::initial: produces Initializing state with zero pending" {
  let st = make_initial_state()
  assert_eq(st.phase(), Initializing)
  assert_eq(st.pending_effects().length(), 0)
  assert_true(st.outcome() is None)
  assert_true(st.suspension_requirement() is None)
  assert_eq(st.next_event_sequence().to_int(), 0)
  assert_eq(st.next_effect_id().to_int(), 1)
  assert_eq(st.transcript().length(), 0)
}

// ──────────────────────────────────────────────────────────────────────────
// Phase invariants via RunState::transition
// ──────────────────────────────────────────────────────────────────────────

///|
test "RunState: AwaitingModel accepts exactly 1 CallModel effect" {
  let st = make_initial_state()
  let eff = make_call_model_effect(EffectId::first())
  let result = try_transition(st, AwaitingModel, [eff], None, None)
  match result {
    Ok(ok) => assert_eq(ok.phase(), AwaitingModel)
    Err(_) => fail("AwaitingModel with 1 CallModel should be legal")
  }
}

///|
test "RunState: AwaitingModel rejects zero pending effects" {
  let st = make_initial_state()
  let result = try_transition(st, AwaitingModel, [], None, None)
  match result {
    Err(ConstructorInvariant(category~)) =>
      assert_true(category.to_string().contains("AwaitingModel"))
    _ => fail("expected ConstructorInvariant for AwaitingModel with 0 pending")
  }
}

///|
test "RunState: ReadyForModel rejects any pending effect" {
  let st = make_initial_state()
  let eff = make_call_model_effect(EffectId::first())
  let result = try_transition(st, ReadyForModel, [eff], None, None)
  match result {
    Err(ConstructorInvariant(category~)) =>
      assert_true(category.to_string().contains("ReadyForModel"))
    _ => fail("expected ConstructorInvariant for ReadyForModel with pending")
  }
}

///|
test "RunState: Suspended legal with zero pending + Some requirement" {
  let st = make_initial_state()
  let req : SuspensionRequirement = { kind: "approval", payload: Json::null() }
  let result = try_transition(st, Suspended, [], None, Some(req))
  match result {
    Ok(ok) => assert_eq(ok.phase(), Suspended)
    Err(_) => fail("Suspended with zero pending + Some(req) should be legal")
  }
}

///|
test "RunState: Suspended rejects Some outcome" {
  let st = make_initial_state()
  let req : SuspensionRequirement = { kind: "approval", payload: Json::null() }
  let result = try_transition(
    st,
    Suspended,
    [],
    Some(Failed(reason=DeadlineReached)),
    Some(req),
  )
  match result {
    Err(ConstructorInvariant(category~)) =>
      assert_true(category.to_string().contains("Suspended"))
    _ => fail("expected ConstructorInvariant: Suspended with outcome")
  }
}

///|
test "RunState: Terminal rejects None outcome" {
  let st = make_initial_state()
  let result = try_transition(st, Terminal, [], None, None)
  match result {
    Err(ConstructorInvariant(category~)) =>
      assert_true(category.to_string().contains("Terminal"))
    _ => fail("expected ConstructorInvariant: Terminal without outcome")
  }
}

///|
test "RunState: Terminal legal with Completed" {
  let st = make_initial_state()
  let final_msg = AssistantMessage(
    content=[Text("done")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
  let result = try_transition(
    st,
    Terminal,
    [],
    Some(Completed(final_message=final_msg, tool_results=[])),
    None,
  )
  match result {
    Ok(ok) => {
      assert_eq(ok.phase(), Terminal)
      match ok.outcome() {
        Some(Completed(..)) => ()
        _ => fail("expected Completed outcome")
      }
    }
    Err(_) => fail("Terminal with Completed should be legal")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Budget state
// ──────────────────────────────────────────────────────────────────────────

///|
test "BudgetConsumed: WithinBudget when no limit exceeded" {
  let consumed : BudgetConsumed = {
    model_steps: 10,
    tool_rounds: 5,
    tool_calls: 20,
    observed_total_tokens: 0,
    any_usage_verified: false,
  }
  let budget = Budget::default_run()
  let state = consumed.exceeded(budget)
  match state {
    WithinBudget => ()
    _ =>
      fail("expected WithinBudget when max_tool_rounds=Some(32) and consumed=5")
  }
}

///|
test "BudgetConsumed: Exceeded when tool_rounds hits limit" {
  let consumed : BudgetConsumed = {
    model_steps: 0,
    tool_rounds: 32,
    tool_calls: 0,
    observed_total_tokens: 0,
    any_usage_verified: false,
  }
  let budget = Budget::default_run() // max_tool_rounds=Some(32)
  let state = consumed.exceeded(budget)
  match state {
    Exceeded(ToolRounds) => ()
    _ => fail("expected Exceeded(ToolRounds)")
  }
}

///|
test "BudgetConsumed: UnknownUsage for tokens when no usage verified" {
  let consumed : BudgetConsumed = {
    model_steps: 0,
    tool_rounds: 0,
    tool_calls: 0,
    observed_total_tokens: 0,
    any_usage_verified: false,
  }
  let budget = Budget::bounded(
    max_model_steps=100,
    max_tool_rounds=10,
    max_tool_calls=50,
    max_total_tokens=1000,
  )
  let state = consumed.exceeded(budget)
  match state {
    UnknownUsage(TotalTokens) => ()
    _ => fail("expected UnknownUsage(TotalTokens), not \{state.to_string()}")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// RunInput kind labels (contract — string form must not drift)
// ──────────────────────────────────────────────────────────────────────────

///|
test "RunInput: kind labels are stable" {
  let start : RunInput = Start(payload=StartPayload::{
    initial_messages: [],
    catalog_version: CatalogVersion::new(1),
  })
  assert_eq(start.kind(), "Start")

  let cancel_input : RunInput = CancelRequested(payload=CancelRequestedPayload::{
    detail: None,
  })
  assert_eq(cancel_input.kind(), "CancelRequested")

  let resume_input : RunInput = Resume(payload=ResumePayload::{
    payload: Json::null(),
  })
  assert_eq(resume_input.kind(), "Resume")
}

// ──────────────────────────────────────────────────────────────────────────
// KernelEvent terminal classification
// ──────────────────────────────────────────────────────────────────────────

///|
test "KernelEvent: terminal events classified correctly" {
  let terminal_completed : KernelEvent = RunCompleted(
    final_message_summary="ok",
    model_steps=1,
    tool_calls=0,
  )
  assert_true(terminal_completed.is_terminal())

  let terminal_failed : KernelEvent = RunFailed(reason=DeadlineReached)
  assert_true(terminal_failed.is_terminal())

  let terminal_cancelled : KernelEvent = RunCancelled(
    reason=HostRequested(detail=None),
  )
  assert_true(terminal_cancelled.is_terminal())

  let non_terminal : KernelEvent = RunStarted(details=StartedDetails::{
    run_id: RunId::unchecked("r"),
    session_id: SessionId::unchecked("s"),
  })
  assert_false(non_terminal.is_terminal())

  let suspended : KernelEvent = RunSuspended(
    requirement=SuspensionRequirement::{
      kind: "approval",
      payload: Json::null(),
    },
    model_step_id=ModelStepId::first(),
  )
  assert_false(suspended.is_terminal())
}

// ──────────────────────────────────────────────────────────────────────────
// Effect accessor
// ──────────────────────────────────────────────────────────────────────────

///|
test "Effect: effect_id accessor works for all variants" {
  let cm = make_call_model_effect(EffectId::first())
  assert_eq(cm.effect_id().to_int(), 1)
  match cm.model_step_id() {
    Some(id) => assert_eq(id.to_int(), 1)
    None => fail("CallModel should carry a model_step_id")
  }

  let cancel_effect : Effect = CancelOutstanding(effect_id=EffectId::first(), payload=CancelOutstandingPayload::{
    effect_ids: [],
    reason: HostRequested(detail=None),
  })
  match cancel_effect.model_step_id() {
    Some(_) => fail("CancelOutstanding should not carry model_step_id")
    None => ()
  }
}

// ──────────────────────────────────────────────────────────────────────────
// ToolOutcome summary (sanitisation)
// ──────────────────────────────────────────────────────────────────────────

///|
test "ToolOutcome: summary excludes raw payloads" {
  let success : ToolOutcome = Success(
    content="short",
    structured=Some(Json::string("data")),
  )
  let summary = success.summary()
  assert_true(summary.contains("Success"))
  assert_false(summary.contains("data")) // payload must not leak

  let not_executed : ToolOutcome = NotExecuted(
    reason=SchemaMismatch(json_path="$.x", expected="number", actual="string"),
    original_call_id=CallId::unchecked("c1"),
  )
  let summary = not_executed.summary()
  assert_true(summary.contains("c1"))
  assert_true(summary.contains("SchemaMismatch"))
}
