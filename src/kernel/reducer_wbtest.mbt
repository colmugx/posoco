///|
/// Whitebox tests for the M1-T03 pure reducer.
///
/// These tests drive the reducer through ADR §3 conformance cases. They are
/// pure: no async, no trait objects, no IO. The catalog and inputs are
/// constructed directly; the reducer's output is pattern-matched.
///
/// Coverage:
/// - C-HAPPY-NO-TOOLS, C-HAPPY-ONE-TOOL
/// - C-MODEL-UNKNOWN-TOOL, C-MODEL-SCHEMA-MISMATCH (NotExecuted, zero ExecuteTool)
/// - C-MODEL-PARSE-FAILURE (Length finish reason)
/// - C-INVARIANT-DUPLICATE-CALL-ID
/// - C-SUSPEND-RESUME-IN-PROCESS
/// - C-SUSPEND-LATE-COMPLETION-REJECTED
/// - C-CANCEL-BEFORE-MODEL, C-CANCEL-WHILE-MODEL
/// - C-DEADLINE-DURING-MODEL
/// - C-POST-TERMINAL-REJECTED
/// - C-RACE-DEADLINE-WINS

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

fn make_catalog_v1() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder::new()
  let _ = builder.add(
    CanonicalToolDef::new(
      name=ToolName::unchecked("read"),
      description="read a file",
      input_schema=Json::object(
        Map::from_array([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map::from_array([
                (
                  "path",
                  Json::object(
                    Map::from_array([("type", Json::string("string"))]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("path")])),
        ]),
      ),
      owner=OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fs-provider"),
    ),
  )
  builder.finish(version=CatalogVersion::new(1))
}

///|
fn fresh_state() -> RunState raise KernelError {
  RunState::initial(
    run_id=RunId::unchecked("run_1"),
    session_id=SessionId::unchecked("sess_1"),
    budget=Budget::default_run(),
  )
}

///|
fn start_input() -> RunInput {
  Start(payload=StartPayload::{
    initial_messages: [UserMessage(content=[Text("hi")])],
    catalog_version: CatalogVersion::new(1),
  })
}

///|
fn make_completion_no_tools() -> AssistantCompletion {
  AssistantCompletion::new(
    content=[Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
}

///|
fn make_completion_with_tool_call(
  call_id : String,
  name : String,
  args : Json,
) -> AssistantCompletion {
  AssistantCompletion::new(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: CallId::unchecked(call_id),
        name: ToolName::unchecked(name),
        arguments: args,
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
fn run_until_awaiting_model() -> (RunState, EffectId, ModelStepId) raise {
  let st0 = fresh_state()
  let catalog = make_catalog_v1()
  let out_start = reduce(st0, catalog, start_input())
  let st1 = out_start.next_state()
  // Drive a model step.
  let out_step = run_model_step(st1, catalog, Json::null())
  let st2 = out_step.next_state()
  // There should be exactly one CallModel effect pending.
  let pending = st2.pending_effects()
  match pending[0] {
    CallModel(effect_id~, payload~) => (st2, effect_id, payload.model_step_id)
    _ => abort("expected CallModel pending effect")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-HAPPY-NO-TOOLS
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-HAPPY-NO-TOOLS: Start → CallModel → ModelCompleted → Terminal(Completed)" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion: make_completion_no_tools(),
  })
  let out = reduce(st_awaiting, catalog, input)
  let final_state = out.next_state()
  assert_eq(final_state.phase(), Terminal)
  match final_state.outcome() {
    Some(Completed(..)) => ()
    _ => fail("expected Completed outcome")
  }
  // Exactly one terminal event.
  let terminal_events = out.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminal_events.length(), 1)
  // No further effects.
  assert_eq(out.effects().length(), 0)
}

// ──────────────────────────────────────────────────────────────────────────
// C-HAPPY-ONE-TOOL
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-HAPPY-ONE-TOOL: model step → tool call → ExecuteTool → ToolCompleted → ReadyForModel" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // First, model completes with a tool call.
  let completion = make_completion_with_tool_call(
    "call_1",
    "read",
    Json::object(Map::from_array([("path", Json::string("/etc/x"))])),
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  let st_tools = out.next_state()
  assert_eq(st_tools.phase(), AwaitingTools)
  // Should have one ExecuteTool effect.
  let effects = out.effects()
  assert_eq(effects.length(), 1)
  let exec_id = match effects[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => fail("expected ExecuteTool effect")
  }
  // Tool completes successfully.
  let tool_input : RunInput = ToolCompleted(payload=ToolCompletedPayload::{
    effect_id: exec_id,
    call_id: CallId::unchecked("call_1"),
    outcome: Success(content="data", structured=None),
  })
  let out2 = reduce(st_tools, catalog, tool_input)
  let st_ready = out2.next_state()
  assert_eq(st_ready.phase(), ReadyForModel)
  // Transcript: [UserMessage, AssistantMessage, ToolMessage]
  assert_eq(st_ready.transcript().length(), 3)
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-UNKNOWN-TOOL
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-MODEL-UNKNOWN-TOOL: unknown tool name → NotExecuted(UnknownTool), zero ExecuteTool" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let completion = make_completion_with_tool_call(
    "call_x",
    "nonexistent_tool",
    Json::object(Map::from_array([])),
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  // Zero ExecuteTool effects declared.
  assert_eq(out.effects().length(), 0)
  let st = out.next_state()
  // State back to ReadyForModel (model needs to see its rejected call).
  assert_eq(st.phase(), ReadyForModel)
  // Tool outcome written to transcript.
  // transcript: [UserMessage, AssistantMessage, ToolMessage]
  assert_eq(st.transcript().length(), 3)
  // Verify the tool message carries NotExecuted(UnknownTool).
  let msgs = st.transcript().messages_snapshot()
  match msgs[2] {
    ToolMessage(outcome~, ..) =>
      match outcome {
        NotExecuted(reason=UnknownTool, ..) => ()
        _ => fail("expected NotExecuted(UnknownTool)")
      }
    _ => fail("expected ToolMessage at index 2")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-SCHEMA-MISMATCH
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-MODEL-SCHEMA-MISMATCH: parsed args fail schema → NotExecuted(SchemaMismatch)" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // 'read' requires path:string. Pass an object missing 'path'.
  let completion = make_completion_with_tool_call(
    "call_y",
    "read",
    Json::object(Map::from_array([])),
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  assert_eq(out.effects().length(), 0)
  let st = out.next_state()
  // transcript: [UserMessage, AssistantMessage, ToolMessage]
  let msgs = st.transcript().messages_snapshot()
  assert_eq(msgs.length(), 3)
  match msgs[2] {
    ToolMessage(outcome~, ..) =>
      match outcome {
        NotExecuted(reason=SchemaMismatch(..), ..) => ()
        _ => fail("expected NotExecuted(SchemaMismatch)")
      }
    _ => fail("expected ToolMessage at index 2")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-PARSE-FAILURE (Length finish reason)
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-MODEL-LENGTH-FINISH: finish_reason=Length → Terminal(Failed)" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let completion = AssistantCompletion::new(
    content=[Text("truncated")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Length,
    usage=None,
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=ModelParseFailure(..))) => ()
    _ => fail("expected Failed(ModelParseFailure) for Length finish")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-TRANSPORT-FAILURE
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-MODEL-TRANSPORT-FAILURE: ModelFailed(Transport) → Terminal(Failed)" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let input : RunInput = ModelFailed(payload=ModelFailedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    failure: Transport(reason="HTTP 500"),
  })
  let out = reduce(st_awaiting, catalog, input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=ModelTransport(..))) => ()
    _ => fail("expected Failed(ModelTransport)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-INVARIANT-DUPLICATE-CALL-ID (within model completion)
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-INVARIANT-DUPLICATE-CALL-ID: same call_id twice in one batch → Failed" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Two tool calls with the SAME call_id, both valid schema.
  let completion = AssistantCompletion::new(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: CallId::unchecked("dup"),
        name: ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/a"))])),
      },
      {
        call_id: CallId::unchecked("dup"),
        name: ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/b"))])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        DuplicateCallId(call_id~) => assert_eq(call_id.to_string(), "dup")
        _ => fail("expected DuplicateCallId invariant")
      }
    _ => fail("expected InvariantViolation(DuplicateCallId)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-SUSPEND-RESUME-IN-PROCESS
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-SUSPEND-RESUME-IN-PROCESS: AwaitingModel → Suspended → ReadyForModel" {
  let (st_awaiting, _eff_id, _step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let suspend_input : RunInput = SuspendRequested(payload=SuspendRequestedPayload::{
    requirement: SuspensionRequirement::{
      kind: "approval",
      payload: Json::null(),
    },
  })
  let out = reduce(st_awaiting, catalog, suspend_input)
  let st_suspended = out.next_state()
  assert_eq(st_suspended.phase(), Suspended)
  assert_true(st_suspended.outcome() is None)
  assert_eq(st_suspended.pending_effects().length(), 0)
  // RunSuspended event is non-terminal.
  let events = out.events()
  let has_suspend_event = events
    .iter()
    .any(fn(e) {
      match e {
        RunSuspended(..) => true
        _ => false
      }
    })
  assert_true(has_suspend_event)
  let has_terminal = events.iter().any(fn(e) { e.is_terminal() })
  assert_false(has_terminal)
  // Resume.
  let resume_input : RunInput = Resume(payload=ResumePayload::{
    payload: Json::null(),
  })
  let out2 = reduce(st_suspended, catalog, resume_input)
  let st_resumed = out2.next_state()
  assert_eq(st_resumed.phase(), ReadyForModel)
  // Same run_id preserved.
  assert_eq(st_resumed.run_id().to_string(), "run_1")
}

// ──────────────────────────────────────────────────────────────────────────
// C-SUSPEND-LATE-COMPLETION-REJECTED
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-SUSPEND-LATE-COMPLETION-REJECTED: ModelCompleted while Suspended rejected" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Suspend.
  let suspend_input : RunInput = SuspendRequested(payload=SuspendRequestedPayload::{
    requirement: SuspensionRequirement::{
      kind: "approval",
      payload: Json::null(),
    },
  })
  let out_s = reduce(st_awaiting, catalog, suspend_input)
  let st_suspended = out_s.next_state()
  // Stray ModelCompleted (for the dropped model effect).
  let stray : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion: make_completion_no_tools(),
  })
  let out = reduce(st_suspended, catalog, stray)
  // State unchanged (still Suspended).
  assert_eq(out.next_state().phase(), Suspended)
  // InputRejected event emitted.
  let rejected = out
    .events()
    .iter()
    .any(fn(e) {
      match e {
        InputRejected(..) => true
        _ => false
      }
    })
  assert_true(rejected)
}

// ──────────────────────────────────────────────────────────────────────────
// C-CANCEL-BEFORE-MODEL (ReadyForModel)
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-CANCEL-BEFORE-MODEL: ReadyForModel + CancelRequested → Terminal(Cancelled)" {
  let st0 = fresh_state()
  let catalog = make_catalog_v1()
  let st1 = reduce(st0, catalog, start_input()).next_state()
  let cancel_input : RunInput = CancelRequested(payload=CancelRequestedPayload::{
    detail: None,
  })
  let out = reduce(st1, catalog, cancel_input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Cancelled(..)) => ()
    _ => fail("expected Cancelled outcome")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-CANCEL-WHILE-MODEL (AwaitingModel)
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-CANCEL-WHILE-MODEL: AwaitingModel + CancelRequested → CancelOutstanding + Cancelled" {
  let (st_awaiting, _eff_id, _step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let cancel_input : RunInput = CancelRequested(payload=CancelRequestedPayload::{
    detail: None,
  })
  let out = reduce(st_awaiting, catalog, cancel_input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Cancelled(..)) => ()
    _ => fail("expected Cancelled")
  }
  // Should declare a CancelOutstanding effect.
  let has_cancel_effect = out
    .effects()
    .iter()
    .any(fn(e) {
      match e {
        CancelOutstanding(..) => true
        _ => false
      }
    })
  assert_true(has_cancel_effect)
}

// ──────────────────────────────────────────────────────────────────────────
// C-DEADLINE-DURING-MODEL
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-DEADLINE-DURING-MODEL: DeadlineReached wins → Terminal(Failed)" {
  let (st_awaiting, _eff_id, _step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let dl_input : RunInput = DeadlineReached(payload=DeadlineReachedPayload::{
    detail: "elapsed",
  })
  let out = reduce(st_awaiting, catalog, dl_input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=DeadlineReached)) => ()
    _ => fail("expected Failed(DeadlineReached)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-POST-TERMINAL-REJECTED
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-POST-TERMINAL-REJECTED: any input after Terminal is rejected" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Drive to Terminal(Completed).
  let completion = make_completion_no_tools()
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  let st_terminal = out.next_state()
  assert_eq(st_terminal.phase(), Terminal)
  // Send another input — should be rejected.
  let stray : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out2 = reduce(st_terminal, catalog, stray)
  assert_eq(out2.next_state().phase(), Terminal) // unchanged
  let rejected = out2
    .events()
    .iter()
    .any(fn(e) {
      match e {
        InputRejected(..) => true
        _ => false
      }
    })
  assert_true(rejected)
}

// ──────────────────────────────────────────────────────────────────────────
// C-TOOL-RUNTIME-FAILURE (non-terminal)
// ──────────────────────────────────────────────────────────────────────────

///|
test "C-TOOL-RUNTIME-FAILURE: ToolFailed(runtime) → RuntimeFailure outcome, Run continues" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let completion = make_completion_with_tool_call(
    "call_1",
    "read",
    Json::object(Map::from_array([("path", Json::string("/x"))])),
  )
  let input : RunInput = ModelCompleted(payload=ModelCompletedPayload::{
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
  })
  let out = reduce(st_awaiting, catalog, input)
  let st_tools = out.next_state()
  let exec_id = match out.effects()[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => fail("expected ExecuteTool")
  }
  // Tool fails with runtime error.
  let tool_fail : RunInput = ToolFailed(payload=ToolFailedPayload::{
    effect_id: exec_id,
    call_id: CallId::unchecked("call_1"),
    runtime: Some(Transport(reason="connection reset")),
    invariant_failure: None,
  })
  let out2 = reduce(st_tools, catalog, tool_fail)
  let st_ready = out2.next_state()
  // Run continues — not terminal.
  assert_eq(st_ready.phase(), ReadyForModel)
  // Outcome was RuntimeFailure.
  let msgs = st_ready.transcript().messages_snapshot()
  match msgs[2] {
    ToolMessage(outcome~, ..) =>
      match outcome {
        RuntimeFailure(..) => ()
        _ => fail("expected RuntimeFailure outcome")
      }
    _ => fail("expected ToolMessage with RuntimeFailure")
  }
}
