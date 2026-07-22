///|
/// M1-T09 Golden conformance tests using the scripted minimal driver.
///
/// Each test drives a Run from Start to Terminal via the scripted driver
/// and asserts the resulting DriverTrace: phase transitions, terminal
/// outcome, event ordering, and absence of unexpected effects.
///
/// These tests are the END-TO-END integration layer for the M1 Kernel.
/// The reducer's per-transition tests (kernel_reducer_wbtest.mbt) cover
/// individual state changes; these tests verify the whole mechanical loop.

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

fn golden_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder::new()
  let _ = builder.add(
    CanonicalToolDef::new(
      name=ToolName::unchecked("read"),
      description="read file",
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
      provenance=Some("fs"),
    ),
  )
  let _ = builder.add(
    CanonicalToolDef::new(
      name=ToolName::unchecked("write"),
      description="write file",
      input_schema=Json::object(
        Map::from_array([("type", Json::string("object"))]),
      ),
      owner=OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fs"),
    ),
  )
  builder.finish(version=CatalogVersion::new(1))
}

///|
fn golden_initial_state() -> RunState raise KernelError {
  RunState::initial(
    run_id=RunId::unchecked("golden_run"),
    session_id=SessionId::unchecked("golden_sess"),
    budget=Budget::default_run(),
  )
}

///|
fn golden_start() -> StartPayload {
  StartPayload::{
    initial_messages: [UserMessage(content=[Text("hello")])],
    catalog_version: CatalogVersion::new(1),
  }
}

///|
fn completion_no_tools(text : String) -> AssistantCompletion {
  AssistantCompletion::new(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
}

///|
fn completion_with_tool_call(
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

// ──────────────────────────────────────────────────────────────────────────
// C-HAPPY-NO-TOOLS (golden)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-HAPPY-NO-TOOLS: Start → Model → Completed" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new().on(
    EffectId::first(),
    ScriptedModelCompleted(completion_no_tools("hi")),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 20)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Completed(..)) => ()
    _ => fail("expected Completed")
  }
  // Exactly one terminal event.
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
  match terminals[0] {
    RunCompleted(..) => ()
    _ => fail("expected RunCompleted terminal event")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-HAPPY-ONE-TOOL (golden)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-HAPPY-ONE-TOOL: Model → Tool → Model → Completed" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new()
    .on(
      // First model step: declares ExecuteTool (effect id 2).
      EffectId::first(),
      ScriptedModelCompleted(
        completion_with_tool_call(
          "c1",
          "read",
          Json::object(Map::from_array([("path", Json::string("/x"))])),
        ),
      ),
    )
    .on(
      // First ExecuteTool.
      EffectId::first().next(),
      ScriptedToolCompleted(Success(content="data", structured=None)),
    )
    .on(
      // Second model step (effect id 3): no tools.
      EffectId::first().next().next(),
      ScriptedModelCompleted(completion_no_tools("done")),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Completed(final_message~, tool_results~)) => {
      ignore(final_message)
      assert_eq(tool_results.length(), 1)
      match tool_results[0] {
        Success(content~, structured=None) => assert_eq(content, "data")
        _ => fail("expected one successful tool result")
      }
    }
    _ => fail("expected Completed after one tool round")
  }
  // 3 driver steps: 1 CallModel + 1 ExecuteTool + 1 CallModel.
  assert_eq(trace.steps().length(), 3)
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-UNKNOWN-TOOL (golden)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-MODEL-UNKNOWN-TOOL: NotExecuted, zero ExecuteTool, then re-prompt" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(
        completion_with_tool_call(
          "c1",
          "nonexistent",
          Json::object(Map::from_array([])),
        ),
      ),
    )
    .on(
      // Second model step: no tools (after seeing rejection).
      EffectId::first().next(),
      ScriptedModelCompleted(completion_no_tools("ok")),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Completed(final_message~, tool_results~)) => {
      ignore(final_message)
      assert_eq(tool_results.length(), 1)
      match tool_results[0] {
        NotExecuted(reason=UnknownTool, original_call_id=call_id) =>
          assert_eq(call_id.to_string(), "c1")
        _ => fail("expected NotExecuted(UnknownTool) terminal result")
      }
    }
    _ => fail("expected Completed with NotExecuted result")
  }
  // Only TWO CallModel steps were executed; no ExecuteTool.
  let kinds = trace.steps().map(fn(s) { s.effect_kind }).join(",")
  assert_eq(kinds, "CallModel,CallModel")
}

