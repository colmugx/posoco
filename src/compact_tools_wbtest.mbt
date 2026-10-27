///|
using @support {compact_tools_seed}

///|
/// Records compact inputs independently of chat, including the durable
/// window at entry so failures can be checked for accidental rewrites.
struct CompactToolsModel {
  inner : ScriptedModel
  seen_tools : Array[Array[@kernel.ToolDef]]
  seen_triggers : Array[@kernel.CompactTrigger]
  committed_at_compact : Array[Array[@kernel.Message]]
  store : RecordingSessionStore
  fail_compact : Bool
  seen_messages : Array[Array[@kernel.Message]]
}

///|
impl @port.ModelPort for CompactToolsModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  (self.inner as &@port.ModelPort).chat(scope, messages, tools, options, stream)
}

///|
impl @port.ModelPort for CompactToolsModel with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.seen_tools.push(tools.map(testkit_snapshot_tool_def))
  self.seen_triggers.push(trigger)
  self.committed_at_compact.push(
    snapshot_messages(self.store.store[scope.session_id.to_string()].messages),
  )
  ignore(options)
  self.seen_messages.push(snapshot_messages(messages.to_owned()))
  if self.fail_compact {
    raise Transport("compact rejected")
  }
  policy_replace_result()
}

///|
impl @port.ModelPort for CompactToolsModel with fn provider_config(_self) -> @port.ProviderConfig {
  policy_reported(context_window=Some(100), compact_threshold=Some(0.9))
}

///|
fn compact_tools_model(
  store : RecordingSessionStore,
  fail_compact : Bool,
  chats : Array[ScriptedModelStep],
) -> CompactToolsModel {
  {
    inner: ScriptedModel(chats),
    seen_tools: [],
    seen_triggers: [],
    committed_at_compact: [],
    store,
    fail_compact,
    seen_messages: [],
  }
}

///|
fn compact_tools_assert(
  model : CompactToolsModel,
  expected : Array[@kernel.ToolDef],
  trigger : @kernel.CompactTrigger,
) -> Unit raise {
  assert_eq(model.seen_tools.length(), 1)
  assert_eq(model.seen_triggers[0], trigger)
  assert_eq(model.seen_tools[0].length(), expected.length())
  for i in 0..<expected.length() {
    assert_true(
      model.seen_tools[0][i] ==
      { ..expected[i], owner: @kernel.OwnerId::unchecked("published"), },
    )
  }
}

///|
async fn compact_tools_idle(fail_compact : Bool, refresh : Bool) -> Unit {
  let id = "tools-idle"
  let store = RecordingSessionStore()
  compact_tools_seed(store, id)
  let model = compact_tools_model(store, fail_compact, [
    Respond(tk_stop_response("old chat")),
    Respond(tk_stop_response("refreshed chat")),
  ])
  let original = tk_tool_def("original", "previous chat tools")
  let current = tk_tool_def("current", "current snapshot tools")
  let pending = tk_tool_def("pending", "adopted at compact admission")
  let source = ToolPublisher(
    RecordingToolProvider(
      [original],
      Map([("echo", OutcomeOk(tk_ok_result("echo")))]),
    ),
  )
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store]), source],
    config=tk_config(),
    runtime=@runtime.PortRuntime(model~),
  )
  if refresh {
    ignore(agent.run_turn(tk_user_msg("before refresh"), id))
    source.publish(RecordingToolProvider([current], Map([])))
    // Published changes are adopted at the next operation boundary.
    ignore(agent.run_turn(tk_user_msg("adopt refresh"), id))
    source.publish(RecordingToolProvider([pending], Map([])))
  }
  let before = snapshot_messages(store.store[id].messages)
  let result : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session(id),
  ) catch {
    e => Err(e)
  }
  if fail_compact {
    guard result is Err(Runtime(@error.RuntimeError::InvocationFailed(detail))) else {
      fail(
        "expected the failed manual compact to surface a runtime invocation failure",
      )
    }
    assert_true(detail.contains("phase=compact_session"))
    assert_true(detail.contains("ModelFailure::Transport"))
    assert_true(detail.contains("compact rejected"))
    assert_true(store.store[id].messages == before)
    assert_true(model.committed_at_compact[0] == before)
  } else {
    assert_true(result is Ok(_))
    assert_true(
      store.store[id].messages == policy_replace_result().compacted_messages,
    )
  }
  assert_eq(model.inner.call_count(), if refresh { 2 } else { 0 })
  compact_tools_assert(
    model,
    if refresh {
      [pending]
    } else {
      [original]
    },
    Manual,
  )
}

