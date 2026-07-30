///|
fn tk_opts() -> ChatOptions {
  { temperature: None, max_output_tokens: None }
}

///|
fn tk_call(id : String, name : String) -> ToolCall {
  {
    call_id: CallId::unchecked(id),
    name: ToolName::unchecked(name),
    arguments: Json::null(),
  }
}

// ---------------------------------------------------------------------------
// ScriptedModel: exhaustion + recording
// ---------------------------------------------------------------------------

///|
async test "tk_model_script_exhausts_loudly" {
  // A model with zero steps must fail on the first call, naming the call index.
  let model = ScriptedModel([])
  let result = Ok(model.chat_direct([], [], tk_opts())) catch { e => Err(e) }
  match result {
    Err(Transport(msg)) => assert_true(msg.contains("scripted_model_exhausted"))
    _ => fail("expected Transport error on exhausted script")
  }
}

///|
async test "tk_model_records_call_count" {
  let model = ScriptedModel([
    Respond(tk_stop_response("a")),
    Respond(tk_stop_response("b")),
  ])
  let _ = model.chat_direct([], [], tk_opts())
  let _ = model.chat_direct([], [], tk_opts())
  assert_eq(model.call_count(), 2)
  // Third call must fail (script exhausted), not replay.
  let third = Ok(model.chat_direct([], [], tk_opts())) catch { e => Err(e) }
  match third {
    Err(Transport(msg)) => assert_true(msg.contains("at call 3"))
    _ => fail("third call should fail with exhaustion, not replay")
  }
}

///|
async test "tk_model_records_received_messages_and_tools" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let msg = tk_user_msg("hello")
  let tool = tk_tool_def("greet", "say hi")
  let _ = model.chat_direct([msg], [tool], tk_opts())
  assert_eq(model.received_messages.length(), 1)
  assert_eq(model.received_tools.length(), 1)
  assert_eq(model.received_tools[0].length(), 1)
  assert_eq(model.received_tools[0][0].name.to_string(), "greet")
}

///|
async test "tk_model_records_chat_options_exactly" {
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let options : ChatOptions = {
    temperature: Some(0.25),
    max_output_tokens: Some(512),
  }
  let _ = model.chat_direct([], [], options)
  let recorded = model.options_received()
  assert_eq(recorded.length(), 1)
  assert_true(recorded[0] == options)
}

///|
async test "tk_model_stream_replays_exact_chunks_in_order" {
  let chunks : Array[StreamChunk] = [
    ReasoningDelta(token="think"),
    TextDelta(token="hello "),
    TextDelta(token="world"),
    Finish(reason="stop"),
  ]
  let response = tk_stop_response("hello world")
  let model = ScriptedModel([Stream(chunks~, response~)])
  // chat_streaming_direct drives chat with NoStream (M3.7) — to actually
  // observe chunks, drive chat with StreamMode::Stream directly.
  let observed : Array[StreamChunk] = []
  let host_chunks : Array[Json] = []
  let _ = (model as &@port.ModelPort).chat(
    [],
    [],
    tk_opts(),
    @types.Stream(fn(json) {
      host_chunks.push(json)
      // Decode the JSON chunk back to a StreamChunk for assertion comparison.
      let decoded : StreamChunk = match json {
        Json::Object(map) =>
          if map.contains("kind") {
            match map["kind"] {
              Json::String(v) if v == "text" =>
                try {
                  let t = map["token"]
                  match t {
                    Json::String(s) => TextDelta(token=s)
                    _ => TextDelta(token="")
                  }
                } catch {
                  _ => TextDelta(token="")
                }
              Json::String(v) if v == "reasoning" =>
                try {
                  let t = map["token"]
                  match t {
                    Json::String(s) => ReasoningDelta(token=s)
                    _ => ReasoningDelta(token="")
                  }
                } catch {
                  _ => ReasoningDelta(token="")
                }
              Json::String(v) if v == "finish" => Finish(reason="stop")
              _ => TextDelta(token="")
            }
          } else {
            TextDelta(token="")
          }
        _ => TextDelta(token="")
      }
      observed.push(decoded)
    }),
  )
  assert_eq(model.call_count(), 1)
  assert_eq(observed.length(), chunks.length())
  assert_true(model.received_chunks == chunks)
}

