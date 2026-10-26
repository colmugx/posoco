///|
/// S5 lifecycle acceptance: async contribution ACK/state, version retire,
/// hard-withdrawal barriers and shutdown/cleanup retries, all through the real
/// public Agent seam.

///|
/// Counting retire callback: records every call, can fail a fixed number of
/// times, and only counts a *successful* retire.
priv struct RetireProbe {
  mut attempts : Int32
  mut completed : Int32
  mut failures_left : Int32
  detail : String
}

///|
fn RetireProbe::RetireProbe(
  failures_left~ : Int32 = 0,
  detail~ : String = "close failed",
) -> RetireProbe {
  { attempts: 0, completed: 0, failures_left, detail, }
}

///|
fn RetireProbe::callback(self : RetireProbe) -> @port.ToolRetire {
  () => {
    self.attempts = self.attempts + 1
    if self.failures_left > 0 {
      self.failures_left = self.failures_left - 1
      Err(self.detail)
    } else {
      self.completed = self.completed + 1
      Ok(())
    }
  }
}

///|
/// Capability holder that never publishes on its own: the test decides when and
/// from which managed async scope the publication happens.
priv struct ManualPublisher {
  mut contributions : @port.ToolContributions?
}

///|
fn ManualPublisher::new() -> ManualPublisher {
  { contributions: None, }
}

///|
fn ManualPublisher::capability(
  self : ManualPublisher,
) -> @port.ToolContributions {
  match self.contributions {
    Some(value) => value
    None => abort("tool contribution capability was not composed")
  }
}

///|
impl @port.Lifecycle for ManualPublisher with fn on_compose(
  self : ManualPublisher,
  view : @port.CompositionView,
) {
  self.contributions = view.tool_contributions()
}

///|
impl @port.Lifecycle for ManualPublisher with fn on_shutdown(
  _self : ManualPublisher,
) {
  ()
}

///|
async test "tool_lifecycle/publish_ack_reports_active_state_and_retires_the_superseded_version" {
  let v1 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let v2 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v2")))]),
  )
  let publisher = ManualPublisher::new()
  // Each published version carries the cleanup callback for its own resources.
  let v1_probe = RetireProbe::RetireProbe()
  let v2_probe = RetireProbe::RetireProbe()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
      ),
      tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let capability = publisher.capability()
  let first = match
    capability.replace(
      provider=v1 as &@port.ToolProvider,
      retire=v1_probe.callback(),
    ) {
    Ok(commit) => commit
    Err(error) => fail("first publish rejected: " + error.to_string())
  }
  assert_eq(first.revision, 1)
  assert_eq(first.state.to_string(), "Active")
  assert_eq(capability.state().to_string(), "Active")
  assert_eq(capability.revision(), Some(1))
  // v1 is still the active version: nothing to retire yet.
  assert_eq(v1_probe.attempts, 0)
  let second = match
    capability.replace(
      provider=v2 as &@port.ToolProvider,
      retire=v2_probe.callback(),
    ) {
    Ok(commit) => commit
    Err(error) => fail("replace rejected: " + error.to_string())
  }
  assert_eq(second.revision, 2)
  assert_eq(second.state.to_string(), "Active")
  // The superseded version had no operation reference, so its own retire ran
  // before the ACK returned; the newly published version stays open.
  assert_eq(v1_probe.attempts, 1)
  assert_eq(v1_probe.completed, 1)
  assert_eq(v2_probe.attempts, 0)
  let withdrawn = match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("hard withdraw rejected: " + error.to_string())
  }
  assert_eq(withdrawn.revision, 3)
  assert_eq(withdrawn.state.to_string(), "Withdrawn")
  assert_eq(capability.state().to_string(), "Withdrawn")
  assert_eq(capability.revision(), None)
  // A hard withdrawal retires the active version (v2) exactly once.
  assert_eq(v2_probe.attempts, 1)
  assert_eq(v2_probe.completed, 1)
  assert_eq(v1_probe.attempts, 1)
  let repeated = match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("repeated hard withdraw rejected: " + error.to_string())
  }
  assert_eq(repeated.revision, 3)
  assert_eq(v2_probe.attempts, 1)
  agent.shutdown()
}

