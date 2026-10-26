///|
/// Agent-facing acceptance for dynamic tool contributions: an extension
/// declares `Capability::ToolContribution`, receives the owner-bound
/// capability through its `CompositionView`, publishes a `ToolProvider`
/// group, and later operations select and execute the contributed tools
/// through the ordinary Agent path.

///|
async test "tool_contribution/published_group_is_executable_by_a_later_operation" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ContributionPublisher::new(provider as &@port.ToolProvider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="contrib", lifecycle=[publisher as &@port.Lifecycle], requires=[
        @port.Capability::ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "session_dynamic")
  assert_eq(contribution_result_texts(result.tool_results), ["echo-v1"])
  assert_eq(provider.exec_records().length(), 1)
  match publisher.published {
    Some(commit) => {
      assert_eq(commit.owner, "contrib")
      assert_eq(commit.revision, 1)
    }
    None => fail("the contribution was never acknowledged")
  }
  // Definitions are read exactly once at commit; operations never re-read
  // the provider to rebuild the catalog.
  assert_eq(provider.list_call_count(), 1)
  // The captured definition is owner-bound to the declaring manifest, and the
  // model-visible definition carries that owner as well.
  assert_eq(model.received_tools[0][0].owner.to_string(), "contrib")
}

///|
/// One contribution change applied from `before_tool`, i.e. while the
/// admitted operation is executing. Optionally enqueues one follow-up turn,
/// which the same operation drains without re-capturing its binding.
priv struct ContributionMutator {
  mut contributions : @port.ToolContributions?
  mut control : AgentControl?
  mut pending : ContributionChange?
  mut applied : Bool
}

///|
priv enum ContributionChange {
  Replace(&@port.ToolProvider)
  Withdraw
}

///|
fn ContributionMutator::new() -> ContributionMutator {
  { contributions: None, control: None, pending: None, applied: false, }
}

///|
impl @port.Lifecycle for ContributionMutator with fn on_compose(
  self : ContributionMutator,
  view : @port.CompositionView,
) {
  self.contributions = view.tool_contributions()
}

///|
impl @port.Lifecycle for ContributionMutator with fn on_shutdown(
  _self : ContributionMutator,
) {
  ()
}

///|
impl @port.PipelineHook for ContributionMutator with fn before_tool(
  self : ContributionMutator,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if !self.applied {
    self.applied = true
    let contributions = match self.contributions {
      Some(value) => value
      None => abort("tool contribution capability was not composed")
    }
    match self.pending {
      Some(Replace(provider)) =>
        match contributions.replace(provider~) {
          Ok(_) => ()
          Err(error) =>
            abort("mid-operation publish rejected: " + error.to_string())
        }
      Some(Withdraw) =>
        match contributions.withdraw() {
          Ok(_) => ()
          Err(error) =>
            abort("mid-operation withdraw rejected: " + error.to_string())
        }
      None => ()
    }
    match self.control {
      Some(control) =>
        match control.enqueue_follow_up(tk_user_msg("follow up")) {
          @runtime.Accepted(..) => ()
          _ => abort("follow-up was not enqueued during the tool call")
        }
      None => ()
    }
  }
  Approve(call~)
}

///|
async test "tool_contribution/mid_operation_replace_is_visible_only_to_the_next_operation" {
  let v1 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let v2 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v2")))]),
  )
  let publisher = ContributionPublisher::new(v1 as &@port.ToolProvider)
  let mutator = ContributionMutator::new()
  mutator.pending = Some(Replace(v2 as &@port.ToolProvider))
  let model = ScriptedModel([
    // Operation A, first turn.
    Respond(tk_tool_call_response("dyn_echo", "call_a1", Json::null())),
    Respond(tk_stop_response("a1 done")),
    // Operation A, follow-up drained by the same operation.
    Respond(tk_tool_call_response("dyn_echo", "call_a2", Json::null())),
    Respond(tk_stop_response("a2 done")),
    // Operation B.
    Respond(tk_tool_call_response("dyn_echo", "call_b1", Json::null())),
    Respond(tk_stop_response("b done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="contrib",
        lifecycle=[publisher as &@port.Lifecycle, mutator as &@port.Lifecycle],
        hooks=[mutator as &@port.PipelineHook],
        requires=[@port.Capability::ToolContribution],
      ),
    ],
    config=tk_config(),
  )
  mutator.control = Some(agent.control())
  let operation_a = agent.run_turn(tk_user_msg("A"), "session_replace")
  // The follow-up turn belongs to the same operation, so it still executes
  // the executor bound at admission even though v2 was accepted mid-call.
  assert_eq(contribution_result_texts(operation_a.tool_results), ["echo-v1"])
  assert_eq(v1.exec_records().length(), 2)
  assert_eq(v2.exec_records().length(), 0)
  match mutator.contributions {
    Some(contributions) => assert_eq(contributions.revision(), Some(2))
    None => fail("contribution capability was not composed")
  }
  // A later operation captures the accepted revision.
  let operation_b = agent.run_turn(tk_user_msg("B"), "session_replace")
  assert_eq(contribution_result_texts(operation_b.tool_results), ["echo-v2"])
  assert_eq(v2.exec_records().length(), 1)
  assert_eq(v1.exec_records().length(), 2)
}

