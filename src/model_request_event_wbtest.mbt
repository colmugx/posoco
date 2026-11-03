///|
/// `ModelRequestStarted` projection tests: the observer-visible request
/// anchor fires once per model step, after the turn (or the previous tool
/// wave) and before any chunk of that step can arrive.

///|
async test "model_request_started/brackets_every_step_before_chunks" {
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Stream(
      chunks=[@types.StreamChunk::TextDelta(token="plan")],
      response=@testkit.tk_tool_call_response("echo", "call_mr", Json::null()),
    ),
    @testkit.ScriptedModelStep::Stream(
      chunks=[@types.StreamChunk::TextDelta(token="done")],
      response=@testkit.tk_stop_response("ok"),
    ),
  ])
  let tools = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @testkit.ScriptedToolOutcome::OutcomeOk(@testkit.tk_ok_result("ok")),
      ),
    ]),
  )
  let observer = @testkit.RecordingObserver()
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model)),
      @testkit.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@testkit.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@testkit.tk_user_msg("hi"), "s_request_anchor"))
  let events = observer.events()
  // One anchor per model step: before the turn's first chunk, and again
  // after the tool wave — never from the response boundary itself.
  let request_indices = []
  let chunk_indices_after_first_request : Array[Int32] = []
  let mut saw_first_request = false
  for i, event in events {
    match event {
      ModelRequestStarted => request_indices.push(i)
      StreamChunkReceived(..) =>
        if saw_first_request {
          chunk_indices_after_first_request.push(i)
        }
      _ => ()
    }
    if event is ModelRequestStarted {
      saw_first_request = true
    }
  }
  assert_eq(request_indices.length(), 2)
  // The first anchor precedes the first chunk of the turn.
  guard chunk_indices_after_first_request.length() > 0 else {
    fail("expected streamed chunks after the first request anchor")
  }
  assert_true(request_indices[0] < chunk_indices_after_first_request[0])
  // The second anchor lands after the tool wave and before the second
  // step's chunk — its position sits between the two response events.
  let response_indices = []
  for i, event in events {
    if event is ModelResponseReceived(..) {
      response_indices.push(i)
    }
  }
  assert_eq(response_indices.length(), 2)
  assert_true(response_indices[0] < request_indices[1])
  assert_true(request_indices[1] < response_indices[1])
}
