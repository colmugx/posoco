///|
using @support {probe_effect}

///|
using @support {type CancellableProbe}

///|
/// Port-level cancellation contract: a ToolProvider that registers a
/// `ToolCancellable` facet via `ToolCallContext.register_cancel` has the
/// facet routed by `PortRuntime.cancel_effects` while the effect is in
/// flight; plain providers and already-settled effects report
/// `NotPropagated`.

///|
async test "port cancel/registered facet routes while effect in flight" {
  let model = ScriptedModel([])
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
      @kernel.CancelReason::HostRequested(detail=Some("port cancel test")),
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
  let model = ScriptedModel([])
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
    @kernel.CancelReason::DeadlineReached,
  )
  debug_inspect(dispositions.map(pair => pair.1), content="[NotPropagated]")
  assert_eq(probe.cancelled_effects, [])
}

///|
async test "port cancel/plain provider and unknown ids stay not propagated" {
  let model = ScriptedModel([])
  let tools = RecordingToolProvider(
    [tk_tool_def("plain", "")],
    Map::from_array([("plain", OutcomeOk(tk_ok_result("ok")))]),
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
    @kernel.CancelReason::DeadlineReached,
  )
  debug_inspect(
    dispositions.map(pair => pair.1),
    content="[NotPropagated, NotPropagated]",
  )
}
