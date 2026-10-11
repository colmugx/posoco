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
fn golden_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  let _ = builder.add(
    ToolDef(
      name=@kernel.ToolName::unchecked("read"),
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
      owner=@kernel.OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fs"),
    ),
  )
  let _ = builder.add(
    ToolDef(
      name=@kernel.ToolName::unchecked("write"),
      description="write file",
      input_schema=Json::object(
        Map::from_array([("type", Json::string("object"))]),
      ),
      owner=@kernel.OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fs"),
    ),
  )
  builder.finish(version=CatalogVersion(1))
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
  {
    initial_messages: [UserMessage(content=[Text("hello")])],
    catalog_version: CatalogVersion(1),
  }
}

///|
fn completion_no_tools(text : String) -> @kernel.Completion {
  Completion(
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
) -> @kernel.Completion {
  Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked(call_id),
        name: @kernel.ToolName::unchecked(name),
        arguments: args,
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
test "GOLDEN C-HAPPY-NO-TOOLS: Start → Model → Completed" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor().on(
    EffectId::first(),
    ScriptedModelCompleted(completion_no_tools("hi")),
  )
  let trace = scripted_driver_run(st0, catalog, scripted, golden_start(), 20)
  let final_st = trace.final_state()
  // The final message survives the whole driver loop intact.
  match final_st.outcome() {
    Some(Completed(final_message~, ..)) =>
      match final_message {
        AssistantMessage(content~, ..) =>
          match content {
            [Text(text)] => assert_eq(text, "hi")
            _ => fail("unexpected final message content")
          }
        _ => fail("expected an AssistantMessage final message")
      }
    _ => fail("expected Completed")
  }
  // Driver loop: exactly one CallModel step fed one ModelCompleted input.
  let steps = trace.steps()
  assert_eq(steps.length(), 1)
  assert_eq(steps[0].effect_kind, "CallModel")
  assert_eq(steps[0].input_kind, "ModelCompleted")
  // Exactly one terminal event, and it is RunCompleted. (Merged from
  // C-TERMINAL-EXACTLY-ONCE; the per-transition state coverage lives in
  // reducer_wbtest.mbt C-HAPPY-NO-TOOLS.)
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
  match terminals[0] {
    RunCompleted(..) => ()
    _ => fail("expected RunCompleted terminal event")
  }
}

///|
test "GOLDEN C-HAPPY-ONE-TOOL: Model → Tool → Model → Completed" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor()
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
  // Driver loop: CallModel → ExecuteTool → CallModel, in that order. The
  // terminal state itself is pinned by reducer_wbtest.mbt (C-HAPPY-ONE-TOOL,
  // C-TOOL-WAVE-OUT-OF-ORDER), so only the driver mechanics are asserted
  // here.
  let steps = trace.steps()
  assert_eq(steps.length(), 3)
  assert_eq(
    steps.map(fn(s) { s.effect_kind }).join(","),
    "CallModel,ExecuteTool,CallModel",
  )
  assert_eq(
    steps.map(fn(s) { s.input_kind }).join(","),
    "ModelCompleted,ToolCompleted,ModelCompleted",
  )
  // Exactly one terminal event closes the Run.
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
  match terminals[0] {
    RunCompleted(..) => ()
    _ => fail("expected RunCompleted terminal event")
  }
}

///|
test "GOLDEN C-MODEL-UNKNOWN-TOOL: NotExecuted, zero ExecuteTool, then re-prompt" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor()
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
  // Driver loop: the rejected call never becomes an ExecuteTool step — the
  // run goes straight back to a second CallModel.
  let steps = trace.steps()
  assert_eq(steps.length(), 2)
  assert_eq(steps.map(fn(s) { s.effect_kind }).join(","), "CallModel,CallModel")
  assert_eq(
    steps.map(fn(s) { s.input_kind }).join(","),
    "ModelCompleted,ModelCompleted",
  )
  // The NotExecuted outcome and its correlation are pinned by
  // reducer_wbtest.mbt C-MODEL-UNKNOWN-TOOL; here only the driver mechanics.
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
  match terminals[0] {
    RunCompleted(..) => ()
    _ => fail("expected RunCompleted terminal event")
  }
}

