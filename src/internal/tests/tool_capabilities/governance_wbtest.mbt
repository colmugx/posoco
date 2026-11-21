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
      definitions: [
        { ..@test_support.tk_tool_def("parent", "parent"), policy: Exclusive, },
      ],
      owners: ["child"],
      action: async fn(ctx) {
        replies.push(ctx.invoke("child", {}))
        @test_support.tk_ok_result("parent")
      },
    }
    let child = @test_support.RecordingToolProvider(
      [
        {
          ..@test_support.tk_tool_def("child", "child"),
          exposure: Deferred,
          input_schema: { "type": "object" },
        },
      ],
      Map::from_array([]),
    )
    let outside = @test_support.RecordingToolProvider(
      [
        {
          ..@test_support.tk_tool_def("outside", "outside"),
          exposure: Deferred,
        },
      ],
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
    let observer = @test_support.RecordingObserver()
    let model = @test_support.ScriptedModel([
      Respond(@test_support.tk_tool_call_response("parent", "p", Json::null())),
      Respond(@test_support.tk_stop_response("done")),
    ])
    let agent = Agent(
      events=@agent.EventSystem(),
      exts=[
        @test_support.tk_ext(id="model", model=Some(model), hooks=[hook], observers=[
          observer,
        ]),
        parent,
        @test_support.tk_ext(id="child", tools=[child]),
        @test_support.tk_ext(id="outside", tools=[outside]),
      ],
      config=@agent.agent_config(max_tool_rounds=Some(10)),
    )
    let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "rewrite-child")
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
    definitions: [
      { ..@test_support.tk_tool_def("parent", "parent"), policy: Exclusive, },
    ],
    owners: ["child"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("child", {}))
      @test_support.tk_ok_result("parent")
    },
  }
  let child = @test_support.RecordingToolProvider(
    [{ ..@test_support.tk_tool_def("child", "child"), exposure: Deferred, }],
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
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("parent", "p", Json::null())),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), hooks=[
        consent, rewrite,
      ]),
      parent,
      @test_support.tk_ext(id="child", tools=[child]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "consent-child")
  guard replies is [Completed(NotExecuted(reason=RejectedByHook(reason~), ..))] else {
    fail("child reused stale consent")
  }
  assert_true(reason.contains("changed after consent"))
  assert_eq(child.exec_records().length(), 0)
}

///|
async test "tool_invoke/child_crosses_the_same_binding_aware_runtime_decorator" {
  let child = @test_support.RecordingToolProvider(
    [{ ..@test_support.tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([
      ("child", OutcomeOk(@test_support.tk_ok_result("child result"))),
    ]),
  )
  let parent = InvokingTool::{ seen_tools: [], }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("parent", "p", Json::null()),
    ),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  let agent = Agent::with_runtime(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      parent,
      @test_support.tk_ext(id="child", tools=[child]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "decorated-child",
  )
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
    definitions: [
      { ..@test_support.tk_tool_def("parent", "parent"), policy: Exclusive, },
    ],
    owners: ["unregistered"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("unregistered", {}))
      @test_support.tk_ok_result("parent")
    },
  }
  let unregistered = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("unregistered", "unregistered")],
    Map::from_array([
      (
        "unregistered",
        OutcomeOk(@test_support.tk_ok_result("must not be called")),
      ),
    ]),
  )
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("parent", "p", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let runtime = @runtime.PortRuntime(model~)
  let agent = Agent::with_runtime(
    events=@agent.EventSystem(),
    exts=[@test_support.tk_ext(id="model", model=Some(model)), parent],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let _ = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "unregistered-child",
  )
  guard replies is [Completed(NotExecuted(reason=UnknownTool, ..))] else {
    fail("unregistered child was treated as a fixed executor")
  }
  assert_eq(unregistered.exec_records().length(), 0)
}

///|
priv struct ExposureSwitch {
  mut disabled : Bool
  mut control : AgentControl?
}

///|
impl @port.PipelineHook for ExposureSwitch with fn tool_exposure(
  self,
  def : @kernel.ToolDef,
) -> @kernel.ToolExposure {
  if self.disabled && def.owner.to_string() == "tools" {
    Disabled
  } else {
    Direct
  }
}

