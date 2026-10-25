///|
async test "tool_cleanup/malformed_runtime_receipts_do_not_release_unconfirmed_executions" {
  for shape in ["missing", "duplicate", "foreign"] {
    let entered = Ref(false)
    let signal = @async.CondVar::Cond()
    let facet = CancellationProbe::{ disposition: Stopped, ids: [], }
    let replies : Array[@kernel.InvocationResult] = []
    let observer = RecordingObserver()
    @async.with_timeout(3_000, async fn() {
      @async.with_task_group(group => {
        let parent = InvocationFixture::{
          id: "parent",
          definitions: [
            { ..tk_tool_def("parent", "parent"), policy: Exclusive, },
          ],
          owners: ["child"],
          action: async fn(ctx) {
            group.spawn_bg(() => {
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
          definitions: [
            { ..tk_tool_def("child", "child"), exposure: Deferred, },
          ],
          owners: [],
          action: async fn(ctx) {
            (ctx.register_cancel)(facet)
            entered.val = true
            signal.broadcast()
            let never = @async.CondVar::Cond()
            never.wait()
            tk_ok_result("unreachable")
          },
        }
        let model = ScriptedModel([
          Respond(tk_tool_call_response("parent", "p", {})),
        ])
        let runtime = FakeRuntime(
          @runtime.PortRuntime(model~, tools=Map::from_array([])),
        )
        runtime.bound_support = true
        runtime.cancel_report = Some(ids => {
          if shape == "missing" {
            []
          } else if shape == "duplicate" {
            [(ids[0], Stopped), (ids[0], Stopped)]
          } else {
            [(ids[0], Stopped), ({ value: 999, }, Stopped)]
          }
        })
        let agent = Agent::with_runtime(
          exts=[
            tk_ext(id="model", model=Some(model), observers=[observer]),
            parent,
            child,
          ],
          config=tk_config(),
          runtime~,
        )
        try agent.run_turn(tk_user_msg("hello"), "bad-cancel-report") catch {
          error => {
            let detail = error.to_string()
            assert_true(detail.contains("joining"))
            assert_true(detail.contains("cancellation result"))
          }
        } noraise {
          _ => fail("malformed cancellation report was accepted")
        }
        while replies.is_empty() {
          signal.wait()
        }
        guard replies
          is [
            Interrupted(
              cancellation=NotPropagated,
              side_effects_possible=true,
              ..
            ),
          ] else {
          fail("an invalid report was treated as proof of termination")
        }
        assert_eq(facet.ids, [])
        assert_eq(
          observer
          .events()
          .filter(e => {
            e is Custom(source="posoco.core", label="secondary_failure", ..)
          })
          .length(),
          1,
        )
        try
          agent.run_turn(tk_user_msg("unsafe retry"), "bad-cancel-report")
        catch {
          error =>
            assert_true(
              error.to_string().contains("unconfirmed tool execution"),
            )
        } noraise {
          _ => fail("malformed report released the admission barrier")
        }
        assert_eq(model.call_count(), 1)
        runtime.cancel_report = None
        agent.shutdown()
        assert_eq(facet.ids.length(), 1)
        assert_eq(runtime.cancel_seen.length(), 2)
        assert_eq(runtime.cancel_seen[0], runtime.cancel_seen[1])
      })
    })
  }
}

///|
priv struct FailingToolCancellation {
  mut failing : Bool
  mut hanging : Bool
  mut calls : Int32
}

///|
impl @port.ToolCancellable for FailingToolCancellation with fn cancel(
  self,
  _id,
  _reason,
) -> @kernel.CancelDisposition {
  self.calls += 1
  if self.hanging {
    let never = @async.CondVar::Cond()
    never.wait()
  }
  if self.failing {
    raise @error.RuntimeError::InvocationFailed("cancel facet failed")
  }
  Stopped
}

///|
async test "tool_cleanup/primary_failure_and_cleanup_error_are_both_visible_and_shutdown_can_retry" {
  for hanging in [false, true] {
    let facet = FailingToolCancellation::{
      failing: !hanging,
      hanging,
      calls: 0,
    }
    let entered = Ref(false)
    let signal = @async.CondVar::Cond()
    let observer = RecordingObserver()
    @async.with_timeout(12_000, async fn() {
      @async.with_task_group(async fn(group) {
        let parent = InvocationFixture::{
          id: "parent",
          definitions: [
            { ..tk_tool_def("parent", "parent"), policy: Exclusive, },
          ],
          owners: ["child"],
          action: async fn(ctx) {
            group.spawn_bg(async fn() { ignore(ctx.invoke("child", {})) })
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
            (ctx.register_cancel)(facet)
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
        try agent.run_turn(tk_user_msg("hello"), "cleanup-error") catch {
          error => {
            let detail = error.to_string()
            assert_true(detail.contains("joining"))
            if hanging {
              assert_true(
                detail.contains("Timeout") || detail.contains("timeout"),
              )
            } else {
              assert_true(detail.contains("cancel facet failed"))
            }
          }
        } noraise {
          _ => fail("unjoined parent succeeded")
        }
        assert_eq(facet.calls, 1)
        let diagnostics = observer
          .events()
          .filter(event => {
            event is Custom(source="posoco.core", label="secondary_failure", ..)
          })
        assert_eq(diagnostics.length(), 1)
        try agent.run_turn(tk_user_msg("unsafe retry"), "cleanup-error") catch {
          error =>
            assert_true(
              error.to_string().contains("unconfirmed tool execution"),
            )
        } noraise {
          _ => fail("cleanup error did not retain the execution")
        }
        facet.failing = false
        facet.hanging = false
        agent.shutdown()
        assert_eq(facet.calls, 2)
      })
    })
  }
}

///|
priv struct FailingChildHook {
  defer_call : Bool
}

///|
impl @port.PipelineHook for FailingChildHook with fn before_tool(self, call) -> @port.ToolDecision {
  if call.name.to_string() != "child" {
    return Approve(call~)
  }
  if self.defer_call {
    Defer(reason="child needs external resolution")
  } else {
    raise @port.HookAbort::Aborted(reason="child hook failed")
  }
}

///|
async test "tool_cleanup/child_hook_defer_and_error_end_waiters_without_starting_the_child" {
  for defer_call in [false, true] {
    let replies : Array[@kernel.InvocationResult] = []
    let signal = @async.CondVar::Cond()
    let parent_cancel = CancellationProbe::{ disposition: Stopped, ids: [], }
    let child = RecordingToolProvider(
      [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
      Map::from_array([]),
    )
    let model = ScriptedModel([
      Respond(tk_tool_call_response("parent", "p", {})),
      Respond(tk_stop_response("recovered")),
    ])
    let observer = RecordingObserver()
    @async.with_timeout(3_000, async fn() {
      @async.with_task_group(group => {
        let parent = InvocationFixture::{
          id: "parent",
          definitions: [
            { ..tk_tool_def("parent", "parent"), policy: Exclusive, },
          ],
          owners: ["child"],
          action: async fn(ctx) {
            (ctx.register_cancel)(parent_cancel)
            group.spawn_bg(() => {
              replies.push(ctx.invoke("child", {}))
              signal.broadcast()
            })
            let never = @async.CondVar::Cond()
            never.wait()
            tk_ok_result("unreachable")
          },
        }
        let agent = Agent(
          exts=[
            tk_ext(
              id="model",
              model=Some(model),
              hooks=[FailingChildHook::{ defer_call, }],
              observers=[observer],
            ),
            parent,
            tk_ext(id="child", tools=[child]),
          ],
          config=tk_config(),
        )
        try agent.run_turn(tk_user_msg("hello"), "hook-failure") catch {
          error => {
            let detail = error.to_string()
            if defer_call {
              assert_true(detail.contains("defer not yet supported"))
            } else {
              assert_true(detail.contains("child hook failed"))
            }
          }
        } noraise {
          _ => fail("terminal child hook decision was ignored")
        }
        while replies.is_empty() {
          signal.wait()
        }
        guard replies
          is [
            Interrupted(
              cancellation=AlreadySettled,
              side_effects_possible=false,
              ..
            ),
          ] else {
          fail("unstarted child was reported as an executed failure")
        }
        assert_eq(child.exec_records().length(), 0)
        assert_eq(parent_cancel.ids.length(), 1)
        assert_eq(
          observer
          .events()
          .filter(e => {
            e is ToolCallAbandoned(call~, ..) &&
            call.name.to_string() == "child"
          })
          .length(),
          1,
        )
        let _ = agent.run_turn(tk_user_msg("retry"), "hook-failure")
        assert_eq(model.call_count(), 2)
      })
    })
  }
}

///|
async test "tool_cleanup/runtime_dispatch_failure_ends_waiters_and_retains_unknown_execution_until_acknowledged" {
  let replies : Array[@kernel.InvocationResult] = []
  let signal = @async.CondVar::Cond()
  let parent_cancel = CancellationProbe::{ disposition: Stopped, ids: [], }
  let child = RecordingToolProvider(
    [{ ..tk_tool_def("child", "child"), exposure: Deferred, }],
    Map::from_array([]),
  )
  let model = ScriptedModel([Respond(tk_tool_call_response("parent", "p", {}))])
  let runtime = FakeRuntime(
    @runtime.PortRuntime(model~, tools=Map::from_array([])),
  )
  runtime.bound_support = true
  runtime.fail_tool = Some("child")
  let observer = RecordingObserver()
  @async.with_timeout(3_000, async fn() {
    @async.with_task_group(group => {
      let parent = InvocationFixture::{
        id: "parent",
        definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
        owners: ["child"],
        action: async fn(ctx) {
          (ctx.register_cancel)(parent_cancel)
          group.spawn_bg(() => {
            replies.push(ctx.invoke("child", {}))
            signal.broadcast()
          })
          let never = @async.CondVar::Cond()
          never.wait()
          tk_ok_result("unreachable")
        },
      }
      let agent = Agent::with_runtime(
        exts=[
          tk_ext(id="model", model=Some(model), observers=[observer]),
          parent,
          tk_ext(id="child", tools=[child]),
        ],
        config=tk_config(),
        runtime~,
      )
      try agent.run_turn(tk_user_msg("hello"), "dispatch-failure") catch {
        error => {
          let detail = error.to_string()
          assert_true(detail.contains("child dispatch fault"), msg=detail)
        }
      } noraise {
        _ => fail("runtime failure was swallowed")
      }
      while replies.is_empty() {
        signal.wait()
      }
      guard replies
        is [
          Interrupted(
            cancellation=NotPropagated,
            side_effects_possible=true,
            ..
          ),
        ] else {
        fail("unconfirmed runtime failure was mistaken for a completed child")
      }
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
      try
        agent.run_turn(tk_user_msg("unsafe retry"), "dispatch-failure")
      catch {
        error =>
          assert_true(error.to_string().contains("unconfirmed tool execution"))
      } noraise {
        _ => fail("runtime exception released unknown execution")
      }
      // This trusted decorator knows it failed before dispatch. Only its
      // explicit terminal receipt can settle the conservative core ledger.
      runtime.cancel_report = Some(ids => ids.map(id => (id, AlreadySettled)))
      agent.shutdown()
      assert_eq(runtime.cancel_seen.length(), 2)
      assert_eq(runtime.cancel_seen[1].length(), 1)
      assert_true(runtime.cancel_seen[1][0].to_int() != parent_cancel.ids[0])
    })
  })
}
