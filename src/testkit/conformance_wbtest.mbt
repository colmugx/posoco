///|
fn tk_opts() -> @types.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn tk_call(id : String, name : String) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked(name),
    arguments: Json::null(),
  }
}

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
async test "tk_model_stream_replays_exact_chunks_in_order" {
  let chunks : Array[@types.StreamChunk] = [
    ReasoningDelta(token="think"),
    TextDelta(token="hello "),
    TextDelta(token="world"),
    Finish(reason="stop"),
  ]
  let response = tk_stop_response("hello world")
  let model = ScriptedModel([Stream(chunks~, response~)])
  // chat_streaming_direct drives chat with NoStream — to actually
  // observe chunks, drive chat with StreamMode::Stream directly.
  let observed : Array[@types.StreamChunk] = []
  let _ = (model as &@port.ModelPort).chat(
    tk_scope(),
    [],
    [],
    tk_opts(),
    Stream(fn(chunk) { observed.push(chunk) }),
  )
  assert_eq(model.call_count(), 1)
  assert_eq(observed.length(), chunks.length())
  assert_true(model.received_chunks == chunks)
}

///|
async test "tk_model_stream_does_not_synthesize_chunks_for_response_step" {
  let model = ScriptedModel([Respond(tk_stop_response("do not split me"))])
  // A Respond step does not emit chunks; the host callback is
  // invoked only inside Stream steps. Driving chat with StreamMode::Stream
  // on a Respond step must not produce any chunks.
  let _ = (model as &@port.ModelPort).chat(
    tk_scope(),
    [],
    [],
    tk_opts(),
    Stream(fn(_chunk) { () }),
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

///|
/// Storage and retrieval side of the port contract, through the testkit fake
/// every memory test composes: writes route through `store` (ticketed),
/// queries through `search`, removals through `delete` — all recorded in
/// call order with their arguments.
async test "tk_memory_port_store_search_delete_contract" {
  let mem = ScriptedMemoryPort(inbounds=[Some("fact")], search_script=[
    Some("hit"),
  ])
  let port = mem as &@port.MemoryPort
  let ticket = port.store(content="entry", metadata=Map::from_array([]))
  assert_eq(ticket, "scripted-0")
  let second = port.store(content="another", metadata=Map::from_array([]))
  assert_eq(second, "scripted-1")
  let found = port.search(query="entry")
  assert_eq(found, Some("hit"))
  port.delete(ticket)
  assert_eq(mem.received_stores().length(), 2)
  let (content, metadata) = mem.received_stores()[0]
  assert_eq(content, "entry")
  assert_eq(metadata.length(), 0)
  assert_eq(mem.received_deletes(), ["scripted-0"])
  assert_eq(mem.received_searches(), [("entry", None)])
  // Past the script, search degrades to a clean no-hit.
  assert_eq(port.search(query="anything"), None)
}

///|
async test "tk_tool_unknown_raises_typed_error" {
  let provider = RecordingToolProvider([], Map::from_array([]))
  let call = tk_call("tc_1", "missing")
  let result = Ok(provider.execute_direct(call)) catch { e => Err(e) }
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
async test "tk_store_load_unknown_returns_empty_session" {
  let store = RecordingSessionPort()
  try {
    let s = store.load("never_saved")
    assert_true(s.messages.is_empty())
    assert_true(s.metadata.length() == 0)
  } catch {
    _ => fail("load of unknown id should return empty session, not error")
  }
}

///|
async test "tk_store_fail_save_returns_typed_error" {
  let store = RecordingSessionPort()
  store.fail_save("broken")
  let result = Ok(
    store.save("broken", { messages: [], metadata: Map::from_array([]), }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(Save(_)) => ()
    _ => fail("expected SessionError::Save for configured failure")
  }
}

///|
async test "tk_store_fail_load_returns_typed_error" {
  let store = RecordingSessionPort()
  store.fail_load("dead", Load("disk gone"))
  let result = Ok(store.load("dead")) catch { e => Err(e) }
  match result {
    Err(Load(msg)) => assert_true(msg.contains("disk gone"))
    _ => fail("expected configured Load failure")
  }
}

///|
async test "tk_hook_records_stage_and_configured_abort" {
  let hook = RecordingHook()
  hook.abort_when("before_model", "policy rejected model call")
  let result : Result[Array[@kernel.Message], String] = try
    hook.before_model([])
  catch {
    Aborted(reason~) => Err(reason)
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
    AbortedWith(message) => assert_eq(message, "policy rejected model call")
    _ => fail("recorded hook outcome should be AbortedWith")
  }
}

///|
async test "tk_hook_records_stage_and_configured_deferral" {
  let hook = RecordingHook()
  hook.defer_when("tc_defer", "approval required")
  let call = @kernel.ToolCall::{
    call_id: @kernel.CallId::unchecked("tc_defer"),
    name: @kernel.ToolName::unchecked("dangerous"),
    arguments: Json::null(),
  }
  let result = hook.before_tool(call)
  match result {
    Defer(reason~) => assert_eq(reason, "approval required")
    _ => fail("configured hook deferral should return Defer")
  }
  let records = hook.records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].label, "before_tool")
  match records[0].outcome {
    DeferredWith(reason) => assert_eq(reason, "approval required")
    _ => fail("recorded hook outcome should be DeferredWith")
  }
}

///|
test "tk_trace_diff_detects_missing_event_at_first_index" {
  let mismatch = event_trace_mismatch([TurnStarted, TurnCompleted], [
    TurnStarted,
  ])
  match mismatch {
    Some(message) => {
      assert_true(message.contains("index 1"))
      assert_true(message.contains("expected TurnCompleted"))
      assert_true(message.contains("got <end>"))
    }
    None => fail("missing event must produce a trace mismatch")
  }
}
