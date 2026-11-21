///|
using @support {type CancellableProbe}

///|
async test "port cancel/equal effect ids cancel only the specified run" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(model=@test_support.ScriptedModel([]))
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
async test "port cancel/run scoped registrations isolate unknown runs and reject duplicates" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(model=@test_support.ScriptedModel([]))
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
    definitions: [@test_support.tk_tool_def("probe", "probe")],
    owners: [],
    action: ctx => {
      saved.push(ctx)
      @test_support.tk_ok_result("settled")
    },
  }
  let runtime = @runtime.PortRuntime(model=@test_support.ScriptedModel([]))
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

///|
/// Port-level cancellation contract: a ToolProvider that registers a
/// `ToolCancellable` facet via `ToolCallContext.register_cancel` has the
/// facet routed by `PortRuntime.cancel_effects` while the effect is in
/// flight; plain providers and already-settled effects report
/// `NotPropagated`.

///|
async test "port cancel/registered facet routes while effect in flight" {
  let model = @test_support.ScriptedModel([])
  let probe = CancellableProbe()
  let port_runtime = @runtime.PortRuntime(model~)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ignore(
        port_runtime.execute_tool(
          probe_effect(7, provider=probe, run_id="port-test"),
        ),
      )
    })
    // Ready-poll until the spawned task has registered its facet (the
    // registration site records the effect id) and suspended on the release
    // queue — no fixed sleep.
    while probe.registered_effects.length() == 0 {
      @async.pause()
    }
    let dispositions = @runtime.Runtime::cancel_effects(
      port_runtime,
      run_id=@kernel.RunId::unchecked("port-test"),
      [{ value: 7, }, { value: 9, }],
      HostRequested(detail=Some("port cancel test")),
    )
    debug_inspect(
      dispositions.map(pair => pair.1),
      content="[Propagated, NotPropagated]",
    )
    probe.release.put(1)
  })
  assert_eq(probe.registered_effects, [7])
  assert_eq(probe.cancelled_effects, [7])
  guard probe.seen_reasons[0] is HostRequested(detail=Some("port cancel test")) else {
    fail("cancel reason not delivered verbatim")
  }
}

///|
async test "port cancel/settled effect drops its registration" {
  let model = @test_support.ScriptedModel([])
  let probe = CancellableProbe()
  let port_runtime = @runtime.PortRuntime(model~)
  // Pre-loaded release: execute runs to completion, the effect settles, and
  // the registration is dropped.
  probe.release.put(1)
  let outcome = @runtime.Runtime::execute_tool(
    port_runtime,
    probe_effect(3, provider=probe, run_id="port-test"),
  )
  guard outcome is Success(..) else { fail("expected probe success") }
  assert_eq(probe.registered_effects, [3])
  let dispositions = @runtime.Runtime::cancel_effects(
    port_runtime,
    run_id=@kernel.RunId::unchecked("port-test"),
    [{ value: 3, }],
    DeadlineReached,
  )
  debug_inspect(dispositions.map(pair => pair.1), content="[NotPropagated]")
  assert_eq(probe.cancelled_effects, [])
}

///|
async test "port cancel/plain provider and unknown ids stay not propagated" {
  let model = @test_support.ScriptedModel([])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("plain", "")],
    Map::from_array([("plain", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let port_runtime = @runtime.PortRuntime(model~)
  let outcome = @runtime.Runtime::execute_tool(
    port_runtime,
    probe_effect(4, tool_name="plain", provider=tools, run_id="port-test"),
  )
  guard outcome is Success(..) else { fail("expected plain success") }
  let dispositions = @runtime.Runtime::cancel_effects(
    port_runtime,
    run_id=@kernel.RunId::unchecked("port-test"),
    [{ value: 4, }, { value: 5, }],
    DeadlineReached,
  )
  debug_inspect(
    dispositions.map(pair => pair.1),
    content="[NotPropagated, NotPropagated]",
  )
}
