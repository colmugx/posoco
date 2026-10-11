///|
/// D1 adversarial tests for tool-completion correlation (reducer_tool.mbt
/// reduce_tool_completed): a `ToolCompleted` input matches its pending
/// `ExecuteTool` effect only when BOTH `effect_id` AND `call_id` agree.
/// Any other combination is a terminal
/// `FailureReason::InvariantViolation(StaleCorrelation)` — never a silent
/// fold. The completion's `tool_name`/`arguments` payload fields are
/// intentionally ignored: the pending effect is the single source of truth
/// for what was declared.

///|
test "D1-STALE-CORRELATION: matching effect_id with wrong call_id → StaleCorrelation" {
  let (st_tools, exec1, _exec2) = run_until_awaiting_tools_two_calls()
  let catalog = make_catalog_v1()
  let out = reduce(
    st_tools,
    catalog,
    ToolCompleted(payload={
      effect_id: exec1,
      call_id: @kernel.CallId::unchecked("call_wrong"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="must never land", structured=None),
    }),
  )
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(effect_id~) => assert_eq(effect_id, exec1)
        _ => fail("expected StaleCorrelation, got \{category.to_string()}")
      }
    _ => fail("expected Failed(InvariantViolation(StaleCorrelation))")
  }
  // The forged completion changed nothing: transcript is preserved verbatim
  // and no result was committed for either pending call.
  assert_eq(st.transcript(), st_tools.transcript())
  assert_eq(st.tool_results_snapshot().length(), 0)
}

///|
test "D1-STALE-CORRELATION: matching call_id with wrong effect_id → StaleCorrelation" {
  let (st_tools, _exec1, exec2) = run_until_awaiting_tools_two_calls()
  let catalog = make_catalog_v1()
  // call_1 is pending, but the completion cites exec2's effect id — the pair
  // never matches a single pending ExecuteTool.
  let out = reduce(
    st_tools,
    catalog,
    ToolCompleted(payload={
      effect_id: exec2,
      call_id: @kernel.CallId::unchecked("call_1"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="must never land", structured=None),
    }),
  )
  let st = out.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(effect_id~) => assert_eq(effect_id, exec2)
        _ => fail("expected StaleCorrelation, got \{category.to_string()}")
      }
    _ => fail("expected Failed(InvariantViolation(StaleCorrelation))")
  }
  assert_eq(st.transcript(), st_tools.transcript())
}

///|
test "D1-STALE-CORRELATION: repeated completion of the same effect → StaleCorrelation" {
  let (st_tools, exec1, _exec2) = run_until_awaiting_tools_two_calls()
  let catalog = make_catalog_v1()
  let first = reduce(
    st_tools,
    catalog,
    ToolCompleted(payload={
      effect_id: exec1,
      call_id: @kernel.CallId::unchecked("call_1"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="first", structured=None),
    }),
  )
  // exec1 was removed from pending but the wave is still open (call_2 left).
  let st_staged = first.next_state()
  assert_eq(st_staged.phase(), AwaitingTools)
  assert_eq(st_staged.transcript().length(), 2)
  // Replay the SAME completion while the wave is still open.
  let replay = reduce(
    st_staged,
    catalog,
    ToolCompleted(payload={
      effect_id: exec1,
      call_id: @kernel.CallId::unchecked("call_1"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="duplicate", structured=None),
    }),
  )
  let st = replay.next_state()
  assert_eq(st.phase(), Terminal)
  match st.outcome() {
    Some(Failed(reason=InvariantViolation(category~))) =>
      match category {
        StaleCorrelation(effect_id~) => assert_eq(effect_id, exec1)
        _ => fail("expected StaleCorrelation, got \{category.to_string()}")
      }
    _ => fail("expected StaleCorrelation for the duplicated completion")
  }
  // The duplicate must not double-commit call_1: transcript still holds only
  // the staged pre-commit state (assistant message, no tool messages).
  assert_eq(st.transcript(), st_staged.transcript())
}

///|
test "D1-STALE-CORRELATION: completion payload name/arguments are ignored, pending effect is canonical" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  let declared_args = Json::object(
    Map::from_array([("path", Json::string("/etc/x"))]),
  )
  let declared = reduce(
    st_awaiting,
    catalog,
    ModelCompleted(payload={
      effect_id: eff_id,
      model_step_id: step_id,
      completion: make_completion_with_tool_call(
        "call_1", "read", declared_args,
      ),
      processed_messages: st_awaiting.transcript().messages_snapshot(),
    }),
  )
  let exec_id = match declared.effects()[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => fail("expected ExecuteTool")
  }
  // Deliberately lie in the completion payload: wrong tool name and wrong
  // arguments. Correlation matches on (effect_id, call_id) only, so the fold
  // succeeds — pinned current behaviour, per reducer_tool.mbt:38-57.
  let out = reduce(
    declared.next_state(),
    catalog,
    ToolCompleted(payload={
      effect_id: exec_id,
      call_id: @kernel.CallId::unchecked("call_1"),
      tool_name: @kernel.ToolName::unchecked("write"),
      arguments: Json::object(Map::from_array([("evil", Json::boolean(true))])),
      outcome: Success(content="done", structured=None),
    }),
  )
  let st = out.next_state()
  // The wave commits and the Run continues — the payload lie does not fail
  // correlation.
  assert_eq(st.phase(), ReadyForModel)
  // The transcript records the PENDING effect's tool name, not the payload's.
  let msgs = st.transcript().messages_snapshot()
  assert_eq(msgs.length(), 3)
  match msgs[2] {
    ToolMessage(call_id~, tool_name~, ..) => {
      assert_eq(call_id.to_string(), "call_1")
      assert_eq(tool_name, @kernel.ToolName::unchecked("read"))
    }
    _ => fail("expected ToolMessage for call_1 at index 2")
  }
  // The committed event carries the canonical call too.
  match out.events()[0] {
    ToolCompleted(call~, ..) => {
      assert_eq(call.name, @kernel.ToolName::unchecked("read"))
      assert_eq(call.arguments, declared_args)
    }
    _ => fail("expected ToolCompleted event")
  }
}