///|
async test "tool_lifecycle/soft_then_hard_withdraw_establishes_a_new_revocation_fact" {
  let v1 = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ManualPublisher::new()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("ok"))])),
      ),
      tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let capability = publisher.capability()
  ignore(capability.replace(provider=v1 as &@port.ToolProvider))
  let soft = match capability.withdraw() {
    Ok(commit) => commit
    Err(error) => fail("soft withdraw rejected: " + error.to_string())
  }
  assert_eq(soft.revision, 2)
  assert_eq(soft.state.to_string(), "Withdrawn")
  let soft_again = match
    capability.withdraw(mode=@port.ToolWithdrawMode::Soft) {
    Ok(commit) => commit
    Err(error) => fail("repeated soft withdraw rejected: " + error.to_string())
  }
  assert_eq(soft_again.revision, 2)
  // A hard withdrawal after a soft one is a new revocation fact: it must not be
  // mistaken for "nothing left to do".
  let hard = match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("hard withdraw rejected: " + error.to_string())
  }
  assert_eq(hard.revision, 3)
  let hard_again = match
    capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("repeated hard withdraw rejected: " + error.to_string())
  }
  assert_eq(hard_again.revision, 3)
  agent.shutdown()
}

///|
/// `before_tool` hook that announces when it is waiting and only then lets the
/// call continue: the deterministic "confirmation in progress" window.
priv struct ConsentWaitHook {
  waiting : Ref[Bool]
  release : @async.CondVar
  released : Ref[Bool]
  mut waits : Int32
}

///|
fn ConsentWaitHook::ConsentWaitHook() -> ConsentWaitHook {
  {
    waiting: Ref(false),
    release: @async.CondVar::Cond(),
    released: Ref(false),
    waits: 0,
  }
}

///|
impl @port.PipelineHook for ConsentWaitHook with fn before_tool(
  self : ConsentWaitHook,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if self.waits == 0 {
    self.waits = self.waits + 1
    self.waiting.val = true
    while !self.released.val {
      self.release.wait()
    }
  }
  Approve(call~)
}

///|
async test "tool_lifecycle/hard_withdraw_during_confirmation_never_starts_the_provider" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ManualPublisher::new()
  let hook = ConsentWaitHook::ConsentWaitHook()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), hooks=[hook]),
      tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let capability = publisher.capability()
  ignore(capability.replace(provider=provider as &@port.ToolProvider))
  @async.with_timeout(5_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "consent-wait")
      })
      while !hook.waiting.val {
        @async.pause()
      }
      // Hard withdrawal lands while the call is still awaiting confirmation.
      match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
        Ok(_) => ()
        Err(error) => fail("hard withdraw rejected: " + error.to_string())
      }
      hook.released.val = true
      hook.release.broadcast()
      let result = turn.wait()
      guard result.tool_results is [NotExecuted(reason=Revoked, ..)] else {
        fail(
          "a revoked target must settle as Revoked: " +
          contribution_result_texts(result.tool_results).join(","),
        )
      }
    })
  })
  // The provider was never entered, and the turn still completed.
  assert_eq(provider.exec_records().length(), 0)
  agent.shutdown()
}

///|
/// Runtime decorator that awaits before forwarding to its inner runtime: the
/// final gate must still see the hard withdrawal that landed during the wait.
struct AwaitingRuntime {
  inner : @runtime.PortRuntime
  entered : Ref[Bool]
  release : @async.CondVar
  released : Ref[Bool]
  forwarded : Ref[Bool]
}

///|
fn AwaitingRuntime::AwaitingRuntime(
  inner : @runtime.PortRuntime,
) -> AwaitingRuntime {
  {
    inner,
    entered: Ref(false),
    release: @async.CondVar::Cond(),
    released: Ref(false),
    forwarded: Ref(false),
  }
}

///|
impl @runtime.Runtime for AwaitingRuntime with fn supports_bound_tools(
  _self : AwaitingRuntime,
) -> Bool {
  true
}