///|
async test "compact_tools/idle manual before any chat uses snapshot" {
  compact_tools_idle(false, false)
}

///|
async test "compact_tools/idle manual after chat uses refreshed snapshot" {
  compact_tools_idle(false, true)
}

///|
async test "compact_tools/idle manual failure preserves committed history" {
  compact_tools_idle(true, true)
}

///|
/// Park the tool wave, not the model response: the queued manual compact
/// executes after all tool results have committed, with no pending call to
/// abandon on failure.
struct CompactToolsRuntime {
  inner : &@runtime.Runtime
  mut parked : Bool
  mut release : Bool
}

///|
impl @runtime.Runtime for CompactToolsRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.inner.call_model(scope, messages, tools, options, on_chunk)
}

///|
impl @runtime.Runtime for CompactToolsRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.parked = true
  while !self.release {
    @async.pause()
  }
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for CompactToolsRuntime with fn cancel_effects(
  self,
  run_id~,
  ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.inner.cancel_effects(ids, reason, run_id~)
}

///|
impl @runtime.Runtime for CompactToolsRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, tools, options, trigger)
}

///|
async fn compact_tools_midturn(fail_compact : Bool) -> Unit {
  let id = "tools-midturn"
  let store = RecordingSessionStore()
  compact_tools_seed(store, id)
  let model = compact_tools_model(store, fail_compact, [
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let original = tk_tool_def("echo", "active snapshot tools")
  let source = ToolPublisher(
    RecordingToolProvider(
      [original],
      Map([("echo", OutcomeOk(tk_ok_result("echo")))]),
    ),
  )
  let runtime = CompactToolsRuntime::{
    inner: @runtime.PortRuntime(model~),
    parked: false,
    release: false,
  }
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store]), source],
    config=tk_config(),
    runtime~,
  )
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      outcome.val = Ok(agent.run_turn(tk_user_msg("hi"), id)) catch {
        e => Err(e)
      }
    })
    while !runtime.parked {
      @async.pause()
    }
    source.publish(
      RecordingToolProvider(
        [tk_tool_def("next", "not in the active snapshot")],
        Map([]),
      ),
    )
    assert_true(
      compact_diag_builtin_compact(agent).invoke("compact", Json::null())
      is Success(..),
    )
    runtime.release = true
    ignore(task.wait())
  })
  if fail_compact {
    guard outcome.val
      is Err(Runtime(@error.RuntimeError::InvocationFailed(detail))) else {
      fail("expected the turn to fail with the compact transport error")
    }
    assert_true(detail.contains("modelport compact failed"))
    assert_true(detail.contains("ModelFailure::Transport"))
    assert_true(detail.contains("compact rejected"))
    // The final tool-wave facts may commit after the failed attempt. No
    // compact rewrite is committed: the result is the un-compacted input,
    // retaining every message already committed before the attempt.
    assert_true(store.store[id].messages == model.seen_messages[0])
    let committed = model.committed_at_compact[0]
    assert_true(
      store.store[id].messages[:committed.length()].to_owned() == committed,
    )
  } else {
    assert_true(outcome.val is Ok(_))
  }
  compact_tools_assert(model, [original], Manual)
}

///|
async test "compact_tools/mid-turn manual keeps active snapshot despite catalog change" {
  compact_tools_midturn(false)
}

///|
async test "compact_tools/mid-turn manual failure preserves committed history" {
  compact_tools_midturn(true)
}