///|
async test "tool_contribution/soft_withdraw_affects_future_operations_only" {
  let v1 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ContributionPublisher::new(v1 as &@port.ToolProvider)
  let mutator = ContributionMutator::new()
  mutator.pending = Some(Withdraw)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_a1", Json::null())),
    Respond(tk_stop_response("a1 done")),
    Respond(tk_tool_call_response("dyn_echo", "call_a2", Json::null())),
    Respond(tk_stop_response("a2 done")),
    // Operation B asks for the withdrawn tool.
    Respond(tk_tool_call_response("dyn_echo", "call_b1", Json::null())),
    Respond(tk_stop_response("b done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="contrib",
        lifecycle=[publisher as &@port.Lifecycle, mutator as &@port.Lifecycle],
        hooks=[mutator as &@port.PipelineHook],
        requires=[@port.Capability::ToolContribution],
      ),
    ],
    config=tk_config(),
  )
  mutator.control = Some(agent.control())
  let operation_a = agent.run_turn(tk_user_msg("A"), "session_withdraw")
  assert_eq(contribution_result_texts(operation_a.tool_results), ["echo-v1"])
  assert_eq(v1.exec_records().length(), 2)
  match mutator.contributions {
    Some(contributions) => assert_eq(contributions.revision(), None)
    None => fail("contribution capability was not composed")
  }
  let operation_b = agent.run_turn(tk_user_msg("B"), "session_withdraw")
  match operation_b.tool_results {
    [NotExecuted(reason=UnknownTool, ..)] => ()
    other =>
      fail(
        "withdrawn tool must not execute: " +
        contribution_result_texts(other).join(","),
      )
  }
  // The provider was never invoked for the withdrawn operation.
  assert_eq(v1.exec_records().length(), 2)
}

///|
async test "tool_contribution/rejected_group_keeps_the_accepted_revision" {
  let static_provider = RecordingToolProvider(
    [tk_tool_def("static_tool", "static tool")],
    Map::from_array([("static_tool", OutcomeOk(tk_ok_result("static")))]),
  )
  let v1 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  // Collides with a static composition tool, so the whole group is rejected.
  let conflicting = RecordingToolProvider(
    [
      tk_tool_def("dyn_echo", "dynamic echo"),
      tk_tool_def("static_tool", "shadow"),
    ],
    Map::from_array([
      ("dyn_echo", OutcomeOk(tk_ok_result("echo-v2"))),
      ("static_tool", OutcomeOk(tk_ok_result("shadow"))),
    ]),
  )
  let publisher = ContributionPublisher::new(v1 as &@port.ToolProvider)
  publisher.publish_at_start = false
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="static", tools=[static_provider]),
      tk_ext(id="contrib", lifecycle=[publisher as &@port.Lifecycle], requires=[
        @port.Capability::ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  ignore(publisher.publish(v1 as &@port.ToolProvider))
  guard publisher
    .capability()
    .replace(provider=conflicting as &@port.ToolProvider)
    is Err(Rejected(reason~)) else {
    fail("a colliding group must be rejected")
  }
  assert_true(reason.contains("dyn_echo") || reason.contains("static_tool"))
  assert_eq(publisher.capability().revision(), Some(1))
  let result = agent.run_turn(tk_user_msg("hello"), "session_conflict")
  assert_eq(contribution_result_texts(result.tool_results), ["echo-v1"])
  assert_eq(conflicting.exec_records().length(), 0)
}

///|
async test "tool_contribution/custom_runtime_executes_captured_binding" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ContributionPublisher::new(provider as &@port.ToolProvider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = @runtime.PortRuntime(
    model=model as &@port.ModelPort,
    tools=Map::from_array([]),
  )
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="contrib", lifecycle=[publisher as &@port.Lifecycle], requires=[
        @port.Capability::ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime=runtime as &@runtime.Runtime,
  )
  let result = agent.run_turn(tk_user_msg("hello"), "bound_runtime")
  assert_eq(contribution_result_texts(result.tool_results), ["echo-v1"])
  assert_eq(provider.exec_records().length(), 1)
}

///|
/// An empty legacy source must not hide bound contributions.
priv struct ContributionCatalogSource {}

///|
impl @runtime.CatalogSource for ContributionCatalogSource with fn revision(
  _self : ContributionCatalogSource,
) -> Int32 {
  1
}

///|
impl @runtime.CatalogSource for ContributionCatalogSource with fn tools(
  _self : ContributionCatalogSource,
) -> Array[@kernel.ToolDef] {
  []
}

///|
async test "tool_contribution/catalog_source_and_bound_contributions_coexist" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ContributionPublisher::new(provider as &@port.ToolProvider)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = @runtime.PortRuntime(
    model=model as &@port.ModelPort,
    tools=Map::from_array([]),
  )
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="contrib", lifecycle=[publisher as &@port.Lifecycle], requires=[
        @port.Capability::ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime=runtime as &@runtime.Runtime,
    catalog_source=ContributionCatalogSource::{ },
  )
  let result = agent.run_turn(tk_user_msg("hello"), "source_and_contribution")
  assert_eq(contribution_result_texts(result.tool_results), ["echo-v1"])
  assert_eq(model.received_tools[0].map(t => t.name.to_string()), ["dyn_echo"])
}