// ──────────────────────────────────────────────────────────────────────────
// C-MODEL-TRANSPORT-FAILURE (golden)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-MODEL-TRANSPORT-FAILURE: ModelFailed → Terminal(Failed)" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new().on(
    EffectId::first(),
    ScriptedModelFailed(Transport(reason="HTTP 503")),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 20)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Failed(reason=ModelTransport(..))) => ()
    _ => fail("expected Failed(ModelTransport)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-TOOL-RUNTIME-FAILURE (golden, non-terminal)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-TOOL-RUNTIME-FAILURE: tool runtime error → Run continues" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(
        completion_with_tool_call(
          "c1",
          "read",
          Json::object(Map::from_array([("path", Json::string("/x"))])),
        ),
      ),
    )
    .on(
      EffectId::first().next(),
      ScriptedToolRuntime(Transport(reason="reset")),
    )
    .on(
      EffectId::first().next().next(),
      ScriptedModelCompleted(completion_no_tools("ok")),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  let final_st = trace.final_state()
  // Run continued despite tool failure.
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Completed(final_message~, tool_results~)) => {
      ignore(final_message)
      assert_eq(tool_results.length(), 1)
      match tool_results[0] {
        RuntimeFailure(error_category~, message~) => {
          assert_eq(error_category, "Transport")
          assert_eq(message, "reset")
        }
        _ => fail("expected RuntimeFailure terminal result")
      }
    }
    _ => fail("expected Completed despite tool runtime failure")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-TERMINAL-EXACTLY-ONCE (golden invariant)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-TERMINAL-EXACTLY-ONCE: every Run ends with exactly 1 terminal event" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new().on(
    EffectId::first(),
    ScriptedModelCompleted(completion_no_tools("ok")),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 20)
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
}

// ──────────────────────────────────────────────────────────────────────────
// C-MISSING-OWNER (golden — invariant failure via scripted)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-INVARIANT-MISSING-OWNER: scripted MissingOwner → Terminal(Failed)" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(
        completion_with_tool_call(
          "c1",
          "read",
          Json::object(Map::from_array([("path", Json::string("/x"))])),
        ),
      ),
    )
    .on(
      EffectId::first().next(),
      ScriptedToolInvariant(
        MissingOwner(owner=OwnerId::unchecked("nonexistent")),
      ),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        MissingOwner(..) => ()
        _ => fail("expected MissingOwner invariant")
      }
    _ => fail("expected InvariantViolation(MissingOwner)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-MULTI-TOOL PARALLEL (golden — both tools in one batch)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-HAPPY-MULTI-TOOL: two parallel tools in one batch" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor::new()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(
        AssistantCompletion::new(
          content=[Text("calling both")],
          tool_calls=[
            {
              call_id: CallId::unchecked("c1"),
              name: ToolName::unchecked("read"),
              arguments: Json::object(
                Map::from_array([("path", Json::string("/a"))]),
              ),
            },
            {
              call_id: CallId::unchecked("c2"),
              name: ToolName::unchecked("write"),
              arguments: Json::object(Map::from_array([])),
            },
          ],
          reasoning=None,
          finish_reason=ToolCalls,
          usage=None,
        ),
      ),
    )
    .on(
      EffectId::first().next(),
      ScriptedToolCompleted(Success(content="r1", structured=None)),
    )
    .on(
      EffectId::first().next().next(),
      ScriptedToolCompleted(Success(content="r2", structured=None)),
    )
    .on(
      EffectId::first().next().next().next(),
      ScriptedModelCompleted(completion_no_tools("done")),
    )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 40)
  let final_st = trace.final_state()
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Completed(final_message~, tool_results~)) => {
      ignore(final_message)
      assert_eq(tool_results.length(), 2)
      match (tool_results[0], tool_results[1]) {
        (
          Success(content=content0, structured=None),
          Success(content=content1, structured=None),
        ) => {
          assert_eq(content0, "r1")
          assert_eq(content1, "r2")
        }
        _ => fail("expected two successful tool results in source order")
      }
    }
    _ => fail("expected Completed after two tools")
  }
  // Steps: CallModel, ExecuteTool, ExecuteTool, CallModel
  assert_eq(trace.steps().length(), 4)
}

