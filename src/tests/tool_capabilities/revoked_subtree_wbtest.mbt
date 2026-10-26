///|
priv struct SubtreeStop {
  signal : @async.CondVar
  stopped : Ref[Bool]
  calls : Ref[Int32]
  confirms : Bool
}

///|
impl @port.ToolCancellable for SubtreeStop with fn cancel(self, _id, _reason) {
  self.calls.val += 1
  if self.confirms {
    self.stopped.val = true
    self.signal.broadcast()
    @kernel.CancelDisposition::Stopped
  } else {
    @kernel.CancelDisposition::Propagated
  }
}

///|
priv struct SubtreeOwner {
  publisher : ManualPublisher
}

///|
impl @port.Extension for SubtreeOwner with fn extension_id(_) {
  "parent"
}

///|
impl @port.Extension for SubtreeOwner with fn manifest(self) {
  @port.ExtensionManifest(
    id="parent",
    lifecycle=[self.publisher],
    requires=[@port.ToolContribution],
    tool_call_owners=["child"],
  )
}

///|
async test "tool_lifecycle/hard_parent_cancels_cross_owner_child_not_parallel_root" {
  let signal = @async.CondVar::Cond()
  let child_entered = Ref(false)
  let other_entered = Ref(false)
  let parent_done = Ref(false)
  let parent_stop = SubtreeStop::{
    signal,
    stopped: Ref(false),
    calls: Ref(0),
    confirms: false,
  }
  let child_stop = SubtreeStop::{
    signal,
    stopped: Ref(false),
    calls: Ref(0),
    confirms: true,
  }
  let other_stop = SubtreeStop::{
    signal,
    stopped: Ref(false),
    calls: Ref(0),
    confirms: true,
  }
  let parent = InvocationFixture::{
    id: "parent",
    owners: ["child"],
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Parallel, }],
    action: async fn(ctx) {
      (ctx.register_cancel)(parent_stop)
      let result = ctx.invoke("child", {})
      parent_done.val = true
      signal.broadcast()
      match result {
        Completed(outcome) => outcome
        Interrupted(reason~, ..) =>
          RuntimeFailure(error_category="Interrupted", message=reason)
      }
    },
  }
  let child = InvocationFixture::{
    id: "child",
    owners: [],
    definitions: [
      { ..tk_tool_def("child", "child"), policy: Parallel, exposure: Deferred, },
    ],
    action: async fn(ctx) {
      (ctx.register_cancel)(child_stop)
      child_entered.val = true
      signal.broadcast()
      while !child_stop.stopped.val {
        signal.wait()
      }
      tk_ok_result("child stopped")
    },
  }
  let other = InvocationFixture::{
    id: "other",
    owners: [],
    definitions: [{ ..tk_tool_def("other", "other"), policy: Parallel, }],
    action: async fn(ctx) {
      (ctx.register_cancel)(other_stop)
      other_entered.val = true
      signal.broadcast()
      while !other_stop.stopped.val {
        signal.wait()
      }
      tk_ok_result("other finished")
    },
  }
  let response = tk_tool_call_response("parent", "p", Json::null())
  let other_call = tk_tool_call_response("other", "o", Json::null()).completion.message.tool_calls[0]
  let completion = response.completion
  let message = completion.message
  let response = {
    ..response,
    completion: {
      ..completion,
      message: { ..message, tool_calls: [message.tool_calls[0], other_call], },
    },
  }
  let publisher = ManualPublisher::new()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([Respond(response), Respond(tk_stop_response("done"))]),
        ),
      ),
      SubtreeOwner::{ publisher, },
      child,
      other,
    ],
    config=tk_config(),
  )
  ignore(publisher.capability().replace(provider=parent))
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "hard-subtree")
      })
      while !child_entered.val || !other_entered.val {
        signal.wait()
      }
      ignore(publisher.capability().withdraw(mode=@port.Hard))
      while !parent_done.val {
        signal.wait()
      }
      assert_eq(parent_stop.calls.val, 1)
      assert_eq(child_stop.calls.val, 1)
      assert_eq(other_stop.calls.val, 0)
      assert_false(other_stop.stopped.val)
      other_stop.stopped.val = true
      signal.broadcast()
      let result = turn.wait()
      assert_eq(contribution_result_texts(result.tool_results), [
        "child stopped", "other finished",
      ])
    })
  })
  agent.shutdown()
}

