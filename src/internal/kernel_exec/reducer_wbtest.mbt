///|
/// Whitebox tests for the pure reducer.
///
/// These tests drive the reducer through ADR §3 conformance cases. They are
/// pure: no async, no trait objects, no IO. The catalog and inputs are
/// constructed directly; the reducer's output is pattern-matched.

///|
fn make_catalog_v1() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  let _ = builder.add(
    ToolDef(
      name=@kernel.ToolName::unchecked("read"),
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
      owner=@kernel.OwnerId::unchecked("fs"),
      policy=Sequential,
      provenance=Some("fs-provider"),
    ),
  )
  builder.finish(version=CatalogVersion(1))
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
  Start(payload={
    initial_messages: [UserMessage(content=[Text("hi")])],
    catalog_version: CatalogVersion(1),
  })
}

///|
fn make_completion_no_tools() -> @kernel.Completion {
  Completion(
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
fn make_completion_with_two_tool_calls(
  call_id_a : String,
  call_id_b : String,
  args : Json,
) -> @kernel.Completion {
  Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked(call_id_a),
        name: @kernel.ToolName::unchecked("read"),
        arguments: args,
      },
      {
        call_id: @kernel.CallId::unchecked(call_id_b),
        name: @kernel.ToolName::unchecked("read"),
        arguments: args,
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
fn run_until_awaiting_tools_two_calls() -> (RunState, EffectId, EffectId) raise {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let completion = make_completion_with_two_tool_calls(
    "call_1",
    "call_2",
    Json::object(Map::from_array([("path", Json::string("/etc/x"))])),
  )
  let out = reduce(
    st_awaiting,
    catalog,
    ModelCompleted(payload={
      effect_id: eff_id,
      model_step_id: step_id,
      completion,
      processed_messages: st_awaiting.transcript().messages_snapshot(),
    }),
  )
  let st_tools = out.next_state()
  assert_eq(st_tools.phase(), AwaitingTools)
  let effects = out.effects()
  assert_eq(effects.length(), 2)
  let exec1 = match effects[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => abort("expected ExecuteTool effect")
  }
  let exec2 = match effects[1] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => abort("expected ExecuteTool effect")
  }
  (st_tools, exec1, exec2)
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

///|
test "C-MODEL-LENGTH-FINISH: finish_reason=Length → Terminal(Failed)" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let completion = @kernel.Completion(
    content=[Text("truncated")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Length,
    usage=None,
  )
  let input : RunInput = ModelCompleted(payload={
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
    processed_messages: st_awaiting.transcript().messages_snapshot(),
  })
  let out = reduce(st_awaiting, catalog, input)
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=ModelParseFailure(..))) => ()
    _ => fail("expected Failed(ModelParseFailure) for Length finish")
  }
}

///|
test "C-INVARIANT-DUPLICATE-CALL-ID: same call_id twice in one batch → Failed" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Two tool calls with the SAME call_id, both valid schema.
  let completion = @kernel.Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("dup"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/a"))])),
      },
      {
        call_id: @kernel.CallId::unchecked("dup"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/b"))])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  let input : RunInput = ModelCompleted(payload={
    effect_id: eff_id,
    model_step_id: step_id,
    completion,
    processed_messages: st_awaiting.transcript().messages_snapshot(),
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

// Staged completed results are kept; pending tools are marked interrupted.

///|
test "C-CANCEL-DURING-TOOLS: staged completed result kept, pending tool marked interrupted" {
  let (st_tools, exec1, _exec2) = run_until_awaiting_tools_two_calls()
  let catalog = make_catalog_v1()
  let out1 = reduce(
    st_tools,
    catalog,
    ToolCompleted(payload={
      effect_id: exec1,
      call_id: @kernel.CallId::unchecked("call_1"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="data", structured=None),
    }),
  )
  let st_staged = out1.next_state()
  assert_eq(st_staged.phase(), AwaitingTools)
  assert_eq(st_staged.transcript().length(), 2)
  let out = reduce(
    st_staged,
    catalog,
    CancelRequested(payload={ detail: None, }),
  )
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Cancelled(..)) => ()
    _ => fail("expected Cancelled outcome")
  }
  let msgs = st.transcript().messages_snapshot()
  assert_eq(msgs.length(), 4)
  match msgs[2] {
    ToolMessage(call_id~, outcome~, ..) => {
      assert_eq(call_id.to_string(), "call_1")
      assert_true(outcome is Success(..))
    }
    _ => fail("expected tool message for call_1")
  }
  match msgs[3] {
    ToolMessage(call_id~, outcome~, ..) => {
      assert_eq(call_id.to_string(), "call_2")
      match outcome {
        RuntimeFailure(..) => ()
        _ =>
          fail("expected interrupted marker for call_2, not fabricated success")
      }
    }
    _ => fail("expected tool message for call_2")
  }
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
  let markers = out
    .events()
    .filter(fn(e) {
      match e {
        ToolCompleted(..) => true
        _ => false
      }
    })
  assert_eq(markers.length(), 1)
}

