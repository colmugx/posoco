///|
fn compact_context_anchor(raw : Json) -> @kernel.Message {
  AssistantMessage(
    content=[],
    tool_calls=[],
    reasoning=Some({ content: "", raw: Some(raw), }),
    finish_reason=Stop,
  )
}

///|
fn assert_compact_context_unknown(state : @types.ContextState) -> Unit raise {
  assert_eq(state.source, Unknown)
  assert_eq(state.last_measured_tokens, None)
  assert_eq(state.estimated_added_tokens, 0)
  assert_eq(state.window_tokens, Some(100))
  assert_eq(state.compact_threshold, 0.9)
}

///|
async fn check_manual_compact_context(
  session_id : String,
  compacted : Array[@kernel.Message],
) -> Unit {
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Compact(result={
      compacted_messages: compacted,
      mode: Replace,
    }),
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_stop_response("no usage yet"),
    ),
    @testkit.ScriptedModelStep::Respond(wave3_stop_with_usage("measured", 37)),
  ])
  let store = @testkit.RecordingSessionPort()
  store.seed(session_id, {
    messages: [@testkit.tk_user_msg("earlier")],
    metadata: policy_context_metadata(
      session_id~,
      measured=95,
      window=100,
      reading_count=1,
    ),
  })
  let observer = @testkit.RecordingObserver()
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config={
      ..agent_config(max_tool_rounds=Some(10)),
      model_context_window: Some(100),
      compact_threshold: Some(0.9),
    },
  )
  ignore(agent.compact_session(session_id))
  guard agent.context_state(session_id) is Some(current) else {
    fail("expected context state after manual compact")
  }
  assert_compact_context_unknown(current)
  assert_eq(current.reading_message_count, compacted.length())
  guard @types.ContextState::from_metadata(store.store[session_id].metadata)
    is Some(saved) else {
    fail("expected persisted context state after manual compact")
  }
  assert_compact_context_unknown(saved)
  let mut projected = None
  for event in observer.events() {
    match event {
      ContextStateUpdated(state~) => projected = Some(state)
      _ => ()
    }
  }
  guard projected is Some(updated) else {
    fail("expected context state event after manual compact")
  }
  assert_compact_context_unknown(updated)
  ignore(agent.run_turn(@testkit.tk_user_msg("continue"), session_id))
  guard agent.context_state(session_id) is Some(unmeasured) else {
    fail("expected context state without new usage")
  }
  assert_compact_context_unknown(unmeasured)
  ignore(agent.run_turn(@testkit.tk_user_msg("again"), session_id))
  guard agent.context_state(session_id) is Some(measured) else {
    fail("expected context state after genuine model usage")
  }
  assert_eq(measured.source, Measured)
  assert_eq(measured.last_measured_tokens, Some(37))
  assert_eq(measured.window_tokens, Some(100))
  assert_true(model.received_messages[0][0] == compacted[0])
}

///|
async test "compact_context/manual opaque-only window stays unknown until genuine usage" {
  check_manual_compact_context("compact-context-manual-opaque", [
    compact_context_anchor(Json::string("opaque replay state")),
  ])
}

///|
async test "compact_context/manual mixed window stays unknown until genuine usage" {
  check_manual_compact_context("compact-context-manual-mixed", [
    @testkit.tk_user_msg("retained visible text"),
    compact_context_anchor({ "provider_state": ["opaque replay state"] }),
    tk_assistant_msg_e2e("retained answer"),
  ])
}

///|
async fn check_auto_compact_context(
  session_id : String,
  compacted : Array[@kernel.Message],
) -> Unit {
  let model = auto_compact_e2e_model(
    [
      @testkit.ScriptedModelStep::Respond(scope_test_tool_call_with_usage(95)),
      @testkit.ScriptedModelStep::Respond(
        @testkit.tk_stop_response("no usage yet"),
      ),
      @testkit.ScriptedModelStep::Respond(wave3_stop_with_usage("measured", 37)),
    ],
    compacted,
  )
  let store = @testkit.RecordingSessionPort()
  let observer = @testkit.RecordingObserver()
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(id="tools", tools=[policy_tools()]),
      @testkit.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@testkit.tk_user_msg("start"), session_id))
  assert_eq(model.compact_calls.val, 1)
  guard agent.context_state(session_id) is Some(current) else {
    fail("expected context state after automatic compact")
  }
  assert_compact_context_unknown(current)
  assert_eq(current.reading_message_count, compacted.length())
  guard @types.ContextState::from_metadata(store.store[session_id].metadata)
    is Some(saved) else {
    fail("expected persisted context state after automatic compact")
  }
  assert_compact_context_unknown(saved)
  let mut projected = None
  for event in observer.events() {
    match event {
      ContextStateUpdated(state~) => projected = Some(state)
      _ => ()
    }
  }
  guard projected is Some(updated) else {
    fail("expected context state event after automatic compact")
  }
  assert_compact_context_unknown(updated)
  assert_true(model.seen_chats()[1] == compacted)
  ignore(agent.run_turn(@testkit.tk_user_msg("again"), session_id))
  guard agent.context_state(session_id) is Some(measured) else {
    fail("expected context state after genuine model usage")
  }
  assert_eq(measured.source, Measured)
  assert_eq(measured.last_measured_tokens, Some(37))
  assert_eq(measured.window_tokens, Some(100))
  assert_eq(model.compact_calls.val, 1)
}

///|
async test "compact_context/auto opaque-only window stays unknown until genuine usage" {
  check_auto_compact_context("compact-context-auto-opaque", [
    compact_context_anchor(["opaque replay state"]),
  ])
}

///|
async test "compact_context/auto mixed window stays unknown until genuine usage" {
  check_auto_compact_context("compact-context-auto-mixed", [
    @testkit.tk_user_msg("retained visible text"),
    compact_context_anchor({ "provider_state": "opaque replay state" }),
    tk_assistant_msg_e2e("retained answer"),
  ])
}

///|
async test "compact_context/empty raw state preserves canonical summary estimate" {
  let empty_states : Array[Json] = [
    Json::null(),
    Json::array([]),
    Json::object(Map::from_array([])),
    Json::string(""),
  ]
  for raw in empty_states {
    let model = @testkit.ScriptedModel([
      @testkit.ScriptedModelStep::Compact(result={
        compacted_messages: [
          compact_context_anchor(raw),
          @testkit.tk_user_msg("summary"),
        ],
        mode: Replace,
      }),
    ])
    let store = @testkit.RecordingSessionPort()
    store.seed("compact-context-empty", {
      messages: [@testkit.tk_user_msg("earlier")],
      metadata: Map::from_array([]),
    })
    let agent = Agent(
      exts=[
        @testkit.tk_ext(id="model", model=Some(model)),
        @testkit.tk_ext(id="io", sessions=[store]),
      ],
      config=agent_config(max_tool_rounds=Some(10)),
    )
    ignore(agent.compact_session("compact-context-empty"))
    guard agent.context_state("compact-context-empty") is Some(current) else {
      fail("expected context state after canonical summary compact")
    }
    assert_eq(current.source, Estimated)
    assert_eq(current.last_measured_tokens, Some(1))
  }
}