///|
async test "tool_contribution/shutdown_closes_the_capability" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ContributionPublisher::new(provider as &@port.ToolProvider)
  let model = ScriptedModel([Respond(tk_stop_response("ok"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="contrib", lifecycle=[publisher as &@port.Lifecycle], requires=[
        @port.Capability::ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  agent.run_scoped(async fn(agent) {
    ignore(agent.run_turn(tk_user_msg("hello"), "session_shutdown"))
  })
  let contributions = publisher.capability()
  guard contributions.replace(provider=provider as &@port.ToolProvider)
    is Err(Closed) else {
    fail("a shut-down Agent must not accept a contribution commit")
  }
  guard contributions.withdraw() is Err(Closed) else {
    fail("a shut-down Agent must not accept a contribution withdrawal")
  }
}

///|
priv struct StartupToolPublisher {
  provider : &@port.ToolProvider
  mut capability : @port.ToolContributions?
  waiting : Ref[Bool]
  release : @async.CondVar
  released : Ref[Bool]
  mut starts : Int32
}

///|
impl @port.Lifecycle for StartupToolPublisher with fn on_compose(self, view) {
  self.capability = view.tool_contributions()
}

///|
impl @port.Lifecycle for StartupToolPublisher with fn on_start(self) {
  self.starts += 1
  self.waiting.val = true
  while !self.released.val {
    self.release.wait()
  }
  match self.capability.unwrap().replace(provider=self.provider) {
    Ok(_) => ()
    Err(error) => raise @error.RuntimeError::InvocationFailed(error.to_string())
  }
}

///|
impl @port.Lifecycle for StartupToolPublisher with fn on_shutdown(_self) {
  ()
}

///|
async test "tool_catalog/first_operation_captures_after_managed_startup_and_holds_the_guard_while_waiting" {
  let provider = RecordingToolProvider(
    [tk_tool_def("initial", "published at startup")],
    Map::from_array([("initial", OutcomeOk(tk_ok_result("startup tool")))]),
  )
  let publisher = StartupToolPublisher::{
    provider,
    capability: None,
    waiting: Ref(false),
    release: @async.CondVar::Cond(),
    released: Ref(false),
    starts: 0,
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("initial", "first", {})),
    Respond(tk_stop_response("done")),
    Respond(tk_stop_response("second")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="publisher", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  @async.with_timeout(3_000, async fn() {
    @async.with_task_group(group => {
      let first = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "startup")
      })
      while !publisher.waiting.val {
        @async.pause()
      }
      assert_eq(model.call_count(), 0)
      try agent.run_turn(tk_user_msg("concurrent"), "startup") catch {
        @error.AgentError::Busy(..) => ()
        error => fail("startup did not preserve Busy: " + error.to_string())
      } noraise {
        _ => fail("startup released the operation guard")
      }
      publisher.released.val = true
      publisher.release.broadcast()
      let result = first.wait()
      assert_eq(contribution_result_texts(result.tool_results), ["startup tool"])
    })
  })
  let _ = agent.run_turn(tk_user_msg("again"), "startup")
  assert_eq(publisher.starts, 1)
  assert_eq(provider.exec_records().length(), 1)
}