///|
impl @runtime.Runtime for AwaitingRuntime with fn call_model(
  self,
  scope,
  messages,
  tool_definitions,
  call_options,
  on_chunk,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  @runtime.Runtime::call_model(
    self.inner,
    scope,
    messages,
    tool_definitions,
    call_options,
    on_chunk,
  )
}

///|
impl @runtime.Runtime for AwaitingRuntime with fn execute_tool(
  self : AwaitingRuntime,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if ctx.tool_name.to_string() != "dyn_echo" {
    return @runtime.Runtime::execute_tool(self.inner, ctx)
  }
  self.entered.val = true
  while !self.released.val {
    self.release.wait()
  }
  self.forwarded.val = true
  @runtime.Runtime::execute_tool(self.inner, ctx)
}

///|
impl @runtime.Runtime for AwaitingRuntime with fn cancel_effects(
  self,
  effect_ids,
  reason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  @runtime.Runtime::cancel_effects(self.inner, effect_ids, reason)
}

///|
impl @runtime.Runtime for AwaitingRuntime with fn compact(
  self,
  scope,
  messages,
  tools,
  call_options,
  trigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  @runtime.Runtime::compact(
    self.inner,
    scope,
    messages,
    tools,
    call_options,
    trigger,
  )
}

///|
async test "tool_lifecycle/hard_withdraw_while_a_runtime_decorator_awaits_is_refused_at_the_final_gate" {
  let provider = RecordingToolProvider(
    [tk_tool_def("dyn_echo", "dynamic echo")],
    Map::from_array([("dyn_echo", OutcomeOk(tk_ok_result("echo-v1")))]),
  )
  let publisher = ManualPublisher::new()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let inner = @runtime.PortRuntime(
    model=model as &@port.ModelPort,
    tools=Map::from_array([]),
  )
  let runtime = AwaitingRuntime::AwaitingRuntime(inner)
  let observer = RecordingObserver()
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), observers=[observer]),
      tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
    runtime=runtime as &@runtime.Runtime,
  )
  let capability = publisher.capability()
  ignore(capability.replace(provider=provider as &@port.ToolProvider))
  @async.with_timeout(5_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "decorator-wait")
      })
      while !runtime.entered.val {
        @async.pause()
      }
      // The wave has already committed its start and the decorator is waiting;
      // the withdrawal must still prevent the provider from being entered.
      match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
        Ok(_) => ()
        Err(error) => fail("hard withdraw rejected: " + error.to_string())
      }
      runtime.released.val = true
      runtime.release.broadcast()
      let result = turn.wait()
      guard result.tool_results is [NotExecuted(reason=Revoked, ..)] else {
        fail(
          "the final gate must settle Revoked: " +
          contribution_result_texts(result.tool_results).join(","),
        )
      }
    })
  })
  assert_true(runtime.forwarded.val)
  assert_eq(provider.exec_records().length(), 0)
  assert_eq(
    observer.events().filter(e => e is ToolCallAbandoned(..)).length(),
    1,
  )
  assert_eq(
    observer.events().filter(e => e is ToolCallRejected(..)).length(),
    0,
  )
  agent.shutdown()
}

///|
/// Provider that only stops when its registered `ToolCancellable` facet is
/// invoked, so the test can prove the withdrawal reached the real effect.
priv struct CancellableProvider {
  entered : Ref[Bool]
  stopped : Ref[Bool]
  wake : @async.CondVar
  cancels : Array[Int32]
  mut executed : Int32
}

///|
fn CancellableProvider::CancellableProvider() -> CancellableProvider {
  {
    entered: Ref(false),
    stopped: Ref(false),
    wake: @async.CondVar::Cond(),
    cancels: [],
    executed: 0,
  }
}

///|
impl @port.ToolProvider for CancellableProvider with fn list_tools(
  _self : CancellableProvider,
) -> Array[@kernel.ToolDef] {
  [tk_tool_def("dyn_echo", "dynamic echo")]
}