///|
test "GOLDEN C-TOOL-RUNTIME-FAILURE: tool runtime error → Run continues" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor()
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
  // Driver loop: the failed tool still completes its wave (as a
  // ToolFailed(runtime) input), and the loop continues with a second
  // CallModel step.
  let steps = trace.steps()
  assert_eq(steps.length(), 3)
  assert_eq(
    steps.map(fn(s) { s.effect_kind }).join(","),
    "CallModel,ExecuteTool,CallModel",
  )
  assert_eq(
    steps.map(fn(s) { s.input_kind }).join(","),
    "ModelCompleted,ToolFailed(runtime),ModelCompleted",
  )
  // RuntimeFailure content and the ReadyForModel continuation are pinned by
  // reducer_wbtest.mbt C-TOOL-RUNTIME-FAILURE; here only the driver
  // mechanics plus exactly-one-terminal-event.
  let terminals = trace.events().filter(fn(e) { e.is_terminal() })
  assert_eq(terminals.length(), 1)
  match terminals[0] {
    RunCompleted(..) => ()
    _ => fail("expected RunCompleted terminal event")
  }
}

///|
test "GOLDEN C-INVARIANT-MISSING-OWNER: scripted MissingOwner → Terminal(Failed)" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor()
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
        MissingOwner(owner=@kernel.OwnerId::unchecked("nonexistent")),
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

///|
test "GOLDEN C-HAPPY-MULTI-TOOL: two parallel tools in one batch" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  let scripted = ScriptedExecutor()
    .on(
      EffectId::first(),
      ScriptedModelCompleted(
        Completion(
          content=[Text("calling both")],
          tool_calls=[
            {
              call_id: @kernel.CallId::unchecked("c1"),
              name: @kernel.ToolName::unchecked("read"),
              arguments: Json::object(
                Map::from_array([("path", Json::string("/a"))]),
              ),
            },
            {
              call_id: @kernel.CallId::unchecked("c2"),
              name: @kernel.ToolName::unchecked("write"),
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
  let completion = @kernel.Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("read_call"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/a"))])),
      },
      {
        call_id: @kernel.CallId::unchecked("write_call"),
        name: @kernel.ToolName::unchecked("write"),
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
      processed_messages: waiting.next_state().transcript().messages_snapshot(),
    }),
  )
  let tools_state = tools_out.next_state()
  let effects = tools_out.effects()
  // Wave size / effect-shape coverage is pinned by reducer_wbtest.mbt
  // C-TOOL-WAVE-OUT-OF-ORDER; the unique value asserted here is the
  // TERMINAL RunOutcome ordering (Completed.tool_results) after a further
  // model step.
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
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="second", structured=None),
    }),
  )
  let after_first = reduce(
    after_second.next_state(),
    catalog,
    ToolCompleted(payload={
      effect_id: first_effect_id,
      call_id: first_call_id,
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
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
      processed_messages: final_waiting
      .next_state()
      .transcript()
      .messages_snapshot(),
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

///|
test "GOLDEN C-UNSCRIPTED-EFFECT: missing script raises fixture error" {
  let catalog = golden_catalog()
  let st0 = golden_initial_state()
  // Script the first model step but forget to script the resulting tool.
  let scripted = ScriptedExecutor().on(
    EffectId::first(),
    ScriptedModelCompleted(
      completion_with_tool_call(
        "c1",
        "read",
        Json::object(Map::from_array([("path", Json::string("/x"))])),
      ),
    ),
  )
  let result = scripted_driver_run(st0, catalog, scripted, golden_start(), 30)
  assert_eq(result.final_state().phase(), Terminal)
  // Pinned fixture-documentation behaviour: an effect with no configured
  // script defaults to ScriptedToolInvariant(StaleCorrelation(effect_id))
  // (see ScriptedExecutor::lookup), which the reducer turns into a terminal
  // Failed(InvariantViolation(StaleCorrelation)).
  match result.final_state().outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(effect_id~) =>
          assert_eq(effect_id, EffectId::first().next())
        _ => fail("expected StaleCorrelation, got \{category.to_string()}")
      }
    _ => fail("expected Failed(InvariantViolation(StaleCorrelation))")
  }
}
