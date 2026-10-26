///|
priv struct ChildReply {
  ready : @async.CondVar
  mut result : @kernel.InvocationResult?
  mut effect_id : EffectId?
  mut started : Bool
}

///|
fn ChildReply::finish(
  self : ChildReply,
  result : @kernel.InvocationResult,
) -> Unit {
  if self.result is None {
    self.result = Some(result)
    self.ready.broadcast()
  }
}

///|
priv enum ToolTreeMessage {
  Request(EffectId, String, Json, ChildReply)
  Finished(Effect, Result[RunInput, PuppetError])
  Abort
  /// The operation's captured bindings gained hard-revoked names.
  Revocations
}

///|
priv struct ToolTree {
  queue : @aqueue.Queue[ToolTreeMessage]
  active : Ref[Bool]
  scopes : Map[Int32, Ref[Bool]]
  replies : Array[ChildReply]
  child_replies : Map[Int32, ChildReply]
  waiting : Map[Int32, Effect]
  running : Map[Int32, Effect]
  executing : Map[Int32, EffectId]
  cancellations : Map[Int32, CancelDisposition]
  mut cleanup_error : String?
}

///|
fn ToolTree::close(self : ToolTree) -> Unit {
  self.active.val = false
  for reply in self.replies {
    reply.finish(
      Interrupted(
        reason="tool execution scope ended",
        cancellation=if reply.started {
          match reply.effect_id {
            Some(id) =>
              self.cancellations.get(id.to_int()).unwrap_or(NotPropagated)
            None => NotPropagated
          }
        } else {
          AlreadySettled
        },
        side_effects_possible=reply.started,
      ),
    )
  }
}

///|
fn ToolTree::launch(
  self : ToolTree,
  group : @async.TaskGroup[PumpStep],
  effect : Effect,
  context : ExecutionContext,
  owners : Map[String, Array[String]],
) -> Unit {
  guard effect is ExecuteTool(effect_id~, payload~) else {
    abort("tool tree received a non-tool effect")
  }
  self.executing[effect_id.to_int()] = effect_id
  self.running[effect_id.to_int()] = effect
  if self.child_replies.get(effect_id.to_int()) is Some(reply) {
    reply.started = true
  }
  let live = Ref(true)
  self.scopes[effect_id.to_int()] = live
  let allowed = owners.get(payload.owner.to_string()).unwrap_or([]).copy()
  let revoked = fn() {
    match context.revocations {
      Some(facts) => self.is_revoked(effect_id, facts)
      None => false
    }
  }
  let scope : @kernel_exec.ToolExecutionScope = {
    invocation: {
      session_id: context.session_id,
      run_id: context.run_id,
      effect_id: Some(effect_id),
      pressure: None,
    },
    parent_effect_id: payload.parent.map(p => p.0),
    root_effect_id: payload.parent.map(p => p.1).unwrap_or(effect_id),
    active: fn() { self.active.val && live.val },
    before_start: fn() {
      if revoked() {
        if context.launch_gate is Some(gate) {
          gate.record_refusal(
            context.run_id.to_string(),
            effect_id.to_int(),
            Revoked,
          )
        }
        Some(Revoked)
      } else {
        None
      }
    },
    tools: fn() {
      if !self.active.val || !live.val || revoked() {
        return []
      }
      context.catalog
      .definitions()
      .filter(def => {
        !(def.exposure is Disabled) && allowed.contains(def.owner.to_string())
      })
      .map(def => { ..def, input_schema: snapshot_json(def.input_schema), })
    },
    invoke: async fn(name, arguments) {
      if !self.active.val || !live.val || revoked() {
        return Interrupted(
          reason="parent tool has settled or been revoked",
          cancellation=AlreadySettled,
          side_effects_possible=false,
        )
      }
      let reply = ChildReply::{
        ready: @async.CondVar::Cond(),
        result: None,
        effect_id: None,
        started: false,
      }
      self.replies.push(reply)
      self.queue.put(Request(effect_id, name, snapshot_json(arguments), reply))
      while reply.result is None {
        reply.ready.wait()
      }
      reply.result.unwrap()
    },
  }
  let child_context = { ..context, tool_scope: Some(scope), }
  group.spawn_bg(async fn() {
    defer {
      live.val = false
    }
    let attempted : Result[RunInput, PuppetError] = Ok(
      execute_one(effect, child_context, None),
    ) catch {
      error => Err(error)
    }
    live.val = false
    self.queue.put(Finished(effect, attempted))
  })
}

