///|
async test "tool_invoke/unjoined_parent_cannot_report_success_and_its_waiter_is_released" {
  let entered = Ref(false)
  let signal = @async.CondVar::Cond()
  let replies : Array[@kernel.InvocationResult] = []
  let observer = RecordingObserver()
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let parent = InvocationFixture::{
        id: "parent",
        definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
        owners: ["child"],
        action: async fn(ctx) {
          // Deliberately break structured use of ctx.invoke: its task is
          // owned by this test's outer group, not by the parent provider.
          group.spawn_bg(async fn() {
            replies.push(ctx.invoke("child", Json::null()))
            signal.broadcast()
          })
          while !entered.val {
            signal.wait()
          }
          tk_ok_result("must not become success")
        },
      }
      let child = InvocationFixture::{
        id: "child",
        owners: [],
        definitions: [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
        action: async fn(_ctx) {
          entered.val = true
          signal.broadcast()
          let never = @async.CondVar::Cond()
          never.wait()
          tk_ok_result("unreachable")
        },
      }
      let model = ScriptedModel([
        Respond(tk_tool_call_response("parent", "p", Json::null())),
      ])
      let agent = Agent(
        exts=[
          tk_ext(id="model", model=Some(model), observers=[observer]),
          parent,
          child,
        ],
        config=tk_config(),
      )
      try agent.run_turn(tk_user_msg("hello"), "unjoined") catch {
        error => assert_true(error.to_string().contains("joining"))
      } noraise {
        _ => fail("unjoined parent was reported as successful")
      }
      while replies.is_empty() {
        signal.wait()
      }
      guard replies is [Interrupted(..)] else {
        fail("abandoned child's waiter was not interrupted")
      }
      assert_eq(
        observer.events().filter(e => e is ToolCallSucceeded(..)).length(),
        0,
      )
      assert_eq(
        observer.events().filter(e => e is ToolCallAbandoned(..)).length(),
        2,
      )
    })
  })
}

///|
priv struct CancellationProbe {
  mut disposition : @kernel.CancelDisposition
  ids : Array[Int32]
}

///|
impl @port.ToolCancellable for CancellationProbe with fn cancel(
  self,
  effect_id,
  _reason,
) -> @kernel.CancelDisposition {
  self.ids.push(effect_id.to_int())
  self.disposition
}

///|
async test "tool_cleanup/unjoined_child_is_cancelled_and_only_confirmed_stop_allows_reuse" {
  for
    disposition in (
      [
        @kernel.CancelDisposition::Stopped,
        @kernel.CancelDisposition::Propagated,
      ] : Array[@kernel.CancelDisposition]) {
    let probe = CancellationProbe::{ disposition, ids: [], }
    let entered = Ref(false)
    let signal = @async.CondVar::Cond()
    let replies : Array[@kernel.InvocationResult] = []
    @async.with_timeout(2000, async fn() {
      @async.with_task_group(async fn(group) {
        let parent = InvocationFixture::{
          id: "parent",
          definitions: [
            { ..tk_tool_def("parent", "parent"), policy: Exclusive, },
          ],
          owners: ["child"],
          action: async fn(ctx) {
            group.spawn_bg(async fn() {
              replies.push(ctx.invoke("child", {}))
              signal.broadcast()
            })
            while !entered.val {
              signal.wait()
            }
            tk_ok_result("must not succeed")
          },
        }
        let child = InvocationFixture::{
          id: "child",
          owners: [],
          definitions: [
            { ..tk_tool_def("child", "child"), exposure: Deferred, },
          ],
          action: async fn(ctx) {
            (ctx.register_cancel)(probe)
            entered.val = true
            signal.broadcast()
            let never = @async.CondVar::Cond()
            never.wait()
            tk_ok_result("unreachable")
          },
        }
        let model = ScriptedModel([
          Respond(tk_tool_call_response("parent", "p", Json::null())),
          Respond(tk_stop_response("recovered")),
        ])
        let agent = Agent(
          exts=[tk_ext(id="model", model=Some(model)), parent, child],
          config=tk_config(),
        )
        try agent.run_turn(tk_user_msg("hello"), "cleanup-reuse") catch {
          error => assert_true(error.to_string().contains("joining"))
        } noraise {
          _ => fail("parent returned success without joining")
        }
        while replies.is_empty() {
          signal.wait()
        }
        assert_eq(probe.ids.length(), 1)
        guard replies
          is [Interrupted(cancellation~, side_effects_possible=true, ..)] else {
          fail("child was not truthfully interrupted")
        }
        assert_eq(cancellation, disposition)
        if disposition is Stopped {
          let _ = agent.run_turn(tk_user_msg("retry"), "cleanup-reuse")
          assert_eq(model.call_count(), 2)
        } else {
          try
            agent.run_turn(tk_user_msg("unsafe retry"), "cleanup-reuse")
          catch {
            error =>
              assert_true(
                error.to_string().contains("unconfirmed tool execution"),
              )
          } noraise {
            _ => fail("signal propagation was mistaken for execution cleanup")
          }
          assert_eq(model.call_count(), 1)
          probe.disposition = Stopped
          agent.shutdown()
          assert_eq(probe.ids.length(), 2)
          assert_eq(probe.ids[0], probe.ids[1])
        }
      })
    })
  }
}