///|
impl @port.ToolProvider for CancellableProvider with fn execute(
  self : CancellableProvider,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome {
  self.executed = self.executed + 1
  let facet : &@port.ToolCancellable = self as &@port.ToolCancellable
  (ctx.register_cancel)(facet)
  self.entered.val = true
  while !self.stopped.val {
    self.wake.wait()
  }
  tk_ok_result("provider stopped itself")
}

///|
impl @port.ToolCancellable for CancellableProvider with fn cancel(
  self : CancellableProvider,
  effect_id : @kernel.EffectId,
  _reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  self.cancels.push(effect_id.to_int())
  self.stopped.val = true
  self.wake.broadcast()
  // The provider really stopped its own work; core records this report instead
  // of inventing a completion.
  @kernel.CancelDisposition::Stopped
}

///|
async test "tool_lifecycle/hard_withdraw_cancels_the_in_flight_effect_and_keeps_the_real_outcome" {
  let provider = CancellableProvider::CancellableProvider()
  let publisher = ManualPublisher::new()
  let retire = RetireProbe::RetireProbe()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("dyn_echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="contrib", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let capability = publisher.capability()
  ignore(
    capability.replace(
      provider=provider as &@port.ToolProvider,
      retire=retire.callback(),
    ),
  )
  @async.with_timeout(8_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "in-flight-hard")
      })
      while !provider.entered.val {
        @async.pause()
      }
      match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
        Ok(_) => ()
        Err(error) => fail("hard withdraw rejected: " + error.to_string())
      }
      let result = turn.wait()
      // The provider's own report is the outcome: the core neither fabricates a
      // cancellation result nor invents a business failure.
      guard result.tool_results
        is [Success(content="provider stopped itself", ..)] else {
        fail(
          "in-flight revocation must keep the provider's real outcome: " +
          contribution_result_texts(result.tool_results).join(","),
        )
      }
    })
  })
  assert_eq(provider.cancels.length(), 1)
  assert_eq(provider.executed, 1)
  // The version stayed alive while its operation ran, then retired once the
  // operation settled.
  assert_eq(retire.completed, 1)
  agent.shutdown()
}

///|
/// Parent tool that hard-withdraws the child's owner while it runs, then asks
/// for the child through the real invocation seam.
priv struct RevokingParent {
  mut child_capability : @port.ToolContributions?
  replies : Array[@kernel.InvocationResult]
}

///|
impl @port.Extension for RevokingParent with fn extension_id(
  _self : RevokingParent,
) -> String {
  "parent"
}

///|
impl @port.Extension for RevokingParent with fn manifest(self : RevokingParent) -> @port.ExtensionManifest {
  @port.ExtensionManifest(id="parent", tools=[self], tool_call_owners=["child"])
}

///|
impl @port.ToolProvider for RevokingParent with fn list_tools(
  _self : RevokingParent,
) -> Array[@kernel.ToolDef] {
  [{ ..tk_tool_def("parent", "call a child"), policy: Exclusive, }]
}

///|
impl @port.ToolProvider for RevokingParent with fn execute(
  self : RevokingParent,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome {
  let capability = match self.child_capability {
    Some(value) => value
    None => abort("child capability was not composed")
  }
  match capability.withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(_) => ()
    Err(error) => abort("child hard withdraw rejected: " + error.to_string())
  }
  self.replies.push(_ctx.invoke("child", {}))
  tk_ok_result("parent done")
}

///|
/// Child-side publisher: takes the capability in `on_compose` only.
priv struct ChildPublisher {
  mut contributions : @port.ToolContributions?
}

///|
impl @port.Lifecycle for ChildPublisher with fn on_compose(
  self : ChildPublisher,
  view : @port.CompositionView,
) {
  self.contributions = view.tool_contributions()
}

///|
impl @port.Lifecycle for ChildPublisher with fn on_shutdown(
  _self : ChildPublisher,
) {
  ()
}