///|
async fn compact_tools_auto(fail_compact : Bool, pre_request : Bool) -> Unit {
  let id = "tools-auto"
  let store = RecordingSessionStore()
  compact_tools_seed(store, id)
  if pre_request {
    store.seed(id, {
      messages: [tk_user_msg("committed history")],
      metadata: policy_context_metadata(
        session_id=id,
        measured=95,
        window=100,
        reading_count=1,
      ),
    })
  }
  let model = compact_tools_model(
    store,
    fail_compact,
    if pre_request {
      [Respond(tk_stop_response("done"))]
    } else {
      [
        Respond(scope_test_tool_call_with_usage(95)),
        Respond(tk_stop_response("done")),
      ]
    },
  )
  let original = tk_tool_def("echo", "auto snapshot tools")
  let source = ToolPublisher(
    RecordingToolProvider(
      [original],
      Map([("echo", OutcomeOk(tk_ok_result("echo")))]),
    ),
  )
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  runtime.on_first_execute = Some(() => {
    source.publish(
      RecordingToolProvider(
        [tk_tool_def("next", "not in active snapshot")],
        Map([]),
      ),
    )
  })
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store]), source],
    config=tk_config(),
    runtime~,
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hi"), id),
  ) catch {
    e => Err(e)
  }
  if fail_compact {
    assert_true(result is Err(AutoCompactFailed(_)))
    // The final tool-wave facts may commit after the failed attempt. No
    // compact rewrite is committed: the result is the un-compacted input,
    // retaining every message already committed before the attempt.
    assert_true(store.store[id].messages == model.seen_messages[0])
    let committed = model.committed_at_compact[0]
    assert_true(
      store.store[id].messages[:committed.length()].to_owned() == committed,
    )
  } else {
    assert_true(result is Ok(_))
    assert_true(store.store[id].messages[0] == tk_user_msg("summary"))
  }
  compact_tools_assert(model, [original], Auto)
  if pre_request {
    assert_eq(model.inner.call_count(), if fail_compact { 0 } else { 1 })
  }
}

///|
async test "compact_tools/auto pre-request has tools before any chat" {
  compact_tools_auto(false, true)
}

///|
async test "compact_tools/auto pre-request failure preserves committed history" {
  compact_tools_auto(true, true)
}

///|
async test "compact_tools/auto mid-turn uses active snapshot" {
  compact_tools_auto(false, false)
}

///|
async test "compact_tools/auto mid-turn failure preserves committed history" {
  compact_tools_auto(true, false)
}

///|
async test "compact_tools/empty snapshot is explicit and does not inherit another Agent chat" {
  let model = ScriptedModel([
    Respond(tk_stop_response("done")),
    Compact(result=policy_replace_result()),
  ])
  let chat_agent = Agent(
    exts=[tk_ext(id="model", model=Some(model), tools=[policy_tools()])],
    config=tk_config(),
  )
  ignore(chat_agent.run_turn(tk_user_msg("hi"), "tools-chat"))
  assert_eq(model.received_tools[0].length(), 1)
  let store = RecordingSessionStore()
  compact_tools_seed(store, "tools-empty")
  let compact_agent = Agent(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store])],
    config=tk_config(),
  )
  ignore(compact_agent.compact_session("tools-empty"))
  assert_eq(model.received_compact_tools.length(), 1)
  assert_eq(model.received_compact_tools[0].length(), 0)
  assert_eq(model.call_count(), 1)
}

///|
async test "compact_tools/default Agent idle manual forwards composed definitions before chat" {
  let model = ScriptedModel([Compact(result=policy_replace_result())])
  let store = RecordingSessionStore()
  compact_tools_seed(store, "tools-composed")
  let tools = RecordingToolProvider(
    [
      {
        ..tk_tool_def("echo", "echo schema"),
        provenance: Some("echo-provider"),
        policy: Sequential,
      },
      tk_tool_def("lookup", "lookup schema"),
    ],
    Map::from_array([]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), tools=[tools], sessions=[store]),
    ],
    config=tk_config(),
  )
  ignore(agent.compact_session("tools-composed"))
  assert_eq(model.call_count(), 0)
  guard model.received_compact_tools is [[echo, lookup]] else {
    fail("compact must receive both composed definitions")
  }
  assert_eq(echo.name.to_string(), "echo")
  assert_eq(echo.owner.to_string(), "model")
  assert_eq(echo.provenance, Some("echo-provider"))
  assert_true(echo.policy is Sequential)
  assert_eq(lookup.name.to_string(), "lookup")
  assert_eq(lookup.owner.to_string(), "model")
}