///|
async test "tk_model_stream_does_not_synthesize_chunks_for_response_step" {
  let model = ScriptedModel([Respond(tk_stop_response("do not split me"))])
  // R3 M3.7: a Respond step does not emit chunks; the host callback is
  // invoked only inside Stream steps. Driving chat with StreamMode::Stream
  // on a Respond step must not produce any chunks.
  let _ = (model as &@port.ModelPort).chat(
    [],
    [],
    tk_opts(),
    @types.Stream(fn(_json) { () }),
  )
  assert_true(model.received_chunks.is_empty())
}

///|
async test "tk_model_fail_step_raises_typed_model_error" {
  let model = ScriptedModel([Fail(ResponseParse("bad json"))])
  let result = Ok(model.chat_direct([], [], tk_opts())) catch { e => Err(e) }
  match result {
    Err(ResponseParse(msg)) => assert_true(msg.contains("bad json"))
    _ => fail("expected ResponseParse from Fail step")
  }
}

// ---------------------------------------------------------------------------
// RecordingToolProvider: routing + recording
// ---------------------------------------------------------------------------

///|
async test "tk_tool_records_execute_with_call_id" {
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("lookup", ScriptedToolOutcome::OutcomeOk(tk_ok_result("found"))),
  ])
  let provider = RecordingToolProvider([tk_tool_def("lookup", "")], outcomes)
  let call = tk_call("tc_42", "lookup")
  let result = provider.execute_direct("lookup", call)
  match result {
    Success(content~, ..) => assert_eq(content, "found")
    _ => fail("expected Success outcome")
  }
  assert_false(result.is_failure())
  let recs = provider.exec_records()
  assert_eq(recs.length(), 1)
  assert_eq(recs[0].call_id, "tc_42")
  assert_eq(recs[0].tool_name, "lookup")
  assert_eq(recs[0].requested_name, "lookup")
  assert_true(recs[0].arguments == Json::null())
}

///|
async test "tk_tool_unknown_raises_typed_error" {
  let provider = RecordingToolProvider([], Map::from_array([]))
  let call = tk_call("tc_1", "missing")
  let result = Ok(provider.execute_direct("missing", call)) catch {
    e => Err(e)
  }
  match result {
    Err(UnknownTool(msg)) => assert_true(msg.contains("missing"))
    _ => fail("expected UnknownTool for unconfigured tool")
  }
  let recs = provider.exec_records()
  assert_eq(recs.length(), 1)
  assert_eq(recs[0].call_id, "tc_1")
  match recs[0].outcome {
    OutcomeErr(UnknownTool(_)) => ()
    _ => fail("unknown tool attempt must be recorded before raising")
  }
}

///|
async test "tk_tool_records_raised_runtime_error" {
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("flaky", ScriptedToolOutcome::OutcomeErr(InvocationFailed("boom"))),
  ])
  let provider = RecordingToolProvider([tk_tool_def("flaky", "")], outcomes)
  let call = tk_call("tc_9", "flaky")
  let result = Ok(provider.execute_direct("flaky", call)) catch { e => Err(e) }
  match result {
    Err(InvocationFailed(_)) => ()
    _ => fail("expected InvocationFailed")
  }
  let recs = provider.exec_records()
  assert_eq(recs.length(), 1)
  // The recorded outcome must preserve the error category.
  match recs[0].outcome {
    OutcomeErr(InvocationFailed(_)) => ()
    _ => fail("recorded outcome should be OutcomeErr(InvocationFailed)")
  }
}