///|
async test "tool_lifecycle/hard_withdraw_refuses_a_child_of_a_captured_version" {
  let child_provider = RecordingToolProvider(
    [tk_tool_def("child", "child tool")],
    Map::from_array([("child", OutcomeOk(tk_ok_result("child ran")))]),
  )
  let parent = RevokingParent::{ child_capability: None, replies: [], }
  let child_publisher = ChildPublisher::{ contributions: None, }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      parent,
      tk_ext(id="child", lifecycle=[child_publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let child_capability = match child_publisher.contributions {
    Some(value) => value
    None => fail("child capability was not composed")
  }
  ignore(
    child_capability.replace(provider=child_provider as &@port.ToolProvider),
  )
  parent.child_capability = Some(child_capability)
  let result = agent.run_turn(tk_user_msg("hello"), "child-revoked")
  guard parent.replies is [Completed(NotExecuted(reason=Revoked, ..))] else {
    fail("the child of a revoked version must settle Revoked")
  }
  assert_eq(contribution_result_texts(result.tool_results), ["parent done"])
  // The child provider was never entered.
  assert_eq(child_provider.exec_records().length(), 0)
  agent.shutdown()
}

///|
async test "tool_lifecycle/hard_withdraw_is_repeatable_and_scoped_to_one_owner" {
  let a_provider = RecordingToolProvider(
    [tk_tool_def("a_tool", "owner a")],
    Map::from_array([("a_tool", OutcomeOk(tk_ok_result("a")))]),
  )
  let b_provider = RecordingToolProvider(
    [tk_tool_def("b_tool", "owner b")],
    Map::from_array([("b_tool", OutcomeOk(tk_ok_result("b")))]),
  )
  let a = ManualPublisher::new()
  let b = ManualPublisher::new()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("a_tool", "a1", Json::null())),
    Respond(tk_stop_response("first")),
    Respond(tk_tool_call_response("a_tool", "a2", Json::null())),
    Respond(tk_tool_call_response("b_tool", "b1", Json::null())),
    Respond(tk_stop_response("second")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="a", lifecycle=[a], requires=[@port.ToolContribution]),
      tk_ext(id="b", lifecycle=[b], requires=[@port.ToolContribution]),
    ],
    config=tk_config(),
  )
  ignore(a.capability().replace(provider=a_provider as &@port.ToolProvider))
  ignore(b.capability().replace(provider=b_provider as &@port.ToolProvider))
  let first = agent.run_turn(tk_user_msg("hello"), "owner-isolation")
  assert_eq(contribution_result_texts(first.tool_results), ["a"])
  let revoked = match
    a.capability().withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("hard withdraw rejected: " + error.to_string())
  }
  let again = match a.capability().withdraw(mode=@port.ToolWithdrawMode::Hard) {
    Ok(commit) => commit
    Err(error) => fail("repeated hard withdraw rejected: " + error.to_string())
  }
  assert_eq(again.revision, revoked.revision)
  assert_eq(b.capability().state().to_string(), "Active")
  // Same session, next operation: the revoked tool is gone from the directory,
  // the other owner's tool still runs.
  let second = agent.run_turn(tk_user_msg("again"), "owner-isolation")
  guard second.tool_results
    is [NotExecuted(reason=UnknownTool, ..), Success(content="b", ..)] else {
    fail(
      "hard withdrawal must not affect another owner: " +
      contribution_result_texts(second.tool_results).join(","),
    )
  }
  assert_eq(a_provider.exec_records().length(), 1)
  assert_eq(b_provider.exec_records().length(), 1)
  agent.shutdown()
}

///|
async test "tool_lifecycle/concurrent_publication_does_not_reenter_a_retiring_version" {
  let publisher = ManualPublisher::new()
  let provider = RecordingToolProvider([tk_tool_def("leaf", "leaf")], Map([]))
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(ScriptedModel([]))),
      tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=tk_config(),
  )
  let calls = Ref(0)
  let released = Ref(false)
  let signal = @async.CondVar::Cond()
  let cap = publisher.capability()
  let _ = cap.replace(provider~, retire=async fn() {
    calls.val += 1
    if calls.val > 1 {
      return Err("retire entered concurrently")
    }
    while !released.val {
      signal.wait()
    }
    Ok(())
  })
  @async.with_task_group(async fn(group) {
    let withdrawn = group.spawn(() => cap.withdraw())
    while calls.val == 0 {
      @async.pause()
    }
    guard cap.replace(provider~) is Ok(_) else {
      fail("a new publication must not reenter an in-progress retire")
    }
    released.val = true
    signal.broadcast()
    guard withdrawn.wait() is Ok(_) else { fail("first withdrawal failed") }
  })
  assert_eq(calls.val, 1)
  agent.shutdown()
}