///|
impl @port.PipelineHook for ExposureSwitch with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if !self.disabled {
    self.disabled = true
    if self.control is Some(control) {
      guard control.enqueue_follow_up(@test_support.tk_user_msg("follow up"))
        is @runtime.Accepted(..) else {
        abort("follow up rejected")
      }
    }
  }
  Approve(call~)
}

///|
async test "tool_exposure/rules_are_frozen_for_followups_and_recomputed_for_next_operation" {
  let hook = ExposureSwitch::{ disabled: false, control: None, }
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "a1", Json::null())),
    Respond(@test_support.tk_stop_response("a1 done")),
    Respond(@test_support.tk_tool_call_response("echo", "a2", Json::null())),
    Respond(@test_support.tk_stop_response("a2 done")),
    Respond(@test_support.tk_tool_call_response("echo", "b", Json::null())),
    Respond(@test_support.tk_stop_response("b done")),
  ])
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[provider], hooks=[hook]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  hook.control = Some(agent.control())
  ignore(agent.run_turn(@test_support.tk_user_msg("A"), "projection"))
  assert_eq(provider.exec_records().length(), 2)
  let next = agent.run_turn(@test_support.tk_user_msg("B"), "projection")
  guard next.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("next operation must use disabled projection")
  }
  assert_eq(provider.exec_records().length(), 2)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), ["echo"])
  assert_eq(model.received_tools[2].map(t => t.name.to_string()), ["echo"])
  assert_eq(model.received_tools[4].length(), 0)
}

///|
priv struct ExposureRewrite {}

///|
impl @port.PipelineHook for ExposureRewrite with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Approve(call={ ..call, name: @kernel.ToolName::unchecked("disabled"), })
}

///|
async test "tool_exposure/hook_rewrite_cannot_enter_disabled_target" {
  let provider = @test_support.RecordingToolProvider(
    [
      @test_support.tk_tool_def("direct", "direct"),
      {
        ..@test_support.tk_tool_def("disabled", "disabled"),
        exposure: Disabled,
      },
    ],
    Map::from_array([]),
  )
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response("direct", "rewrite", Json::null()),
    ),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[provider], hooks=[
        ExposureRewrite::{ },
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(
    @test_support.tk_user_msg("hello"),
    "rewrite-exposure",
  )
  guard result.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("rewrites must be checked against effective exposure")
  }
  assert_eq(provider.exec_records().length(), 0)
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), ["direct"])
}

///|
async test "tool_exposure/deferred_tool_is_not_offered_and_guessing_is_rejected" {
  let deferred = {
    ..@test_support.tk_tool_def("secret", "deferred"),
    exposure: Deferred,
  }
  let provider = @test_support.RecordingToolProvider(
    [deferred],
    Map::from_array([
      ("secret", OutcomeOk(@test_support.tk_ok_result("must not execute"))),
    ]),
  )
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("secret", "guess", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="owner", tools=[provider]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(@test_support.tk_user_msg("hello"), "exposure")
  assert_eq(model.received_tools[0].length(), 0)
  assert_eq(provider.exec_records().length(), 0)
  guard result.tool_results is [NotExecuted(reason=NotOffered, ..)] else {
    fail("a guessed deferred tool must be rejected")
  }
}

///|
async test "tool_exposure/manual_compact_only_receives_direct_projection" {
  let model = @test_support.ScriptedModel([
    Compact(result=policy_replace_result()),
  ])
  let store = @test_support.RecordingSessionPort()
  compact_tools_seed(store, "exposure-compact")
  let provider = @test_support.RecordingToolProvider(
    [
      {
        ..@test_support.tk_tool_def("deferred", "deferred"),
        exposure: Deferred,
      },
      {
        ..@test_support.tk_tool_def("disabled", "disabled"),
        exposure: Disabled,
      },
      @test_support.tk_tool_def("direct", "direct"),
    ],
    Map::from_array([]),
  )
  let agent = Agent(
    events=@agent.EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      @test_support.tk_ext(id="tools", tools=[provider]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.compact_session("exposure-compact"))
  assert_eq(model.received_compact_tools[0].map(t => t.name.to_string()), [
    "direct",
  ])
}
