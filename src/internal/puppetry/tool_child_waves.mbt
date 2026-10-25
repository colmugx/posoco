///|
/// A parent holds its root scheduling slot until its entire subtree settles.
/// Reuse the kernel scheduler for siblings, including already-running siblings
/// in the first wave. This permits new Parallel work to join a Parallel wave,
/// but never lets later work jump a queued Sequential/Exclusive sibling.
async fn Puppet::start_ready_children(
  self : Puppet,
  tree : ToolTree,
  group : @async.TaskGroup[PumpStep],
  state : RunState,
  context : ExecutionContext,
  dispatcher : EventDispatcher,
  turn_id : TurnId,
) -> Unit raise PuppetError {
  let parents : Map[Int32, EffectId] = Map::from_array([])
  for _, effect in tree.waiting {
    if effect is ExecuteTool(payload~, ..) &&
      payload.parent is Some((parent, _, _)) {
      parents[parent.to_int()] = parent
    }
  }
  for _, parent in parents {
    let siblings : Array[Effect] = []
    for _, effect in tree.running {
      if effect is ExecuteTool(payload~, ..) &&
        payload.parent is Some((p, _, _)) &&
        p == parent {
        siblings.push(effect)
      }
    }
    for _, effect in tree.waiting {
      if effect is ExecuteTool(payload~, ..) &&
        payload.parent is Some((p, _, _)) &&
        p == parent {
        siblings.push(effect)
      }
    }
    let first = scheduled_tool_effect_waves(
        siblings,
        context.catalog,
        state.catalog_version(),
      )[0]
    let ready = first.filter(effect => {
      tree.waiting.contains(effect.effect_id().to_int())
    })
    if ready.is_empty() {
      continue
    }
    let calls : Array[ToolCall] = []
    let mut model_step : @kernel_exec.ModelStepId? = None
    for effect in ready {
      guard effect is ExecuteTool(payload~, ..) else {
        abort("scheduled non-tool child")
      }
      calls.push({
        call_id: payload.call_id,
        name: payload.tool_name,
        arguments: payload.arguments,
      })
      model_step = Some(payload.model_step_id)
    }
    self.commit_boundary(
      state,
      ToolCommitted,
      [ToolWaveStarted(model_step_id=model_step.unwrap(), calls~)],
      dispatcher,
      context.run_id,
      turn_id,
      context.session_id,
      "sp_child_wave_" + ready[0].effect_id().to_int().to_string(),
    )
    // The journal may suspend. A parent which returned meanwhile must not
    // start its child, even if the child was already admitted and approved.
    guard tree.scopes.get(parent.to_int()) is Some({ val: true, }) else {
      raise EffectExecutionFailed(
        phase="child scheduling",
        cause="parent returned before joining its child",
      )
    }
    for effect in ready {
      let id = effect.effect_id().to_int()
      tree.waiting.remove(id)
      tree.running[id] = effect
      tree.launch(group, effect, context, self.config.tool_call_owners)
    }
  }
}
