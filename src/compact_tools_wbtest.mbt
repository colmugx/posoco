///|
using @support {compact_tools_seed}

///|
/// Records compact inputs independently of chat, including the durable
/// window at entry so failures can be checked for accidental rewrites.
struct CompactToolsModel {
  inner : @test_support.ScriptedModel
  seen_tools : Array[Array[@kernel.ToolDef]]
  seen_triggers : Array[@kernel.CompactTrigger]
  committed_at_compact : Array[Array[@kernel.Message]]
  store : @test_support.RecordingSessionPort
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
  self.seen_tools.push(tools.map(@test_support.snapshot_tool_def))
  self.seen_triggers.push(trigger)
  self.committed_at_compact.push(
    @message_snapshot.snapshot_messages(
      self.store.store[scope.session_id.to_string()].messages,
    ),
  )
  ignore(options)
  self.seen_messages.push(
    @message_snapshot.snapshot_messages(messages.to_owned()),
  )
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
  store : @test_support.RecordingSessionPort,
  fail_compact : Bool,
  chats : Array[@test_support.ScriptedModelStep],
) -> CompactToolsModel {
  {
    inner: @test_support.ScriptedModel(chats),
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
  let store = @test_support.RecordingSessionPort()
  compact_tools_seed(store, id)
  let model = compact_tools_model(store, fail_compact, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("old chat"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("refreshed chat"),
    ),
  ])
  let original = @test_support.tk_tool_def("original", "previous chat tools")
  let current = @test_support.tk_tool_def("current", "current snapshot tools")
  let pending = @test_support.tk_tool_def(
    "pending", "adopted at compact admission",
  )
  let source = ToolPublisher(
    @test_support.RecordingToolProvider(
      [original],
      Map([
        (
          "echo",
          @test_support.ScriptedToolOutcome::OutcomeOk(
            @test_support.tk_ok_result("echo"),
          ),
        ),
      ]),
    ),
  )
  let agent = Agent::with_runtime(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      source,
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=@runtime.PortRuntime(model~),
  )
  if refresh {
    ignore(agent.run_turn(@test_support.tk_user_msg("before refresh"), id))
    source.publish(@test_support.RecordingToolProvider([current], Map([])))
    // Published changes are adopted at the next operation boundary.
    ignore(agent.run_turn(@test_support.tk_user_msg("adopt refresh"), id))
    source.publish(@test_support.RecordingToolProvider([pending], Map([])))
  }
  let before = @message_snapshot.snapshot_messages(store.store[id].messages)
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
async test "compact_tools/idle manual after chat uses refreshed snapshot" {
  compact_tools_idle(false, true)
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
  let store = @test_support.RecordingSessionPort()
  compact_tools_seed(store, id)
  let model = compact_tools_model(store, fail_compact, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let original = @test_support.tk_tool_def("echo", "active snapshot tools")
  let source = ToolPublisher(
    @test_support.RecordingToolProvider(
      [original],
      Map([
        (
          "echo",
          @test_support.ScriptedToolOutcome::OutcomeOk(
            @test_support.tk_ok_result("echo"),
          ),
        ),
      ]),
    ),
  )
  let runtime = CompactToolsRuntime::{
    inner: @runtime.PortRuntime(model~),
    parked: false,
    release: false,
  }
  let agent = Agent::with_runtime(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      source,
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      outcome.val = Ok(agent.run_turn(@test_support.tk_user_msg("hi"), id)) catch {
        e => Err(e)
      }
    })
    while !runtime.parked {
      @async.pause()
    }
    source.publish(
      @test_support.RecordingToolProvider(
        [@test_support.tk_tool_def("next", "not in the active snapshot")],
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
  let store = @test_support.RecordingSessionPort()
  compact_tools_seed(store, id)
  if pre_request {
    store.seed(id, {
      messages: [@test_support.tk_user_msg("committed history")],
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
      [
        @test_support.ScriptedModelStep::Respond(
          @test_support.tk_stop_response("done"),
        ),
      ]
    } else {
      [
        @test_support.ScriptedModelStep::Respond(
          scope_test_tool_call_with_usage(95),
        ),
        @test_support.ScriptedModelStep::Respond(
          @test_support.tk_stop_response("done"),
        ),
      ]
    },
  )
  let original = @test_support.tk_tool_def("echo", "auto snapshot tools")
  let source = ToolPublisher(
    @test_support.RecordingToolProvider(
      [original],
      Map([
        (
          "echo",
          @test_support.ScriptedToolOutcome::OutcomeOk(
            @test_support.tk_ok_result("echo"),
          ),
        ),
      ]),
    ),
  )
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  runtime.on_first_execute = Some(() => {
    source.publish(
      @test_support.RecordingToolProvider(
        [@test_support.tk_tool_def("next", "not in active snapshot")],
        Map([]),
      ),
    )
  })
  let agent = Agent::with_runtime(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      source,
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(@test_support.tk_user_msg("hi"), id),
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
    assert_true(
      store.store[id].messages[0] == @test_support.tk_user_msg("summary"),
    )
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
async test "compact_tools/empty snapshot is explicit and does not inherit another Agent chat" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
    @test_support.ScriptedModelStep::Compact(result=policy_replace_result()),
  ])
  let chat_agent = Agent(
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), tools=[policy_tools()]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(chat_agent.run_turn(@test_support.tk_user_msg("hi"), "tools-chat"))
  assert_eq(model.received_tools[0].length(), 1)
  let store = @test_support.RecordingSessionPort()
  compact_tools_seed(store, "tools-empty")
  let compact_agent = Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model), sessions=[store])],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(compact_agent.compact_session("tools-empty"))
  assert_eq(model.received_compact_tools.length(), 1)
  assert_eq(model.received_compact_tools[0].length(), 0)
  assert_eq(model.call_count(), 1)
}