///|
/// Drive one already-scheduled root wave and its children. The pump alone
/// mutates RunState and journals facts. Provider tasks only submit requests
/// and return executor inputs; they never run hooks or choose an executor.
async fn Puppet::execute_tool_tree(
  self : Puppet,
  wave : Array[Effect],
  initial : RunState,
  context : ExecutionContext,
  dispatcher : EventDispatcher,
  turn_id : TurnId,
  snap : TurnSnapshot,
  hook_scope : @types.EventScope,
) -> PumpStep raise PuppetError {
  let tree = ToolTree::{
    queue: @aqueue.Queue(kind=Unbounded),
    active: Ref(true),
    scopes: Map::from_array([]),
    replies: [],
    child_replies: Map::from_array([]),
    waiting: Map::from_array([]),
    running: Map::from_array([]),
    executing: Map::from_array([]),
    cancellations: Map::from_array([]),
    cleanup_error: None,
  }
  defer tree.close()
  let mut state = initial
  let roots : Map[Int32, RunInput] = Map::from_array([])
  let returning = Ref(false)
  let aborted = Ref(false)
  let attempted : Result[PumpStep, PuppetError] = Ok(
    @async.with_task_group(async fn(group) {
      group.add_defer(() => {
        if !returning.val {
          @async.protect_from_cancel(async fn() { tree.cleanup(context) })
        }
      })
      for effect in wave {
        tree.launch(group, effect, context, self.config.tool_call_owners)
      }
      // Cancellation and completions share one FIFO. Racing a destructive
      // queue.get against abort can dequeue and then discard a real completion.
      group.spawn_bg(async fn() {
        await_abort_requested(context.mailbox)
        tree.queue.put(Abort)
      })
      // Hard withdrawal of a captured binding must reach in-flight effects.
      // Only the watcher observes the fact; the tree loop owns cancellation and
      // never fabricates a provider result.
      match context.revocations {
        Some(facts) => {
          let mut seen = facts.generation()
          group.spawn_bg(async fn() {
            while true {
              @async.sleep(effect_abort_poll_ms)
              if facts.generation() != seen {
                seen = facts.generation()
                tree.queue.put(Revocations)
              }
            }
          })
        }
        None => ()
      }
      while roots.length() < wave.length() || !tree.child_replies.is_empty() {
        match tree.queue.get() {
          Abort => {
            returning.val = true
            aborted.val = true
            group.return_immediately(ContinueWith(state))
            return ContinueWith(state)
          }
          Revocations => {
            // The cancellation report is the fact; a raised cleanup failure is
            // preserved as the tree's primary error instead of being dropped.
            let attempted : Result[Unit, PuppetError] = Ok(
              cancel_revoked_effects(tree, context),
            ) catch {
              error => Err(tool_tree_error(error))
            }
            guard attempted is Ok(_) else {
              returning.val = true
              let error = attempted.unwrap_err()
              if tree.cleanup_error is Some(detail) {
                raise ExecutionCleanupFailed(primary=error, detail~)
              }
              raise error
            }
          }
          Request(parent_id, name, arguments, reply) => {
            let parent_live = tree.scopes.get(parent_id.to_int())
            let parent_revoked = match context.revocations {
              Some(facts) => tree.is_revoked(parent_id, facts)
              None => false
            }
            if parent_live is None ||
              !parent_live.unwrap().val ||
              parent_revoked {
              reply.finish(
                Interrupted(
                  reason="parent tool has settled",
                  cancellation=AlreadySettled,
                  side_effects_possible=false,
                ),
              )
              continue
            }
            let parent = @kernel_exec.find_tool_effect(
              state.pending_effects(),
              parent_id,
            ).unwrap()
            let allowed = self.config.tool_call_owners
              .get(parent.owner.to_string())
              .unwrap_or([])
            let (declared, effect, pre_rejection) = @kernel_exec.declare_tool_child(
              state,
              context.catalog,
              parent_id,
              @kernel.ToolName::unchecked(name),
              arguments,
              allowed,
              self.config.max_tool_depth,
              (self.config.bound_tool_names)(),
            ) catch {
              error =>
                raise ReducerInvariantViolation(
                  category=IllegalPhase(
                    phase="child admission",
                    detail=error.to_string(),
                  ),
                )
            }
            state = declared.next_state()
            self.commit_boundary(
              state,
              ToolCommitted,
              declared.events(),
              dispatcher,
              context.run_id,
              turn_id,
              context.session_id,
              "sp_child_declared_" + effect.effect_id().to_int().to_string(),
            )
            guard effect is ExecuteTool(effect_id~, payload~) else {
              abort("child declaration did not produce ExecuteTool")
            }
            reply.effect_id = Some(effect_id)
            let mut call : ToolCall = {
              call_id: payload.call_id,
              name: payload.tool_name,
              arguments: payload.arguments,
            }
            let mut rejection = pre_rejection
            let mut consent_scope : String? = None
            if rejection is None {
              let contenders : Array[async () -> FinalizedToolCall?] = [
                async fn() {
                  Some(
                    finalize_tool_call(
                      context.catalog,
                      self.config.hooks,
                      call,
                      direct=false,
                      revocations?=self.tool_revocations,
                    ),
                  )
                },
                async fn() {
                  await_abort_requested(context.mailbox)
                  None
                },
              ]
              if context.revocations is Some(facts) {
                contenders.push(async fn() {
                  while !tree.is_revoked(parent_id, facts) &&
                        !facts.is_revoked(call.name.to_string()) {
                    @async.sleep(effect_abort_poll_ms)
                  }
                  Some(FinalizedToolCall::{
                    call,
                    consent_scope: None,
                    rejection: Some(
                      @kernel.ToolOutcome::NotExecuted(
                        reason=Revoked,
                        original_call_id=call.call_id,
                      ),
                    ),
                  })
                })
              }
              let finalized = @async.any(contenders)
              guard finalized is Some(finalized) else {
                returning.val = true
                aborted.val = true
                group.return_immediately(ContinueWith(state))
                return ContinueWith(state)
              }
              call = finalized.call
              consent_scope = finalized.consent_scope
              rejection = match finalized.rejection {
                Some(rejected) => Some(rejected)
                None =>
                  @kernel_exec.validate_tool_child(
                    context.catalog,
                    parent,
                    call,
                    allowed,
                    (self.config.bound_tool_names)(),
                  )
              }
            }
            let owner = context.catalog
              .find(call.name)
              .map(e => e.definition.owner)
              .unwrap_or(payload.owner)
            let final_effect : Effect = ExecuteTool(effect_id~, payload={
              ..payload,
              tool_name: call.name,
              arguments: snapshot_json(call.arguments),
              owner,
            })
            let pending = state
              .pending_effects()
              .map(e => {
                if e.effect_id() == effect_id {
                  final_effect
                } else {
                  e
                }
              })
            state = state.transition(
              phase=AwaitingTools,
              transcript=state.transcript(),
              pending_effects=pending,
              next_event_sequence=state.next_event_sequence(),
              next_effect_id=state.next_effect_id(),
              current_model_step_id=state.current_model_step_id(),
              catalog_version=None,
              budget_consumed=state.budget_consumed(),
              outcome=None,
              suspension_requirement=None,
            ) catch {
              error =>
                raise ReducerInvariantViolation(
                  category=IllegalPhase(
                    phase="child finalization",
                    detail=error.to_string(),
                  ),
                )
            }
            if rejection is Some(outcome) {
              state = self.complete_child(
                state, effect_id, call, outcome, dispatcher, turn_id, context, hook_scope,
              )
              reply.finish(Completed(outcome))
            } else {
              if !parent_live.unwrap().val {
                raise EffectExecutionFailed(
                  phase="child admission",
                  cause="parent returned before joining its child",
                )
              }
              self.commit_boundary(
                state,
                ToolCommitted,
                [
                  ToolCallApproved(
                    model_step_id=payload.model_step_id,
                    call~,
                    consent_scope~,
                  ),
                ],
                dispatcher,
                context.run_id,
                turn_id,
                context.session_id,
                "sp_child_approved_" + effect_id.to_int().to_string(),
              )
              tree.child_replies[effect_id.to_int()] = reply
              tree.waiting[effect_id.to_int()] = final_effect
            }
          }
          Finished(effect, attempted) => {
            let input = match attempted {
              Ok(input) => input
              Err(error) => raise error
            }
            guard effect is ExecuteTool(effect_id~, payload~) else {
              abort("non-tool completion")
            }
            tree.executing.remove(effect_id.to_int())
            // A later journal failure cannot undo the executor's return.
            tree.cancellations[effect_id.to_int()] = AlreadySettled
            if state
              .pending_effects()
              .any(e => {
                e is ExecuteTool(payload=p, ..) &&
                p.parent is Some((parent_id, _, _)) &&
                parent_id == effect_id
              }) {
              raise EffectExecutionFailed(
                phase="tool completion",
                cause="parent returned before joining its child",
              )
            }
            tree.running.remove(effect_id.to_int())
            if payload.parent is None {
              roots[effect_id.to_int()] = input
            } else {
              let output = reduce(state, context.catalog, input) catch {
                error =>
                  raise ReducerInvariantViolation(
                    category=IllegalPhase(
                      phase="child completion",
                      detail=error.to_string(),
                    ),
                  )
              }
              state = output.next_state()
              self.commit_boundary(
                state,
                ToolCommitted,
                output.events(),
                dispatcher,
                context.run_id,
                turn_id,
                context.session_id,
                "sp_child_done_" + effect_id.to_int().to_string(),
              )
              self.fire_post_event_hooks(input, hook_scope)
              if state.phase() == Terminal {
                raise EffectExecutionFailed(
                  phase="child completion",
                  cause="child completion violated run invariants",
                )
              }
              // Return precisely the outcome committed by the reducer, including
              // its runtime failure classification, rather than reconstructing it.
              let mut completed : @kernel.ToolOutcome? = None
              for event in output.events() {
                if event is ToolCompleted(outcome~, ..) {
                  completed = Some(outcome)
                }
              }
              guard completed is Some(outcome) else {
                raise EffectExecutionFailed(
                  phase="child completion",
                  cause="reducer did not settle the child",
                )
              }
              let reply = tree.child_replies[effect_id.to_int()]
              tree.child_replies.remove(effect_id.to_int())
              reply.finish(
                if outcome is NotExecuted(reason=Revoked, ..) {
                  Interrupted(
                    reason="tool version revoked before provider start",
                    cancellation=AlreadySettled,
                    side_effects_possible=false,
                  )
                } else {
                  Completed(outcome)
                },
              )
            }
          }
        }
        self.start_ready_children(
          tree, group, state, context, dispatcher, turn_id,
        )
      }
      for effect in wave {
        let input = roots[effect.effect_id().to_int()]
        match
          self.fold_effect_input(
            state,
            input,
            dispatcher,
            context.run_id,
            turn_id,
            context.session_id,
            "sp_tool_tree_root",
            snap,
          ) {
          Return(result) => {
            returning.val = true
            group.return_immediately(StopWith(result))
            return StopWith(result)
          }
          Continue(next) => state = next
        }
        self.fire_post_event_hooks(input, hook_scope)
      }
      returning.val = true
      group.return_immediately(ContinueWith(state))
      ContinueWith(state)
    }),
  ) catch {
    error => Err(tool_tree_error(error))
  }
  match attempted {
    Err(error) => {
      if tree.cleanup_error is Some(detail) {
        raise ExecutionCleanupFailed(primary=error, detail~)
      }
      raise error
    }
    Ok(step) =>
      if aborted.val {
        self.pump_abort(
          state,
          context,
          dispatcher,
          context.run_id,
          turn_id,
          context.session_id,
          on_cancel=reports => tree.record_cancellations(reports),
        )
      } else {
        step
      }
  }
}

///|
async fn Puppet::complete_child(
  self : Puppet,
  state : RunState,
  id : EffectId,
  call : ToolCall,
  outcome : @kernel.ToolOutcome,
  dispatcher : EventDispatcher,
  turn_id : TurnId,
  context : ExecutionContext,
  hook_scope : @types.EventScope,
) -> RunState raise PuppetError {
  let input : RunInput = ToolCompleted(payload={
    effect_id: id,
    call_id: call.call_id,
    tool_name: call.name,
    arguments: call.arguments,
    outcome,
  })
  let output = reduce(state, context.catalog, input) catch {
    error =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="child rejection", detail=error.to_string()),
      )
  }
  self.commit_boundary(
    output.next_state(),
    ToolCommitted,
    output.events(),
    dispatcher,
    context.run_id,
    turn_id,
    context.session_id,
    "sp_child_rejected_" + id.to_int().to_string(),
  )
  self.fire_post_event_hooks(input, hook_scope)
  output.next_state()
}
