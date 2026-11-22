///|
priv struct WakeupCheckpointModel {
  script : @test_support.ScriptedModel
  capture : WakeupCapture
  store : @test_support.RecordingSessionPort
  mut at_continuation : @types.Session?
}

///|
impl @port.ModelPort for WakeupCheckpointModel with fn chat(
  self,
  scope,
  messages,
  tools,
  options,
  stream,
) {
  let session = scope.session_id.to_string()
  match self.script.call_count() {
    0 =>
      match self.capture.wakeup {
        Some(port) =>
          match port.request(session~, tag="notice", note="check again") {
            Ok(_) => ()
            Err(error) => raise ResponseParse("wakeup rejected: \{repr(error)}")
          }
        None => raise ResponseParse("missing wakeup capability")
      }
    // Capture before the second response can trigger a terminal save.
    1 =>
      self.at_continuation = self.store.store
        .get(session)
        .map(fn(stored) {
          {
            messages: @message_snapshot.snapshot_messages(stored.messages),
            metadata: @message_snapshot.snapshot_metadata(stored.metadata),
          }
        })
    _ => ()
  }
  self.script.chat(scope, messages, tools, options, stream)
}

///|
impl @port.ModelPort for WakeupCheckpointModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) {
  raise ResponseParse("unexpected compact")
}

///|
impl @port.ModelPort for WakeupCheckpointModel with fn provider_config(_self) {
  @port.ProviderConfig::empty()
}

///|
async test "wakeup checkpoint/trimmed stop is persisted before the continuation enters" {
  let session = "wakeup-trimmed-stop"
  let old_input = @test_support.tk_user_msg("old input")
  let old_reply : @kernel.Message = AssistantMessage(
    content=[Text("old reply")],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
  let input = @test_support.tk_user_msg("current input")
  let metadata = Map::from_array([("label", Json::string("keep me"))])
  let store = @test_support.RecordingSessionPort()
  store.seed(session, { messages: [old_input, old_reply], metadata, })
  let stop = @test_support.tk_stop_response("initial stop")
  let script = @test_support.ScriptedModel([
    Respond({ ..stop, processed_messages: [input], }),
    Respond(@test_support.tk_stop_response("continued")),
  ])
  let capture = WakeupCapture::WakeupCapture()
  let model = WakeupCheckpointModel::{
    script,
    capture,
    store,
    at_continuation: None,
  }
  let observer = SignalObserver::SignalObserver()
  let agent = wakeup_capture_agent(capture, model, store, observer)
  let result = agent.run_scoped(async fn(agent) {
    agent.set_active_session(Some(session))
    agent.run_turn(input, session)
  })
  assert_true(
    result.message is AssistantMessage(content=[Text("continued")], ..),
  )
  assert_eq(operation_events(observer, "operation_started").length(), 1)
  let canonical : Array[@kernel.Message] = [
    input,
    AssistantMessage(
      content=[Text("initial stop")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
    ),
    @test_support.tk_user_msg("[posoco-wakeup tag=\"notice\"] check again"),
  ]
  assert_eq(script.received_messages, [[old_input, old_reply, input], canonical])
  guard model.at_continuation is Some(stored) else {
    fail("expected a persisted session at continuation entry")
  }
  assert_eq(stored.messages, canonical)
  assert_eq(stored.metadata, metadata)
}

///|
async test "wakeup checkpoint/a tool request after continuation still exceeds a zero round budget" {
  let session = "wakeup-zero-tool-rounds"
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("initial stop")),
    Respond(@test_support.tk_tool_call_response("probe", "after-wakeup", {})),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "test tool")],
    Map::from_array([("probe", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let capture = WakeupCapture::WakeupCapture()
  let store = @test_support.RecordingSessionPort()
  let observer = SignalObserver::SignalObserver()
  let model = WakeupCheckpointModel::{
    script,
    capture,
    store,
    at_continuation: None,
  }
  let agent = wakeup_capture_agent(
    capture,
    model,
    store,
    observer,
    tools=[tools],
    max_tool_rounds=0,
  )
  let result = agent.run_scoped(async fn(agent) {
    agent.set_active_session(Some(session))
    Ok(agent.run_turn(@test_support.tk_user_msg("start"), session)) catch {
      error => Err(error)
    }
  })
  guard result is Err(ToolLoopExceeded(consumed=1, limit=0)) else {
    fail("expected ToolLoopExceeded(consumed=1, limit=0), got \{repr(result)}")
  }
  assert_eq(script.call_count(), 2)
  assert_true(
    acceptance_user_message_contains(script.received_messages[1], "check again"),
  )
  assert_eq(operation_events(observer, "operation_started").length(), 1)
  assert_eq(tools.exec_records().length(), 0)
}