///|
async test "tk_tool_unified_trace_preserves_list_execute_order" {
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("lookup", ScriptedToolOutcome::OutcomeOk(tk_ok_result("found"))),
  ])
  let provider = RecordingToolProvider([tk_tool_def("lookup", "")], outcomes)
  let _ = provider.list_tools()
  let call = ToolCall::{
    call_id: CallId::unchecked("tc_order"),
    name: ToolName::unchecked("lookup"),
    arguments: Json::object(Map::from_array([("query", Json::string("x"))])),
  }
  let _ = provider.execute_direct("lookup", call)
  let ops = provider.ops()
  assert_eq(ops.length(), 2)
  assert_true(ops[0] is ListTools)
  match ops[1] {
    ExecuteTool(requested_name~, call~) => {
      assert_eq(requested_name, "lookup")
      assert_eq(call.call_id.to_string(), "tc_order")
      assert_true(
        call.arguments ==
        Json::object(Map::from_array([("query", Json::string("x"))])),
      )
    }
    _ => fail("second provider operation should be ExecuteTool")
  }
}

///|
async test "tk_tool_records_are_recursive_json_snapshots" {
  let structured_map : Map[String, Json] = Map::from_array([
    ("status", Json::string("original")),
  ])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    (
      "lookup",
      OutcomeOk(
        Success(content="found", structured=Some(Json::object(structured_map))),
      ),
    ),
  ])
  let provider = RecordingToolProvider([tk_tool_def("lookup", "")], outcomes)
  structured_map["status"] = Json::string("mutated after configuration")
  let argument_map : Map[String, Json] = Map::from_array([
    ("query", Json::string("original")),
  ])
  let call : ToolCall = {
    call_id: CallId::unchecked("tc_snapshot"),
    name: ToolName::unchecked("lookup"),
    arguments: Json::object(argument_map),
  }
  let result = provider.execute_direct("lookup", call)
  argument_map["query"] = Json::string("mutated after execute")
  guard result is Success(structured=Some(Object(result_map))) else {
    fail("expected structured object result")
  }
  assert_true(result_map["status"] == Json::string("original"))
  let records = provider.exec_records()
  guard records[0].arguments is Object(recorded_arguments) else {
    fail("expected recorded argument object")
  }
  assert_true(recorded_arguments["query"] == Json::string("original"))
  recorded_arguments["query"] = Json::string("mutated accessor result")
  let records_again = provider.exec_records()
  guard records_again[0].arguments is Object(recorded_arguments_again) else {
    fail("expected recorded argument object twice")
  }
  assert_true(recorded_arguments_again["query"] == Json::string("original"))
}

// ---------------------------------------------------------------------------
// RecordingSessionStore: metadata snapshots + configurable failures
// (SessionStore methods are non-async, non-raising Result returns — direct calls work.)
// ---------------------------------------------------------------------------

///|
async test "tk_store_records_save_metadata_snapshot" {
  let store = RecordingSessionStore()
  let meta = Map::from_array([
    ("user_role", Json::string("admin")),
    ("turn_count", Json::number(3.0)),
  ])
  let session : Session = { messages: [], metadata: meta }
  let _ = store.save("s1", session)
  let snaps = store.save_snapshots()
  assert_eq(snaps.length(), 1)
  let (id, saved_meta) = snaps[0]
  assert_eq(id, "s1")
  assert_true(saved_meta.contains("user_role"))
  assert_true(saved_meta["user_role"] == Json::string("admin"))
}

///|
async test "tk_store_load_unknown_returns_empty_session" {
  let store = RecordingSessionStore()
  try {
    let s = store.load("never_saved")
    assert_true(s.messages.is_empty())
    assert_true(s.metadata.length() == 0)
  } catch {
    _ => fail("load of unknown id should return empty session, not error")
  }
}

///|
async test "tk_store_load_and_seed_are_snapshot_isolated" {
  let store = RecordingSessionStore()
  let seeded : Session = {
    messages: [tk_user_msg("seed")],
    metadata: Map::from_array([("owner", Json::string("original"))]),
  }
  store.seed("isolated", seeded)
  seeded.messages.push(tk_user_msg("outside mutation"))
  seeded.metadata["owner"] = Json::string("outside mutation")
  let first = store.load("isolated") catch {
    _ => fail("seeded session should load")
  }
  assert_eq(first.messages.length(), 1)
  assert_true(first.metadata["owner"] == Json::string("original"))
  first.messages.push(tk_user_msg("loaded mutation"))
  first.metadata["owner"] = Json::string("loaded mutation")
  let second = store.load("isolated") catch {
    _ => fail("seeded session should load twice")
  }
  assert_eq(second.messages.length(), 1)
  assert_true(second.metadata["owner"] == Json::string("original"))
}

