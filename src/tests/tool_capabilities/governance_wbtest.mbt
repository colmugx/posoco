///|
priv struct InvocationHook {
  decide : (@kernel.ToolCall) -> @port.ToolDecision
}

///|
impl @port.PipelineHook for InvocationHook with fn before_tool(self, call) -> @port.ToolDecision {
  (self.decide)(call)
}

///|
async test "tool_invoke/rewritten_child_rechecks_owner_and_schema_and_never_inherits_parent_consent" {
  for rewrite_owner in [true, false] {
    let replies : Array[@kernel.InvocationResult] = []
    let seen : Array[String] = []
    let parent = InvocationFixture::{
      id: "parent",
      definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
      owners: ["child"],
      action: async fn(ctx) {
        replies.push(ctx.invoke("child", {}))
        tk_ok_result("parent")
      },
    }
    let child = RecordingToolProvider(
      [
        {
          ..tk_tool_def("child", "child"),
          exposure: Deferred,
          input_schema: { "type": "object" },
        },
      ],
      Map::from_array([]),
    )
    let outside = RecordingToolProvider(
      [{ ..tk_tool_def("outside", "outside"), exposure: Deferred, }],
      Map::from_array([]),
    )
    let hook = InvocationHook::{
      decide: call => {
        seen.push(call.name.to_string())
        if call.name.to_string() == "parent" {
          ApproveAfterConsent(call~, consent_scope="parent only")
        } else if rewrite_owner {
          Approve(call={ ..call, name: @kernel.ToolName::unchecked("outside"), })
        } else {
          Approve(call={ ..call, arguments: "not an object", })
        }
      },
    }
    let observer = RecordingObserver()
    let model = ScriptedModel([
      Respond(tk_tool_call_response("parent", "p", Json::null())),
      Respond(tk_stop_response("done")),
    ])
    let agent = Agent(
      exts=[
        tk_ext(id="model", model=Some(model), hooks=[hook], observers=[observer]),
        parent,
        tk_ext(id="child", tools=[child]),
        tk_ext(id="outside", tools=[outside]),
      ],
      config=tk_config(),
    )
    let _ = agent.run_turn(tk_user_msg("hello"), "rewrite-child")
    guard replies is [Completed(NotExecuted(reason~, ..))] else {
      fail("rewritten child was not rejected")
    }
    if rewrite_owner {
      assert_eq(reason, OwnerNotAllowed)
    } else {
      guard reason is SchemaMismatch(..) else {
        fail("child rewrite bypassed schema validation")
      }
    }
    assert_eq(seen, ["parent", "child"])
    assert_eq(child.exec_records().length(), 0)
    assert_eq(outside.exec_records().length(), 0)
    assert_eq(
      observer.events().filter(event => event is ToolCallStarted(..)).length(),
      1,
    )
  }
}

///|
async test "tool_invoke/a_later_rewrite_invalidates_child_consent" {
  let replies : Array[@kernel.InvocationResult] = []
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["child"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("child", {}))
      tk_ok_result("parent")
    },
  }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([]),
  )
  let consent = InvocationHook::{
    decide: call => {
      if call.name.to_string() == "child" {
        ApproveAfterConsent(call~, consent_scope="confirmed original arguments")
      } else {
        Approve(call~)
      }
    },
  }
  let rewrite = InvocationHook::{
    decide: call => {
      if call.name.to_string() == "child" {
        Approve(call={ ..call, arguments: { "changed": true }, })
      } else {
        Approve(call~)
      }
    },
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), hooks=[consent, rewrite]),
      parent,
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "consent-child")
  guard replies is [Completed(NotExecuted(reason=RejectedByHook(reason~), ..))] else {
    fail("child reused stale consent")
  }
  assert_true(reason.contains("changed after consent"))
  assert_eq(child.exec_records().length(), 0)
}

///|
async test "tool_invoke/child_crosses_the_same_binding_aware_runtime_decorator" {
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([("child", OutcomeOk(tk_ok_result("child result")))]),
  )
  let parent = InvokingTool::{ seen_tools: [], }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      parent,
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
    runtime~,
  )
  let result = agent.run_turn(tk_user_msg("hello"), "decorated-child")
  assert_eq(contribution_result_texts(result.tool_results), ["child result"])
  assert_eq(runtime.seen_contexts.map(ctx => ctx.owner.to_string()), [
    "parent", "child",
  ])
  assert_eq(runtime.seen_contexts.length(), 2)
  assert_true(
    runtime.seen_contexts[0].effect_id != runtime.seen_contexts[1].effect_id,
  )
}

///|
async test "tool_invoke/unregistered_target_cannot_be_invoked_by_name" {
  let replies : Array[@kernel.InvocationResult] = []
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["unregistered"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("unregistered", {}))
      tk_ok_result("parent")
    },
  }
  let unregistered = RecordingToolProvider(
    [tk_tool_def("unregistered", "unregistered")],
    Map::from_array([
      ("unregistered", OutcomeOk(tk_ok_result("must not be called"))),
    ]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = @runtime.PortRuntime(model~)
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model)), parent],
    config=tk_config(),
    runtime~,
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "unregistered-child")
  guard replies is [Completed(NotExecuted(reason=UnknownTool, ..))] else {
    fail("unregistered child was treated as a fixed executor")
  }
  assert_eq(unregistered.exec_records().length(), 0)
}
