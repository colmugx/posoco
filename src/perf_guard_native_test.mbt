///|
/// Permanent wall-clock tripwires for the ultraspeed performance fixes.
/// Native-only so @async.now() is meaningful; thresholds are generous
/// (~100x over observed post-fix costs) to keep CI stable.

///|
/// StreamAccumulator text path: 100k × 4-char TextDelta pushes must complete
/// in well under 2s. Catches an O(L²) recurrence where repeated string
/// concatenation copied the whole prefix on every push.
async test "perf guard: stream accumulator text push is sub-quadratic" {
  let n = 100_000
  let acc = @types.StreamAccumulator()
  let t0 = @async.now()
  for _i in 0..<n {
    acc.push(@types.TextDelta(token="abcd"))
  }
  let dt = @async.now() - t0
  assert_true(
    dt < 2000,
    msg="100k TextDelta pushes took " + dt.to_string() + "ms, expected < 2000ms",
  )
  assert_eq(acc.text().length(), n * 4)
}

///|
/// Reducer wave commit path: 8 waves × 4 parallel tools over a growing
/// transcript must complete in a few seconds. Catches an O(K·N) rebuild
/// recurrence where each tool result triggered a full transcript copy.
async test "perf guard: multi-wave tool commit is linear in transcript" {
  let waves = 8
  let tools_per_wave = 4
  let steps : Array[@posoco.ScriptedModelStep] = []
  for wave in 0..<waves {
    let calls : Array[@kernel.ToolCall] = []
    for i in 0..<tools_per_wave {
      let id = "w" + wave.to_string() + "_t" + i.to_string()
      calls.push({
        call_id: @kernel.CallId::unchecked(id),
        name: @kernel.ToolName::unchecked("echo"),
        arguments: Json::object(Map::from_array([])),
      })
    }
    let completion : @kernel.Completion = @kernel.Completion(
      content=[],
      tool_calls=calls,
      reasoning=None,
      finish_reason=@kernel.ToolCalls,
      usage=None,
    )
    steps.push(@posoco.Respond({ completion, processed_messages: [] }))
  }
  steps.push(@posoco.Respond(@posoco.tk_stop_response("done")))

  let outcomes : Map[String, @posoco.ScriptedToolOutcome] = Map::from_array([])
  outcomes["echo"] = @posoco.OutcomeOk(@posoco.tk_ok_result("ok"))
  let provider = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("echo", "echo tool")],
    outcomes,
  )
  let store = @posoco.RecordingSessionStore()
  let config : @posoco.AgentConfig = {
    max_tool_rounds: Some(waves + 2),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
    system_prompt: None,
  }
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(@posoco.ScriptedModel(steps))),
      @posoco.tk_ext(id="io", tools=[provider], sessions=[store]),
    ],
    config~,
  )

  let t0 = @async.now()
  let result = agent.run_turn(@posoco.tk_user_msg("go"), "perf_wave")
  let dt = @async.now() - t0
  ignore(result)
  assert_true(
    dt < 5000,
    msg="8 waves x 4 tools took " + dt.to_string() + "ms, expected < 5000ms",
  )
}

///|
/// Streaming turn: 50k chunks through a ScriptedModel+RecordingObserver agent
/// turn must complete < 5s. Catches accidental synchronous fan-out or
/// per-chunk persistence recurrence. Telemetry is intentionally lossy under
/// overload; this guard checks wall time, not event counts.
async test "perf guard: streaming turn drains 50k chunks fast" {
  let n = 50_000
  let chunks : Array[@types.StreamChunk] = []
  for _i in 0..<n {
    chunks.push(@types.TextDelta(token="abcd"))
  }
  let model = @posoco.ScriptedModel([
    @posoco.Stream(chunks~, response=@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore()
  let observer = @posoco.RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=@posoco.tk_config(),
  )

  let t0 = @async.now()
  let result = agent.run_turn(@posoco.tk_user_msg("hello"), "s2")
  let dt = @async.now() - t0
  ignore(result)
  assert_true(
    dt < 5000,
    msg="50k chunk streaming turn took " +
      dt.to_string() +
      "ms, expected < 5000ms",
  )
}