///|
async test "tk_store_snapshots_nested_json_and_tool_arguments" {
  let metadata_object : Map[String, Json] = Map::from_array([
    ("value", Json::string("metadata-original")),
  ])
  let argument_object : Map[String, Json] = Map::from_array([
    ("value", Json::string("argument-original")),
  ])
  let session : Session = {
    messages: [
      AssistantMessage(
        content=[],
        tool_calls=[
          {
            call_id: CallId::unchecked("tc_nested"),
            name: ToolName::unchecked("nested"),
            arguments: Json::object(argument_object),
          },
        ],
        reasoning=None,
        finish_reason=Stop,
      ),
    ],
    metadata: Map::from_array([("nested", Json::object(metadata_object))]),
  }
  let store = RecordingSessionStore()
  store.seed("nested", session)
  metadata_object["value"] = Json::string("metadata-outside")
  argument_object["value"] = Json::string("argument-outside")
  let first = store.load("nested") catch {
    _ => fail("expected nested session")
  }
  guard first.metadata["nested"] is Object(first_metadata) else {
    fail("expected nested metadata object")
  }
  guard first.messages[0]
    is AssistantMessage(tool_calls=[{ arguments: Object(first_arguments), .. }]) else {
    fail("expected nested arguments object")
  }
  assert_true(first_metadata["value"] == Json::string("metadata-original"))
  assert_true(first_arguments["value"] == Json::string("argument-original"))
  first_metadata["value"] = Json::string("metadata-loaded")
  first_arguments["value"] = Json::string("argument-loaded")
  let second = store.load("nested") catch {
    _ => fail("expected nested session twice")
  }
  guard second.metadata["nested"] is Object(second_metadata) else {
    fail("expected second nested metadata object")
  }
  guard second.messages[0]
    is AssistantMessage(
      tool_calls=[{ arguments: Object(second_arguments), .. }]
    ) else {
    fail("expected second nested arguments object")
  }
  assert_true(second_metadata["value"] == Json::string("metadata-original"))
  assert_true(second_arguments["value"] == Json::string("argument-original"))
}

///|
async test "tk_store_operation_accessors_return_recursive_snapshots" {
  let nested : Map[String, Json] = Map::from_array([
    ("value", Json::string("original")),
  ])
  let store = RecordingSessionStore()
  let _ = store.save("ops", {
    messages: [],
    metadata: Map::from_array([("nested", Json::object(nested))]),
  })
  let first = store.ops()
  match first[0] {
    OpSave(metadata~, ..) =>
      match metadata["nested"] {
        Object(values) => values["value"] = Json::string("mutated accessor")
        _ => fail("expected nested operation metadata")
      }
    _ => fail("expected save operation")
  }
  let second = store.ops()
  match second[0] {
    OpSave(metadata~, ..) =>
      match metadata["nested"] {
        Object(values) =>
          assert_true(values["value"] == Json::string("original"))
        _ => fail("expected second nested operation metadata")
      }
    _ => fail("expected second save operation")
  }
}