///|
async test "tool_lifecycle/hard_parent_blocks_queued_children_and_new_invocations" {
  let signal = @async.CondVar::Cond()
  let first_started = Ref(false)
  let second_approved = Ref(false)
  let forbidden_starts = Ref(0)
  let replies : Array[@kernel.InvocationResult] = []
  let first_stop = SubtreeStop::{
    signal,
    stopped: Ref(false),
    calls: Ref(0),
    confirms: true,
  }
  let parent = InvocationFixture::{
    id: "parent",
    owners: ["child"],
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    action: async fn(ctx) {
      replies.append(
        @async.all([
          async fn() { ctx.invoke("first", {}) },
          async fn() { ctx.invoke("second", {}) },
        ]),
      )
      assert_eq(ctx.tools().length(), 0)
      replies.push(ctx.invoke("third", {}))
      tk_ok_result("joined revoked subtree")
    },
  }
  let child = InvocationFixture::{
    id: "child",
    owners: [],
    definitions: ["first", "second", "third"].map(name => {
      ..tk_tool_def(name, name),
      policy: Sequential,
      exposure: Deferred,
    }),
    action: async fn(ctx) {
      if ctx.name.to_string() == "first" {
        (ctx.register_cancel)(first_stop)
        first_started.val = true
        signal.broadcast()
        while !first_stop.stopped.val {
          signal.wait()
        }
      } else {
        forbidden_starts.val += 1
      }
      tk_ok_result("child settled")
    },
  }
  let hook = InvocationHook::{
    decide: call => {
      if call.name.to_string() == "second" {
        second_approved.val = true
        signal.broadcast()
      }
      Approve(call~)
    },
  }
  let publisher = ManualPublisher::new()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_tool_call_response("parent", "p", Json::null())),
            Respond(tk_stop_response("done")),
          ]),
        ),
        hooks=[hook],
      ),
      SubtreeOwner::{ publisher, },
      child,
    ],
    config=tk_config(),
  )
  ignore(publisher.capability().replace(provider=parent))
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "queued-revocation")
      })
      while !first_started.val || !second_approved.val {
        signal.wait()
      }
      ignore(publisher.capability().withdraw(mode=@port.Hard))
      ignore(turn.wait())
    })
  })
  assert_eq(forbidden_starts.val, 0)
  assert_eq(first_stop.calls.val, 1)
  guard replies
    is [
      Completed(Success(..)),
      Interrupted(side_effects_possible=false, ..),
      Interrupted(side_effects_possible=false, ..),
    ] else {
    fail("queued or new invocation did not terminate as interrupted")
  }
  agent.shutdown()
}

///|
async test "tool_lifecycle/hard_parent_ends_child_confirmation_wait_without_entering_provider" {
  let hook = WaitingChildHook::{
    waiting: Ref(false),
    exited: Ref(false),
    signal: @async.CondVar::Cond(),
  }
  let replies : Array[@kernel.InvocationResult] = []
  let parent = InvocationFixture::{
    id: "parent",
    owners: ["child"],
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    action: async fn(ctx) {
      replies.push(ctx.invoke("child", {}))
      tk_ok_result("confirmation ended")
    },
  }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map([]),
  )
  let publisher = ManualPublisher::new()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_tool_call_response("parent", "p", Json::null())),
            Respond(tk_stop_response("done")),
            Respond(tk_stop_response("reused")),
          ]),
        ),
        hooks=[hook],
      ),
      SubtreeOwner::{ publisher, },
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  ignore(publisher.capability().replace(provider=parent))
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "hard-consent")
      })
      while !hook.waiting.val {
        hook.signal.wait()
      }
      ignore(publisher.capability().withdraw(mode=@port.Hard))
      ignore(turn.wait())
    })
  })
  assert_true(hook.exited.val)
  assert_eq(child.exec_records().length(), 0)
  guard replies is [Completed(NotExecuted(reason=Revoked, ..))] else {
    fail("unstarted child was not settled as revoked")
  }
  ignore(agent.run_turn(tk_user_msg("retry"), "hard-consent"))
  agent.shutdown()
}

///|
async test "tool_lifecycle/hard_parent_blocks_static_child_after_runtime_await" {
  let publisher = ManualPublisher::new()
  let replies : Array[@kernel.InvocationResult] = []
  let parent = InvocationFixture::{
    id: "parent",
    owners: ["child"],
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    action: async fn(ctx) {
      replies.push(ctx.invoke("dyn_echo", Json::null()))
      tk_ok_result("parent settled")
    },
  }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("dyn_echo", "static child"), exposure: Deferred, }],
    Map([]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let runtime = AwaitingRuntime::AwaitingRuntime(
    @runtime.PortRuntime(model~, tools=Map([])),
  )
  let observer = RecordingObserver()
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), observers=[observer]),
      SubtreeOwner::{ publisher, },
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
    runtime~,
  )
  ignore(publisher.capability().replace(provider=parent))
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(() => {
        agent.run_turn(tk_user_msg("hello"), "hard-late-static")
      })
      while !runtime.entered.val {
        @async.pause()
      }
      ignore(publisher.capability().withdraw(mode=@port.Hard))
      runtime.released.val = true
      runtime.release.broadcast()
      ignore(turn.wait())
    })
  })
  assert_eq(child.exec_records().length(), 0)
  guard replies
    is [
      Interrupted(cancellation=AlreadySettled, side_effects_possible=false, ..),
    ] else {
    fail("static child entered after its captured ancestor was revoked")
  }
  assert_eq(
    observer.events().filter(e => e is ToolCallAbandoned(..)).length(),
    1,
  )
  agent.shutdown()
}