///|
test "D1-STALE-CORRELATION: call_id replayed across model steps is accepted and yields a second ledger entry" {
  let (st_awaiting, eff_id, step_id) = run_until_awaiting_model()
  let catalog = make_catalog_v1()
  // Step 1: model declares call "replay"; host completes it.
  let first_decl = reduce(
    st_awaiting,
    catalog,
    ModelCompleted(payload={
      effect_id: eff_id,
      model_step_id: step_id,
      completion: make_completion_with_tool_call(
        "replay",
        "read",
        Json::object(Map::from_array([("path", Json::string("/one"))])),
      ),
      processed_messages: st_awaiting.transcript().messages_snapshot(),
    }),
  )
  let exec1 = match first_decl.effects()[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => abort("expected first ExecuteTool")
  }
  let after_first = reduce(
    first_decl.next_state(),
    catalog,
    ToolCompleted(payload={
      effect_id: exec1,
      call_id: @kernel.CallId::unchecked("replay"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="first", structured=None),
    }),
  )
  let ready1 = after_first.next_state()
  assert_eq(ready1.phase(), ReadyForModel)
  // Step 2: the model (badly) reuses the SAME call_id. Correlation is
  // per-wave only, so the reducer accepts the replay instead of raising
  // StaleCorrelation or DuplicateCallId — pinned current behaviour.
  let step2 = run_model_step(ready1, catalog, Json::null())
  let (eff2, step2_id) = match step2.effects()[0] {
    CallModel(effect_id~, payload~) => (effect_id, payload.model_step_id)
    _ => abort("expected second CallModel")
  }
  let second_decl = reduce(
    step2.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: eff2,
      model_step_id: step2_id,
      completion: make_completion_with_tool_call(
        "replay",
        "read",
        Json::object(Map::from_array([("path", Json::string("/two"))])),
      ),
      processed_messages: ready1.transcript().messages_snapshot(),
    }),
  )
  let exec2 = match second_decl.effects()[0] {
    ExecuteTool(effect_id~, ..) => effect_id
    _ => abort("expected second ExecuteTool")
  }
  let after_second = reduce(
    second_decl.next_state(),
    catalog,
    ToolCompleted(payload={
      effect_id: exec2,
      call_id: @kernel.CallId::unchecked("replay"),
      tool_name: @kernel.ToolName::unchecked("read"),
      arguments: Json::null(),
      outcome: Success(content="second", structured=None),
    }),
  )
  let ready2 = after_second.next_state()
  // The replayed wave commits normally: no invariant failure.
  assert_eq(ready2.phase(), ReadyForModel)
  // Transcript layout (probe-pinned): both tool messages are committed in
  // completion order next to the FIRST assistant that declared the call id;
  // the second assistant message follows them.
  let msgs = ready2.transcript().messages_snapshot()
  assert_eq(msgs.length(), 5)
  let layout = StringBuilder()
  for m in msgs {
    match m {
      UserMessage(..) => layout <+ "[U]"
      SystemMessage(..) => layout <+ "[S]"
      AssistantMessage(tool_calls~, ..) =>
        layout <+ "[A(\{tool_calls.length()})]"
      ToolMessage(call_id~, ..) => layout <+ "[T(\{call_id.to_string()})]"
    }
  }
  assert_eq(layout.to_string(), "[U][A(1)][T(replay)][T(replay)][A(1)]")
  // Tool-message outcomes are in completion order: first, then second.
  match (msgs[2], msgs[3]) {
    (
      ToolMessage(outcome=Success(content=c1, structured=None), ..),
      ToolMessage(outcome=Success(content=c2, structured=None), ..),
    ) => {
      assert_eq(c1, "first")
      assert_eq(c2, "second")
    }
    _ => fail("expected two Success tool messages for the replayed call id")
  }
  // The tool-result ledger keeps BOTH entries for the replayed id (no dedup,
  // no replacement) in completion order.
  let ledger_txt = ready2
    .tool_results_snapshot()
    .map(fn(rec) {
      let (cid, oc) = rec
      match oc {
        Success(content~, structured=None) => "\{cid.to_string()}=\{content}"
        _ => "\{cid.to_string()}=?"
      }
    })
    .join(";")
  assert_eq(ledger_txt, "replay=first;replay=second")
}