///|
async test "tk_store_fail_save_returns_typed_error" {
  let store = RecordingSessionStore()
  store.fail_save("broken")
  let result = Ok(
    store.save("broken", { messages: [], metadata: Map::from_array([]) }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(SessionError::Save(_)) => ()
    _ => fail("expected SessionError::Save for configured failure")
  }
}

///|
async test "tk_store_fail_load_returns_typed_error" {
  let store = RecordingSessionStore()
  store.fail_load("dead", Load("disk gone"))
  let result = Ok(store.load("dead")) catch { e => Err(e) }
  match result {
    Err(Load(msg)) => assert_true(msg.contains("disk gone"))
    _ => fail("expected configured Load failure")
  }
}

// ---------------------------------------------------------------------------
// RecordingObserver: full event order (Observer is non-async — direct calls work.)
// ---------------------------------------------------------------------------

///|
async test "tk_observer_preserves_event_order" {
  let obs = RecordingObserver()
  obs.on_event(TurnStarted)
  obs.on_event(ToolCallPending(tk_call("c1", "t")))
  obs.on_event(TurnCompleted)
  let events = obs.events()
  assert_eq(events.length(), 3)
  assert_true(events[0] is TurnStarted)
  assert_true(events[2] is TurnCompleted)
}

///|
async test "tk_observer_event_accessor_is_deep_snapshot" {
  let obs = RecordingObserver()
  // R3 M3.7: pick an AssistantMessage whose content array is mutable so we
  // can still prove the observer took a deep copy (SystemMessage/UserMessage
  // also have mutable content arrays; either works the same way).
  let message : Message = AssistantMessage(
    content=[Text("original")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
  obs.on_event(ModelResponseReceived(message~, usage=None))
  // Mutate the caller-side content array AFTER handing the message off.
  // The recorded event must not see this mutation.
  match message {
    AssistantMessage(content~, ..) => content.push(Text("outside mutation"))
    _ => fail("expected AssistantMessage")
  }
  let first = obs.events()
  match first[0] {
    ModelResponseReceived(message~, ..) =>
      match message {
        AssistantMessage(content~, ..) =>
          content.push(Text("accessor mutation"))
        _ => fail("expected AssistantMessage in recorded event")
      }
    _ => fail("expected model response event")
  }
  let second = obs.events()
  match second[0] {
    ModelResponseReceived(message~, ..) =>
      match message {
        AssistantMessage(content~, ..) => {
          assert_eq(content.length(), 1)
          assert_true(content[0] == Text("original"))
        }
        _ => fail("expected second AssistantMessage")
      }
    _ => fail("expected second model response event")
  }
}

// ---------------------------------------------------------------------------
// RecordingHook: stage history + configured decisions
// ---------------------------------------------------------------------------

///|
test "tk_hook_records_stage_and_configured_abort" {
  let hook = RecordingHook()
  hook.abort_when("before_model", "policy rejected model call")
  let result : Result[Array[@kernel.Message], String] = try
    hook.before_model([])
  catch {
    @port.HookAbort::Aborted(reason~) => Err(reason)
  } noraise {
    _ => Ok([])
  }
  match result {
    Err(message) => assert_eq(message, "policy rejected model call")
    _ => fail("configured hook abort should return error")
  }
  let records = hook.records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].label, "before_model")
  match records[0].outcome {
    RecordedHookOutcome2::AbortedWith(message) =>
      assert_eq(message, "policy rejected model call")
    _ => fail("recorded hook outcome should be AbortedWith")
  }
}

///|
test "tk_hook_records_stage_and_configured_deferral" {
  let hook = RecordingHook()
  hook.defer_when("tc_defer", "approval required")
  let call = @kernel.ToolCall::{
    call_id: @kernel.CallId::unchecked("tc_defer"),
    name: @kernel.ToolName::unchecked("dangerous"),
    arguments: Json::null(),
  }
  let result = hook.before_tool(call)
  match result {
    @port.ToolHookDecision::Defer(reason~) =>
      assert_eq(reason, "approval required")
    _ => fail("configured hook deferral should return Defer")
  }
  let records = hook.records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].label, "before_tool")
  match records[0].outcome {
    RecordedHookOutcome2::DeferredWith(reason) =>
      assert_eq(reason, "approval required")
    _ => fail("recorded hook outcome should be DeferredWith")
  }
}

