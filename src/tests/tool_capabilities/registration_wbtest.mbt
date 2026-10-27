///|
using @support {type CancellableProbe}

///|
async test "port cancel/equal effect ids cancel only the specified run" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(model=ScriptedModel([]))
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(
          runtime.execute_tool(probe_effect(7, provider=probe, run_id="one")),
        )
      })
      group.spawn_bg(() => {
        ignore(
          runtime.execute_tool(probe_effect(7, provider=probe, run_id="two")),
        )
      })
      while probe.registered_effects.length() < 2 {
        @async.pause()
      }
      let report = runtime.cancel_effects(
        [{ value: 7, }],
        DeadlineReached,
        run_id=@kernel.RunId::unchecked("one"),
      )
      assert_true(report[0].1 is Propagated)
      assert_eq(probe.cancelled_runs, ["one"])
      assert_eq(probe.cancelled_effects, [7])
      probe.release.put(1)
      probe.release.put(1)
    })
  })
}

///|
async test "port cancel/duplicate live run effect cannot replace its registration" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(model=ScriptedModel([]))
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(
          runtime.execute_tool(probe_effect(7, provider=probe, run_id="one")),
        )
      })
      while probe.registered_effects.is_empty() {
        @async.pause()
      }
      try
        runtime.execute_tool(probe_effect(7, provider=probe, run_id="one"))
      catch {
        error =>
          assert_true(error.to_string().contains("duplicate live tool effect"))
      } noraise {
        _ => fail("duplicate execution must not enter the provider")
      }
      assert_eq(probe.registered_effects, [7])
      let report = runtime.cancel_effects(
        [{ value: 7, }],
        DeadlineReached,
        run_id=@kernel.RunId::unchecked("one"),
      )
      assert_true(report[0].1 is Propagated)
      assert_eq(probe.cancelled_effects, [7])
      probe.release.put(1)
    })
  })
}

///|
async test "port cancel/run scoped registrations isolate unknown runs and reject duplicates" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(model=ScriptedModel([]))
  @async.with_timeout(5_000, async fn() {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(
          runtime.execute_tool(probe_effect(7, provider=probe, run_id="a")),
        )
      })
      group.spawn_bg(() => {
        ignore(
          runtime.execute_tool(probe_effect(7, provider=probe, run_id="b")),
        )
      })
      while probe.registered_effects.length() < 2 {
        @async.pause()
      }
      try
        runtime.execute_tool(probe_effect(7, provider=probe, run_id="a"))
      catch {
        error =>
          assert_true(error.to_string().contains("duplicate live tool effect"))
      } noraise {
        _ => fail("duplicate execution overwrote an unsettled registration")
      }
      let reports = runtime.cancel_effects(
        [{ value: 7, }],
        DeadlineReached,
        run_id=@kernel.RunId::unchecked("unknown"),
      )
      assert_true(reports[0].1 is NotPropagated)
      assert_eq(probe.registered_effects, [7, 7])
      assert_eq(probe.cancelled_effects, [])
      probe.release.put(1)
      probe.release.put(1)
    })
  })
}

///|
async test "port cancel/registrar_expires_even_for_a_manually_constructed_context" {
  let saved : Array[@port.ToolCallContext] = []
  let provider = InvocationFixture::{
    id: "probe_owner",
    definitions: [tk_tool_def("probe", "probe")],
    owners: [],
    action: ctx => {
      saved.push(ctx)
      tk_ok_result("settled")
    },
  }
  let runtime = @runtime.PortRuntime(model=ScriptedModel([]))
  ignore(runtime.execute_tool(probe_effect(7, provider~, run_id="settled")))
  let late = CancellationProbe::{ disposition: Stopped, ids: [], }
  (saved[0].register_cancel)(late)
  let reports = runtime.cancel_effects(
    [{ value: 7, }],
    DeadlineReached,
    run_id=@kernel.RunId::unchecked("settled"),
  )
  debug_inspect(reports.map(entry => entry.1), content="[NotPropagated]")
  assert_eq(late.ids, [])
}
