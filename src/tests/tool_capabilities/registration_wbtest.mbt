///|
using @support {type CancellableProbe}

///|
fn scoped_probe_effect(run_id : String, id : Int32) -> @runtime.EffectContext {
  let effect_id : @kernel.EffectId = { value: id, }
  @runtime.EffectContext(
    effect_id~,
    owner=@kernel.OwnerId::unchecked("probe_owner"),
    call_id=@kernel.CallId::unchecked("probe_call"),
    tool_name=@kernel.ToolName::unchecked("probe"),
    arguments={},
    tool_context=register_cancel => {
      @port.ToolCallContext(
        effect_id~,
        call_id=@kernel.CallId::unchecked("probe_call"),
        name=@kernel.ToolName::unchecked("probe"),
        arguments={},
        register_cancel~,
        scope={
          run_id: @kernel.RunId::unchecked(run_id),
          session_id: @kernel.SessionId::unchecked("probe_session"),
          effect_id: Some(effect_id),
          pressure: None,
        },
      )
    },
  )
}

///|
async test "port cancel/ambiguous effect ids never cancel an arbitrary run" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(
    model=ScriptedModel([]),
    tools=Map::from_array([("probe", probe as &@port.ToolProvider)]),
  )
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(runtime.execute_tool(scoped_probe_effect("one", 7)))
      })
      group.spawn_bg(() => {
        ignore(runtime.execute_tool(scoped_probe_effect("two", 7)))
      })
      while probe.registered_effects.length() < 2 {
        @async.pause()
      }
      try runtime.cancel_effects([{ value: 7, }], DeadlineReached) catch {
        error => assert_true(error.to_string().contains("ambiguous"))
      } noraise {
        _ => fail("cancellation must reject an ambiguous run identity")
      }
      assert_eq(probe.cancelled_effects, [])
      probe.release.put(1)
      probe.release.put(1)
    })
  })
}

///|
async test "port cancel/duplicate live run effect cannot replace its registration" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(
    model=ScriptedModel([]),
    tools=Map::from_array([("probe", probe as &@port.ToolProvider)]),
  )
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(runtime.execute_tool(scoped_probe_effect("one", 7)))
      })
      while probe.registered_effects.is_empty() {
        @async.pause()
      }
      try runtime.execute_tool(scoped_probe_effect("one", 7)) catch {
        error =>
          assert_true(error.to_string().contains("duplicate live tool effect"))
      } noraise {
        _ => fail("duplicate execution must not enter the provider")
      }
      assert_eq(probe.registered_effects, [7])
      let report = runtime.cancel_effects([{ value: 7, }], DeadlineReached)
      assert_true(report[0].1 is Propagated)
      assert_eq(probe.cancelled_effects, [7])
      probe.release.put(1)
    })
  })
}

///|
async test "port cancel/run scoped registrations reject ambiguous and duplicate execution identities" {
  let probe = CancellableProbe()
  let runtime = @runtime.PortRuntime(
    model=ScriptedModel([]),
    tools=Map::from_array([("probe", probe as &@port.ToolProvider)]),
  )
  @async.with_timeout(5_000, async fn() {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        ignore(runtime.execute_tool(probe_effect(7, run_id="a")))
      })
      group.spawn_bg(() => {
        ignore(runtime.execute_tool(probe_effect(7, run_id="b")))
      })
      while probe.registered_effects.length() < 2 {
        @async.pause()
      }
      try runtime.execute_tool(probe_effect(7, run_id="a")) catch {
        error =>
          assert_true(error.to_string().contains("duplicate live tool effect"))
      } noraise {
        _ => fail("duplicate execution overwrote an unsettled registration")
      }
      try runtime.cancel_effects([{ value: 7, }], DeadlineReached) catch {
        error =>
          assert_true(error.to_string().contains("ambiguous tool cancellation"))
      } noraise {
        _ => fail("bare effect id selected an arbitrary run")
      }
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
  let runtime = @runtime.PortRuntime(
    model=ScriptedModel([]),
    tools=Map::from_array([("probe", provider as &@port.ToolProvider)]),
  )
  ignore(runtime.execute_tool(probe_effect(7)))
  let late = CancellationProbe::{ disposition: Stopped, ids: [], }
  (saved[0].register_cancel)(late)
  let reports = runtime.cancel_effects([{ value: 7, }], DeadlineReached)
  debug_inspect(reports.map(entry => entry.1), content="[NotPropagated]")
  assert_eq(late.ids, [])
}