///|
test "C-COMPRESS-PROCESSED-MESSAGES: ModelCompleted processed_messages replaces transcript body" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Simulate a modelport that elided the user message before sending.
  let trimmed : Array[@kernel.Message] = []
  let input : RunInput = ModelCompleted(payload={
    effect_id: eff_id,
    model_step_id: step_id,
    completion: make_completion_no_tools(),
    processed_messages: trimmed,
  })
  let out = reduce(st_awaiting, catalog, input)
  let final_state = out.next_state()
  // Transcript should be the trimmed body + the new assistant message = 1 entry.
  assert_eq(final_state.transcript().length(), 1)
}

// The reducer is the sole transcript writer.

///|
fn rewrite_input(
  messages : Array[@kernel.Message],
  reason : String,
) -> RunInput {
  TranscriptRewrite(payload={ rewritten_messages: messages, reason, })
}

///|
test "C-TRANSCRIPT-REWRITE-AWAITING-MODEL: model step in flight rejects rewrite" {
  let (st_awaiting, _eff, _step) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let rewritten : Array[@kernel.Message] = [
    UserMessage(content=[Text("compacted")]),
  ]
  let out = reduce(
    st_awaiting,
    catalog,
    rewrite_input(rewritten, "compact_replace"),
  )
  let next = out.next_state()
  assert_eq(next.phase(), AwaitingModel)
  assert_eq(next.transcript().length(), 1)
  assert_eq(next.pending_effects().length(), 1)
  assert_eq(out.effects().length(), 0)
  match out.events()[0] {
    InputRejected(input_kind~, ..) => assert_eq(input_kind, "TranscriptRewrite")
    _ => fail("expected InputRejected")
  }
}

// Completions arriving in reverse order still produce tool messages in source
// (call) order — regression guard for the wave-commit staging path.

///|
test "C-TOOL-WAVE-OUT-OF-ORDER: reverse completions preserve source order" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Assistant requests four tools in source order: alpha, beta, gamma, delta.
  let completion = @kernel.Completion(
    content=[Text("calling")],
    tool_calls=[
      {
        call_id: @kernel.CallId::unchecked("alpha"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/a"))])),
      },
      {
        call_id: @kernel.CallId::unchecked("beta"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/b"))])),
      },
      {
        call_id: @kernel.CallId::unchecked("gamma"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/c"))])),
      },
      {
        call_id: @kernel.CallId::unchecked("delta"),
        name: @kernel.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([("path", Json::string("/d"))])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  let out1 = reduce(
    st_awaiting,
    catalog,
    ModelCompleted(payload={
      effect_id: eff_id,
      model_step_id: step_id,
      completion,
      processed_messages: st_awaiting.transcript().messages_snapshot(),
    }),
  )
  let st_tools = out1.next_state()
  assert_eq(st_tools.phase(), AwaitingTools)
  let effects = out1.effects()
  assert_eq(effects.length(), 4)
  // Complete the tools in reverse source order.
  let mut state = st_tools
  for i in [3, 2, 1, 0] { // delta, gamma, beta, alpha
    let exec_id = match effects[i] {
      ExecuteTool(effect_id~, payload=ep) => {
        assert_eq(ep.tool_name, @kernel.ToolName::unchecked("read"))
        effect_id
      }
      _ => fail("expected ExecuteTool")
    }
    let call_id = match effects[i] {
      ExecuteTool(payload=ep, ..) => ep.call_id
      _ => fail("expected ExecuteTool")
    }
    let out = reduce(
      state,
      catalog,
      ToolCompleted(payload={
        effect_id: exec_id,
        call_id,
        tool_name: @kernel.ToolName::unchecked("read"),
        arguments: Json::null(),
        outcome: Success(content=call_id.to_string(), structured=None),
      }),
    )
    state = out.next_state()
  }
  // Final state is back to ReadyForModel.
  assert_eq(state.phase(), ReadyForModel)
  // Transcript contains tool messages in source order: alpha, beta, gamma, delta.
  let msgs = state.transcript().messages_snapshot()
  assert_eq(msgs.length(), 6) // User + Assistant + 4 ToolMessage
  let expected_call_ids = ["alpha", "beta", "gamma", "delta"]
  for i, expected in expected_call_ids {
    match msgs[i + 2] {
      ToolMessage(call_id~, ..) => assert_eq(call_id.to_string(), expected)
      _ => fail("expected ToolMessage at index \{i + 2}")
    }
  }
  // Tool-result ledger is also in source order.
  let tool_result_ids = state
    .transcript()
    .messages_snapshot()
    .filter(fn(msg) {
      match msg {
        ToolMessage(..) => true
        _ => false
      }
    })
    .map(fn(msg) {
      match msg {
        ToolMessage(call_id~, ..) => call_id.to_string()
        _ => ""
      }
    })
  assert_eq(tool_result_ids, expected_call_ids)
}

///|
/// Mixed wave: one valid call + one pre-pass-rejected call. The reducer must
/// surface the rejected call as one dedicated `ToolCallsPreRejected` event
/// BEFORE the effect-only batch-start, and the wave commit must not duplicate
/// the already-committed rejected tool message.
