///|
/// Port-level cancellation contract: a ToolProvider that registers a
/// `ToolCancellable` facet via `ToolCallContext.register_cancel` has the
/// facet routed by `PortRuntime.cancel_effects` while the effect is in
/// flight; plain providers and already-settled effects report
/// `NotPropagated`.

///|
/// Cancellable fake: registers its facet at execute start, then suspends on
/// a release queue so the effect stays in flight until the test lets it go.
priv struct CancellableProbe {
  release : @aqueue.Queue[Int]
  registered_effects : Array[Int]
  cancelled_effects : Array[Int]
  seen_reasons : Array[@kernel.CancelReason]
}

///|
fn CancellableProbe::CancellableProbe() -> CancellableProbe {
  {
    release: Queue(kind=Unbounded),
    registered_effects: [],
    cancelled_effects: [],
    seen_reasons: [],
  }
}

///|
impl @port.ToolProvider for CancellableProbe with fn list_tools(_self) {
  [tk_tool_def("probe", "cancellable probe")]
}

///|
impl @port.ToolProvider for CancellableProbe with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  (ctx.register_cancel)(self as &@port.ToolCancellable)
  self.registered_effects.push(ctx.effect_id.to_int())
  ignore(self.release.get() catch { _ => 0 })
  tk_ok_result("probe settled")
}

///|
impl @port.ToolCancellable for CancellableProbe with fn cancel(
  self,
  effect_id : @kernel.EffectId,
  reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  self.cancelled_effects.push(effect_id.to_int())
  self.seen_reasons.push(reason)
  @kernel.CancelDisposition::Propagated
}

///|
fn probe_effect(
  effect_id : Int,
  tool_name? : String = "probe",
) -> @runtime.EffectContext {
  {
    effect_id: { value: effect_id, },
    owner: @kernel.OwnerId::unchecked("probe_owner"),
    call_id: @kernel.CallId::unchecked("call_probe"),
    tool_name: @kernel.ToolName::unchecked(tool_name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
async test "port cancel/registered facet routes while effect in flight" {
  let model = ScriptedModel([])
  let probe = CancellableProbe()
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("probe", probe as &@port.ToolProvider)]),
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => ignore(port_runtime.execute_tool(probe_effect(7))))
    // Let the task register its facet and suspend on the release queue.
    @async.sleep(5)
    let dispositions = @runtime.Runtime::cancel_effects(
      port_runtime,
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
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("probe", probe as &@port.ToolProvider)]),
  )
  // Pre-loaded release: execute runs to completion, the effect settles, and
  // the registration is dropped.
  probe.release.put(1)
  let outcome = @runtime.Runtime::execute_tool(port_runtime, probe_effect(3))
  guard outcome is Success(..) else { fail("expected probe success") }
  assert_eq(probe.registered_effects, [3])
  let dispositions = @runtime.Runtime::cancel_effects(
    port_runtime,
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
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("plain", tools as &@port.ToolProvider)]),
  )
  let outcome = @runtime.Runtime::execute_tool(
    port_runtime,
    probe_effect(4, tool_name="plain"),
  )
  guard outcome is Success(..) else { fail("expected plain success") }
  let dispositions = @runtime.Runtime::cancel_effects(
    port_runtime,
    [{ value: 4, }, { value: 5, }],
    @kernel.CancelReason::DeadlineReached,
  )
  debug_inspect(
    dispositions.map(pair => pair.1),
    content="[NotPropagated, NotPropagated]",
  )
}