///|
priv struct WaitingChildHook {
  waiting : Ref[Bool]
  exited : Ref[Bool]
  signal : @async.CondVar
}

///|
impl @port.PipelineHook for WaitingChildHook with fn before_tool(self, call) -> @port.ToolDecision {
  if call.name.to_string() == "child" {
    self.waiting.val = true
    self.signal.broadcast()
    defer {
      self.exited.val = true
    }
    let never = @async.CondVar::Cond()
    never.wait()
  }
  Approve(call~)
}

///|
async test "tool_cleanup/abort_cancels_a_child_confirmation_wait_and_keeps_the_session_reusable" {
  let hook = WaitingChildHook::{
    waiting: Ref(false),
    exited: Ref(false),
    signal: @async.CondVar::Cond(),
  }
  let parent_cancel = CancellationProbe::{ disposition: Stopped, ids: [], }
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["child"],
    action: async fn(ctx) {
      (ctx.register_cancel)(parent_cancel)
      match ctx.invoke("child", {}) {
        Completed(outcome) => outcome
        Interrupted(reason~, ..) =>
          RuntimeFailure(error_category="Interrupted", message=reason)
      }
    },
  }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([]),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("recovered")),
  ])
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), hooks=[hook], observers=[observer]),
      parent,
      tk_ext(id="child", tools=[child]),
    ],
    config=tk_config(),
  )
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        try agent.run_turn(tk_user_msg("hello"), "confirmation-abort") catch {
          error => assert_true(error is @error.AgentError::Cancelled(_))
        } noraise {
          _ => fail("aborted turn succeeded")
        }
      })
      while !hook.waiting.val {
        hook.signal.wait()
      }
      ignore(agent.control().abort_active(Some("test cancellation")))
      turn.wait()
    })
  })
  assert_true(hook.exited.val)
  assert_eq(child.exec_records().length(), 0)
  assert_eq(parent_cancel.ids.length(), 1)
  assert_eq(
    observer
    .events()
    .filter(e => {
      e is ToolCallAbandoned(call~, ..) && call.name.to_string() == "child"
    })
    .length(),
    1,
  )
  assert_eq(
    observer
    .events()
    .filter(e => {
      e is ToolCallFailed(call~, ..) && call.name.to_string() == "child"
    })
    .length(),
    0,
  )
  let _ = agent.run_turn(tk_user_msg("retry"), "confirmation-abort")
  assert_eq(model.call_count(), 2)
}

///|
priv struct SettledCoroutineCancellation {
  exited : Ref[Bool]
  calls : Array[Int32]
}

///|
impl @port.ToolCancellable for SettledCoroutineCancellation with fn cancel(
  self,
  id,
  _reason,
) -> @kernel.CancelDisposition {
  self.calls.push(id.to_int())
  if self.exited.val {
    Stopped
  } else {
    NotPropagated
  }
}

///|
async test "tool_cleanup/root_abort_cancels_the_live_subtree_after_provider_tasks_exit" {
  let parent_stop = SettledCoroutineCancellation::{
    exited: Ref(false),
    calls: [],
  }
  let child_stop = SettledCoroutineCancellation::{
    exited: Ref(false),
    calls: [],
  }
  let entered = Ref(false)
  let signal = @async.CondVar::Cond()
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["child"],
    action: async fn(ctx) {
      defer {
        parent_stop.exited.val = true
      }
      (ctx.register_cancel)(parent_stop)
      match ctx.invoke("child", {}) {
        Completed(outcome) => outcome
        Interrupted(reason~, ..) =>
          RuntimeFailure(error_category="Interrupted", message=reason)
      }
    },
  }
  let child = InvocationFixture::{
    id: "child",
    owners: [],
    definitions: [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    action: async fn(ctx) {
      defer {
        child_stop.exited.val = true
      }
      (ctx.register_cancel)(child_stop)
      entered.val = true
      signal.broadcast()
      let never = @async.CondVar::Cond()
      never.wait()
      tk_ok_result("unreachable")
    },
  }
  let observer = RecordingObserver()
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("recovered")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), observers=[observer]),
      parent,
      child,
    ],
    config=tk_config(),
  )
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        try agent.run_turn(tk_user_msg("hello"), "abort-subtree") catch {
          error => assert_true(error is @error.AgentError::Cancelled(_))
        } noraise {
          _ => fail("aborted subtree succeeded")
        }
      })
      while !entered.val {
        signal.wait()
      }
      ignore(agent.control().abort_active(Some("abort subtree")))
      turn.wait()
    })
  })
  assert_true(parent_stop.exited.val)
  assert_true(child_stop.exited.val)
  assert_eq(parent_stop.calls, [2])
  assert_eq(child_stop.calls, [3])
  assert_eq(
    observer
    .events()
    .filter(e => {
      e is ToolCallAbandoned(call~, ..) && call.name.to_string() == "child"
    })
    .length(),
    1,
  )
  assert_eq(
    observer
    .events()
    .filter(e => {
      e is ToolCallFailed(call~, ..) && call.name.to_string() == "child"
    })
    .length(),
    0,
  )
  let _ = agent.run_turn(tk_user_msg("retry"), "abort-subtree")
  assert_eq(model.call_count(), 2)
}
