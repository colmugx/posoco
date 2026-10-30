///|
async test "tool_invoke/child_result_returns_to_parent_without_another_model_turn" {
  let parent = InvokingTool::{ seen_tools: [], }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([("child", OutcomeOk(tk_ok_result("child result")))]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "parent-call", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let store = RecordingSessionPort()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[store], observers=[
        observer,
      ]),
      parent,
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "nested")
  assert_eq(contribution_result_texts(result.tool_results), ["child result"])
  assert_eq(child.exec_records().length(), 1)
  assert_eq(model.call_count(), 2)
  assert_eq(model.received_tools[0].map(def => def.name.to_string()), ["parent"])
  assert_eq(parent.seen_tools, ["child"])
  let session = store.load("nested")
  let persisted_tools = session.messages.filter(message => {
    message is ToolMessage(..)
  })
  assert_eq(persisted_tools.length(), 1)
  guard persisted_tools[0] is ToolMessage(call_id~, ..) &&
    call_id.to_string() == "parent-call" else {
    fail("child was persisted as a synthetic model tool message")
  }
  let declarations = observer
    .events()
    .filter(event => event is ToolChildDeclared(..))
  guard declarations
    is [
      ToolChildDeclared(
        effect_id~,
        parent_effect_id~,
        root_effect_id~,
        depth=1,
        ..
      ),
    ] else {
    fail("expected formal child identity")
  }
  assert_eq(parent_effect_id, root_effect_id)
  assert_true(effect_id != root_effect_id)
}

///|
async test "tool_invoke/admission_denials_do_not_reach_the_child_provider" {
  let cases : Array[
    (
      Array[String],
      @kernel.ExecutionPolicy,
      @kernel.ExecutionPolicy,
      @kernel.ToolExposure,
      Int32?,
      Int32?,
      @kernel.NotExecutedReason,
    ),
  ] = [
    ([], Exclusive, Parallel, Deferred, None, None, OwnerNotAllowed),
    (["child"], Parallel, Sequential, Deferred, None, None, PolicyConflict),
    (["child"], Parallel, Exclusive, Deferred, None, None, PolicyConflict),
    (["child"], Sequential, Exclusive, Deferred, None, None, PolicyConflict),
    (["child"], Exclusive, Parallel, Disabled, None, None, NotOffered),
    (["child"], Exclusive, Parallel, Deferred, Some(1), None, InvocationLimit),
    (["child"], Exclusive, Parallel, Deferred, None, Some(0), InvocationLimit),
  ]
  for case in cases {
    let (
      owners,
      parent_policy,
      child_policy,
      exposure,
      max_calls,
      max_depth,
      reason,
    ) = case
    let replies : Array[@kernel.InvocationResult] = []
    let started = Ref(0)
    let parent = InvocationFixture::{
      id: "parent",
      definitions: [
        { ..tk_tool_def("parent", "parent"), policy: parent_policy, },
      ],
      owners,
      action: async fn(ctx) {
        replies.push(ctx.invoke("child", Json::null()))
        tk_ok_result("parent")
      },
    }
    let child = InvocationFixture::{
      id: "child",
      owners: [],
      definitions: [
        { ..tk_tool_def("child", "child"), policy: child_policy, exposure, },
      ],
      action: _ctx => {
        started.val += 1
        tk_ok_result("unexpected")
      },
    }
    let model = ScriptedModel([
      Respond(tk_tool_call_response("parent", "p", Json::null())),
      Respond(tk_stop_response("done")),
    ])
    let agent = Agent(
      exts=[tk_ext(id="model", model=Some(model)), parent, child],
      config=@agent.agent_config(
        max_tool_rounds=tk_config().max_tool_rounds,
        max_tool_calls=max_calls,
        max_tool_depth=max_depth,
      ),
    )
    let _ = agent.run_turn(tk_user_msg("hello"), "rejected-child")
    guard replies is [Completed(NotExecuted(reason=actual, ..))] else {
      fail("expected a structured admission rejection")
    }
    assert_eq(actual, reason)
    assert_eq(started.val, 0)
  }
}