///|
test "GOLDEN C-HAPPY-REVERSE-TOOL-COMPLETION: terminal results preserve call order" {
  let catalog = golden_catalog()
  let started = reduce(
    golden_initial_state(),
    catalog,
    Start(payload=golden_start()),
  )
  let waiting = run_model_step(started.next_state(), catalog, Json::null())
  let (model_effect_id, model_step_id) = match
    waiting.next_state().pending_effects()[0] {
    CallModel(effect_id~, payload~) => (effect_id, payload.model_step_id)
    _ => fail("expected initial CallModel effect")
  }
  let completion = AssistantCompletion::new(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: CallId::unchecked("read_call"),
        name: ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/a"))])),
      },
      {
        call_id: CallId::unchecked("write_call"),
        name: ToolName::unchecked("write"),
        arguments: Json::object(Map::from_array([])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  let tools_out = reduce(
    waiting.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: model_effect_id,
      model_step_id,
      completion,
    }),
  )
  let tools_state = tools_out.next_state()
  let effects = tools_out.effects()
  assert_eq(effects.length(), 2)
  let (first_effect_id, first_call_id) = match effects[0] {
    ExecuteTool(effect_id~, payload~) => (effect_id, payload.call_id)
    _ => fail("expected first ExecuteTool effect")
  }
  let (second_effect_id, second_call_id) = match effects[1] {
    ExecuteTool(effect_id~, payload~) => (effect_id, payload.call_id)
    _ => fail("expected second ExecuteTool effect")
  }
  // Complete the second call first, then the first call. Completion order is
  // intentionally different from the model's source order.
  let after_second = reduce(
    tools_state,
    catalog,
    ToolCompleted(payload={
      effect_id: second_effect_id,
      call_id: second_call_id,
      outcome: Success(content="second", structured=None),
    }),
  )
  let after_first = reduce(
    after_second.next_state(),
    catalog,
    ToolCompleted(payload={
      effect_id: first_effect_id,
      call_id: first_call_id,
      outcome: Success(content="first", structured=None),
    }),
  )
  let final_waiting = run_model_step(
    after_first.next_state(),
    catalog,
    Json::null(),
  )
  let (final_effect_id, final_step_id) = match
    final_waiting.next_state().pending_effects()[0] {
    CallModel(effect_id~, payload~) => (effect_id, payload.model_step_id)
    _ => fail("expected final CallModel effect")
  }
  let terminal_state = reduce(
    final_waiting.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: final_effect_id,
      model_step_id: final_step_id,
      completion: completion_no_tools("done"),
    }),
  ).next_state()
  match terminal_state.outcome() {
    Some(Completed(final_message~, tool_results~)) => {
      ignore(final_message)
      assert_eq(tool_results.length(), 2)
      match (tool_results[0], tool_results[1]) {
        (
          Success(content=first_content, structured=None),
          Success(content=second_content, structured=None),
        ) => {
          assert_eq(first_content, "first")
          assert_eq(second_content, "second")
        }
        _ => fail("terminal results were not in source order")
      }
    }
    _ => fail("expected terminal Completed outcome")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// C-UNSCRIPTED-EFFECT (golden — loud failure when test forgets to script)
// ──────────────────────────────────────────────────────────────────────────

///|
test "GOLDEN C-UNSCRIPTED-EFFECT: missing script → StaleCorrelation → Failed" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  // Script the first model step but forget to script the resulting tool.
  let scripted = ScriptedExecutor::new().on(
    EffectId::first(),
    ScriptedModelCompleted(
      completion_with_tool_call(
        "c1",
        "read",
        Json::object(Map::from_array([("path", Json::string("/x"))])),
      ),
    ),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  let final_st = trace.final_state()
  // Missing script → invariant failure (loud default).
  assert_eq(final_st.phase(), Terminal)
  match final_st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(..) => ()
        _ => fail("expected StaleCorrelation from missing script")
      }
    _ => fail("expected InvariantViolation from missing script")
  }
}