///|
test "tk_hook_records_pass_through_outcome" {
  let hook = RecordingHook()
  let msgs = [
    @kernel.Message::UserMessage(content=[@kernel.Content::Text("hello")]),
  ]
  let returned = hook.before_model(msgs)
  assert_eq(returned.length(), 1)
  let records = hook.records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].label, "before_model")
  match records[0].outcome {
    RecordedHookOutcome2::PassedThrough => ()
    _ => fail("recorded hook outcome should be PassedThrough")
  }
}

///|
test "tk_hook_record_accessor_is_deep_snapshot" {
  let hook = RecordingHook()
  let msg = @kernel.Message::UserMessage(content=[
    @kernel.Content::Text("original"),
  ])
  let _ = hook.before_model([msg])
  let first = hook.records()
  assert_eq(first[0].label, "before_model")
  match first[0].outcome {
    RecordedHookOutcome2::PassedThrough => ()
    _ => fail("expected PassedThrough outcome")
  }
  // Mutate the returned array to prove snapshot isolation
  first[0] = HookRecord2::{ label: "tampered", outcome: PassedThrough }
  let second = hook.records()
  assert_eq(second.length(), 1)
  assert_eq(second[0].label, "before_model")
  match second[0].outcome {
    RecordedHookOutcome2::PassedThrough => ()
    _ => fail("expected second PassedThrough outcome")
  }
}

// ---------------------------------------------------------------------------
// Trace assertions
// ---------------------------------------------------------------------------

///|
async test "tk_assert_events_eq_passes_on_match" {
  let expected : Array[TurnEvent] = [
    TurnEvent::TurnStarted,
    TurnEvent::TurnCompleted,
  ]
  let actual : Array[TurnEvent] = [
    TurnEvent::TurnStarted,
    TurnEvent::TurnCompleted,
  ]
  assert_events_eq(expected, actual)
}

///|
async test "tk_assert_events_contain_finds_subsequence" {
  let hay : Array[TurnEvent] = [
    TurnEvent::TurnStarted,
    TurnEvent::ToolCallPending(tk_call("c1", "t")),
    TurnEvent::TurnCompleted,
  ]
  let needle : Array[TurnEvent] = [
    TurnEvent::ToolCallPending(tk_call("c1", "t")),
    TurnEvent::TurnCompleted,
  ]
  assert_events_contain(hay, needle)
}

///|
test "tk_trace_diff_detects_missing_event_at_first_index" {
  let mismatch = event_trace_mismatch(
    [TurnEvent::TurnStarted, TurnEvent::TurnCompleted],
    [TurnEvent::TurnStarted],
  )
  match mismatch {
    Some(message) => {
      assert_true(message.contains("index 1"))
      assert_true(message.contains("expected TurnCompleted"))
      assert_true(message.contains("got <end>"))
    }
    None => fail("missing event must produce a trace mismatch")
  }
}

///|
test "tk_trace_diff_detects_duplicate_event_at_first_index" {
  let mismatch = event_trace_mismatch(
    [TurnEvent::TurnStarted, TurnEvent::TurnCompleted],
    [TurnEvent::TurnStarted, TurnEvent::TurnStarted, TurnEvent::TurnCompleted],
  )
  match mismatch {
    Some(message) => {
      assert_true(message.contains("index 1"))
      assert_true(message.contains("expected TurnCompleted"))
      assert_true(message.contains("got TurnStarted"))
    }
    None => fail("duplicate event must produce a trace mismatch")
  }
}

///|
test "tk_trace_diff_detects_out_of_order_event_at_first_index" {
  let mismatch = event_trace_mismatch(
    [
      TurnEvent::TurnStarted,
      TurnEvent::ToolCallPending(tk_call("c1", "tool")),
      TurnEvent::TurnCompleted,
    ],
    [
      TurnEvent::ToolCallPending(tk_call("c1", "tool")),
      TurnEvent::TurnStarted,
      TurnEvent::TurnCompleted,
    ],
  )
  match mismatch {
    Some(message) => {
      assert_true(message.contains("index 0"))
      assert_true(message.contains("expected TurnStarted"))
      assert_true(message.contains("got ToolCallPending(c1)"))
    }
    None => fail("out-of-order event must produce a trace mismatch")
  }
}