///|
async test "tool_invoke/recursion_uses_the_shared_call_budget_without_an_extra_model_round" {
  let calls = Ref(0)
  let replies : Array[@kernel.InvocationResult] = []
  let recursive = InvocationFixture::{
    id: "recursive",
    owners: ["recursive"],
    definitions: [
      { ..tk_tool_def("recurse", "recursive composition"), policy: Exclusive, },
    ],
    action: async fn(ctx) {
      calls.val += 1
      let result = ctx.invoke("recurse", Json::null())
      replies.push(result)
      tk_ok_result("returned")
    },
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("recurse", "root", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[tk_ext(id="model", model=Some(model)), recursive],
    config=@agent.agent_config(
      max_tool_rounds=tk_config().max_tool_rounds,
      max_tool_calls=Some(3),
      max_tool_depth=Some(8),
    ),
  )
  let result = @async.with_timeout(2000, async fn() {
    agent.run_turn(tk_user_msg("hello"), "recursive")
  })
  assert_eq(calls.val, 3)
  assert_eq(model.call_count(), 2)
  assert_eq(result.tool_results.length(), 1)
  guard replies[0] is Completed(NotExecuted(reason=InvocationLimit, ..)) else {
    fail("shared budget was not enforced")
  }
  assert_eq(replies.length(), 3)
}

///|
async test "tool_invoke/a_saved_context_loses_discovery_and_invocation" {
  let saved : Ref[@port.ToolCallContext?] = Ref(None)
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [tk_tool_def("parent", "parent")],
    owners: ["child"],
    action: ctx => {
      saved.val = Some(ctx)
      tk_ok_result("parent")
    },
  }
  let child = RecordingToolProvider(
    [tk_tool_def("child", "child")],
    Map::from_array([]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      parent,
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "saved-context")
  let ctx = saved.val.unwrap()
  assert_eq(ctx.tools().length(), 0)
  guard ctx.invoke("child", Json::null())
    is Interrupted(cancellation=AlreadySettled, side_effects_possible=false, ..) else {
    fail("a settled context retained invocation authority")
  }
  assert_eq(child.exec_records().length(), 0)
}

///|
async test "tool_invoke/custom_runtime_forwards_mandatory_child_bindings" {
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([("child", OutcomeOk(tk_ok_result("child result")))]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "parent-call", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      InvokingTool::{ seen_tools: [], },
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
    runtime~,
  )
  let result = agent.run_turn(tk_user_msg("invoke"), "bound-child")
  assert_eq(contribution_result_texts(result.tool_results), ["child result"])
  assert_eq(child.exec_records().length(), 1)
  assert_eq(runtime.seen_contexts.map(ctx => ctx.owner.to_string()), [
    "parent", "child",
  ])
}

///|
test "tool_invoke/duplicate_owner_cannot_silently_widen_its_child_scope" {
  let parent = InvokingTool::{ seen_tools: [], }
  try
    Agent(
      exts=[
        tk_ext(id="model", model=Some(ScriptedModel([]))),
        parent,
        tk_ext(id="parent"),
      ],
      config=tk_config(),
    )
  catch {
    @error.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      assert_eq(manifest_id, "parent")
      assert_true(detail.contains("tool_call_owners"))
    }
    error => fail(error.to_string())
  } noraise {
    _ => fail("conflicting owner scope declarations were accepted")
  }
}

///|
priv struct CollidingCallModel {
  inner : ScriptedModel
}

///|
impl @port.ModelPort for CollidingCallModel with fn provider_config(self) -> @port.ProviderConfig {
  self.inner.provider_config()
}

///|
impl @port.ModelPort for CollidingCallModel with fn chat(
  self,
  scope,
  messages,
  tools,
  options,
  stream,
) -> @kernel.ModelCallResult raise @error.ModelError {
  let result = self.inner.chat(scope, messages, tools, options, stream)
  let completion = result.completion
  let message = completion.message
  let calls = message.tool_calls.map(call => {
    ..call,
    call_id: @kernel.CallId::unchecked(scope.run_id.to_string() + ":child:3"),
  })
  {
    ..result,
    completion: { ..completion, message: { ..message, tool_calls: calls, }, },
  }
}

///|
impl @port.ModelPort for CollidingCallModel with fn compact(
  self,
  scope,
  messages,
  tools,
  options,
  trigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.inner.compact(scope, messages, tools, options, trigger)
}

///|
async test "tool_invoke/model_call_ids_cannot_collide_with_kernel_child_ids" {
  let model = CollidingCallModel::{
    inner: ScriptedModel([
      Respond(
        tk_tool_call_response("parent", "will be rewritten", Json::null()),
      ),
      Respond(tk_stop_response("done")),
    ]),
  }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([("child", OutcomeOk(tk_ok_result("child result")))]),
  )
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), observers=[observer]),
      InvokingTool::{ seen_tools: [], },
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "colliding-child-id")
  assert_eq(contribution_result_texts(result.tool_results), ["child result"])
  let ids = observer
    .events()
    .filter_map(event => {
      match event {
        ToolCallPending(call) => Some(call.call_id.to_string())
        _ => None
      }
    })
  assert_eq(ids.length(), 2)
  assert_true(ids[0] != ids[1])
}
