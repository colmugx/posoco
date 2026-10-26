///|
/// Child requests enter the same RunState as their parent. Effects remain plain
/// data; no provider, callback, queue or permission hook lives here.
pub fn declare_tool_child(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  parent_id : EffectId,
  name : @kernel.ToolName,
  arguments : Json,
  allowed_owners : Array[String],
  max_depth : Int32?,
  bound_names : Array[String],
) -> (ReduceOutput, Effect, @kernel.ToolOutcome?) raise KernelError {
  let parent = find_tool_effect(state.pending_effects(), parent_id)
  guard parent is Some(parent) else {
    raise constructor_illegal_phase(
      "AwaitingTools", "child parent is not pending",
    )
  }
  let (root_id, depth) = match parent.parent {
    None => (parent_id, 1)
    Some((_, root, parent_depth)) => (root, parent_depth + 1)
  }
  let effect_id = state.next_effect_id()
  let call : @kernel.ToolCall = {
    call_id: child_call_id(state, effect_id),
    name,
    arguments,
  }
  let owner = match catalog.find(name) {
    Some(entry) => entry.definition.owner
    None => parent.owner
  }
  let payload : ExecuteToolPayload = {
    model_step_id: parent.model_step_id,
    call_id: call.call_id,
    tool_name: name,
    arguments,
    owner,
    catalog_version: catalog.version(),
    parent: Some((parent_id, root_id, depth)),
  }
  let effect = ExecuteTool(effect_id~, payload~)
  let mut rejection = validate_tool_child(
    catalog, parent, call, allowed_owners, bound_names,
  )
  if rejection is None {
    if max_depth is Some(limit) && depth > limit {
      rejection = Some(
        NotExecuted(reason=InvocationLimit, original_call_id=call.call_id),
      )
    } else if state.budget().max_tool_calls is Some(limit) &&
      state.budget_consumed().tool_calls >= limit {
      rejection = Some(
        NotExecuted(reason=InvocationLimit, original_call_id=call.call_id),
      )
    }
  }
  let consumed = if rejection is None {
    {
      ..state.budget_consumed(),
      tool_calls: state.budget_consumed().tool_calls + 1,
    }
  } else {
    state.budget_consumed()
  }
  let events : Array[KernelEvent] = [
    ToolChildDeclared(
      effect_id~,
      parent_effect_id=parent_id,
      root_effect_id=root_id,
      depth~,
      call~,
    ),
    ToolBatchStarted(model_step_id=parent.model_step_id, calls=[call]),
  ]
  let pending = state.pending_effects()
  pending.push(effect)
  let next = state.transition(
    phase=AwaitingTools,
    transcript=state.transcript(),
    pending_effects=pending,
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=effect_id.next(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=consumed,
    outcome=None,
    suspension_requirement=None,
  )
  (
    reduce_output(next, if rejection is None { [effect] } else { [] }, events),
    effect,
    rejection,
  )
}

///|
pub fn validate_tool_child(
  catalog : ToolCatalogSnapshot,
  parent : ExecuteToolPayload,
  call : @kernel.ToolCall,
  allowed_owners : Array[String],
  bound_names : Array[String],
) -> @kernel.ToolOutcome? {
  if classify_rejected_outcome(catalog, call, direct=false) is Some(rejected) {
    return Some(rejected)
  }
  let target = catalog.find(call.name).unwrap().definition
  let reason : @kernel.NotExecutedReason? = if !allowed_owners.contains(
      target.owner.to_string(),
    ) {
    Some(OwnerNotAllowed)
  } else if !bound_names.contains(call.name.to_string()) {
    Some(UnsupportedInvocation)
  } else {
    let caller_policy = catalog.find(parent.tool_name).unwrap().definition.policy
    match (caller_policy, target.policy) {
      (Parallel, Sequential | Exclusive) | (Sequential, Exclusive) =>
        Some(PolicyConflict)
      _ => None
    }
  }
  reason.map(reason => NotExecuted(reason~, original_call_id=call.call_id))
}

///|
/// Model call ids are untrusted strings, so a generated spelling is not a
/// reserved namespace. Avoid both the transcript's root ids and pending ids.
fn child_call_id(state : RunState, effect_id : EffectId) -> @kernel.CallId {
  let used : Map[String, Bool] = Map::from_array([])
  for message in state.transcript().messages_snapshot() {
    if message is AssistantMessage(tool_calls~, ..) {
      for call in tool_calls {
        used[call.call_id.to_string()] = true
      }
    }
  }
  for effect in state.pending_effects() {
    if effect is ExecuteTool(payload~, ..) {
      used[payload.call_id.to_string()] = true
    }
  }
  let mut name = state.run_id().to_string() +
    ":child:" +
    effect_id.to_int().to_string()
  while used.contains(name) {
    name += ":"
  }
  @kernel.CallId::unchecked(name)
}

///|
pub fn find_tool_effect(
  effects : Array[Effect],
  id : EffectId,
) -> ExecuteToolPayload? {
  for effect in effects {
    if effect is ExecuteTool(effect_id~, payload~) && effect_id == id {
      return Some(payload)
    }
  }
  None
}
