///|
/// Puppet orchestration — the single long-lived pump (ADR §2.1, §4, §6).
///
/// The Puppet is the ONLY loop in the product that drives RunState forward
/// across model/tool rounds. It composes:
/// - PhaseGate — macro-phase gating + lease
/// - TurnSnapshot — immutable turn capture
/// - ControlMailbox — steer/follow-up/resume/abort + idle barrier
/// - RunJournal + SavepointCoordinator — append-only journal
/// - EventDispatcher — post-commit event dispatch
/// - reducer + execute_one — reused unchanged
///
/// The pump NEVER decides termination by inspecting `tool_calls.is_empty()`.
/// It only drives reducer-declared effects. If the reducer declares zero
/// effects and the state is not terminal, the pump stops and waits for
/// external input (prompt/resume).
///
/// Single-writer: only the pump advances journal revision. Only the pump
/// emits envelopes. Only the pump allocates seq.
// ──────────────────────────────────────────────────────────────────────────
// prompt — start a new run
// ──────────────────────────────────────────────────────────────────────────

///|
/// Complete input for one prompt on a long-lived Puppet. Composition-static
/// ports and catalog wiring remain in `PuppetConfig`; every value that may
/// differ from one turn to the next travels through this request.
pub(all) struct PromptRequest {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  initial_messages : Array[Message]
  operation_id : String
  policy : RunPolicy
} derive(Eq, Debug)

///|
/// Result of `prompt`.
pub(all) enum PromptResult {
  /// Run accepted; the puppet has entered Active phase and is driving.
  Accepted(run_id~ : RunId, turn_id~ : TurnId)
  /// Rejected because a lease is already held.
  LeaseBusy(held_by~ : String)
  /// Rejected for another typed reason.
  Rejected(error~ : PuppetError)
  /// M3.5: Fork completed. The pump consumed a `ForkCommand` at a safe
  /// point, snapshotted the transcript's first `fork_index` messages,
  /// wrote them as a new session (carrying `parent_thread_id` lineage) to
  /// the configured SessionStore if any, and stopped the current turn.
  /// Product code should switch its active thread to `new_session_id`.
  /// `forked_messages` is the new thread's body (deep copy of the parent's
  /// transcript prefix). The original thread is untouched and may continue
  /// accepting turns (copy-on-write semantics).
  ForkCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    parent_session_id~ : String,
    new_session_id~ : String,
    forked_messages~ : Array[@kernel.Message]
  )
  /// M3.5: Compact completed. The pump consumed a `CompactCommand`
  /// (manual `/compact`) or auto-triggered compact (90% context-window
  /// pressure) and applied the modelport's `CompactResult` to the current
  /// transcript. `mode` reports how the modelport asked posoco to apply
  /// the result:
  /// - **NewThread**: a new session was created with `parent_thread_id`
  ///   lineage. `new_session_id` is `Some(id)`; product code should switch
  ///   its active thread. The original thread is preserved unchanged.
  /// - **Replace**: the current session's message body was replaced in
  ///   place. `new_session_id` is `None`; product code keeps the same
  ///   active thread. The current turn continues with the compacted body.
  /// - **Append**: the compacted body was appended to the current session.
  ///   `new_session_id` is `None`; product code keeps the same active
  ///   thread. The current turn continues with the appended body.
  CompactCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    mode~ : @kernel.CompactMode,
    trigger~ : @kernel.CompactTrigger,
    new_session_id~ : String?,
    compacted_messages~ : Array[@kernel.Message]
  )
}

///|
pub impl Show for PromptResult with fn to_string(self : PromptResult) -> String {
  match self {
    Accepted(run_id~, turn_id~) =>
      "Accepted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()})"
    LeaseBusy(held_by~) => "LeaseBusy(held_by=\{held_by})"
    Rejected(error~) => "Rejected(\{error.to_string()})"
    ForkCompleted(
      run_id~,
      turn_id~,
      parent_session_id~,
      new_session_id~,
      forked_messages~
    ) =>
      "ForkCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, parent=\{parent_session_id}, new=\{new_session_id}, msgs=\{forked_messages.length()})"
    CompactCompleted(
      run_id~,
      turn_id~,
      mode~,
      trigger~,
      new_session_id~,
      compacted_messages~
    ) =>
      "CompactCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, mode=\{mode}, trigger=\{trigger}, new=\{match new_session_id { Some(id) => id; None => "-" }}, msgs=\{compacted_messages.length()})"
  }
}

///|
/// Prompt the Puppet with an initial user message. Only legal when the
/// phase is Idle.
///
/// Steps (ADR §6.1):
/// 1. Acquire prompt lease via the phase gate.
/// 2. Capture TurnSnapshot.
/// 3. Bind ControlMailbox to the new run/turn.
/// 4. Transition to Active.
/// 5. Let the pump atomically commit the initial boundary (`InputAccepted`,
///    `RunStarted`, and first model intent) before any model effect.
/// 6. Run the pump until terminal or suspended.
/// 7. On terminal, dispatch terminal event, release lease, return.
///
/// `run_id` / `turn_id` are caller-supplied (host generates them; the
/// Puppet does not allocate). This keeps cross-process resume (M5)
/// possible without a central id factory.
pub async fn Puppet::prompt(
  self : Puppet,
  request : PromptRequest,
) -> PromptResult raise PuppetError {
  let run_id = request.run_id
  let turn_id = request.turn_id
  let session_id = request.session_id
  // Step 1: acquire lease.
  let acquire_result : Result[(PhaseGate, OperationLease), PuppetError] = attempt(() => {
      self.phase_gate.acquire_prompt(request.operation_id, run_id, turn_id)
    },
  )
  let (gate_with_lease, _lease) = match acquire_result {
    Err(e) => return Rejected(error=e)
    Ok(pair) => pair
  }
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
  // Step 2: capture snapshot (validation happens here).
  let snap_input : TurnSnapshotInput = {
    run_id,
    turn_id,
    session_id,
    catalog: self.config.catalog,
    policy: request.policy,
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  }
  let snap_result : Result[TurnSnapshot, PuppetError] = attempt(() => {
    TurnSnapshot::capture(snap_input)
  })
  let snap = match snap_result {
    Err(e) => {
      // Roll back the lease on snapshot failure.
      self.phase_gate = PhaseGate::idle()
      self.mailbox.set_quiescent(Idle)
      return Rejected(error=e)
    }
    Ok(s) => s
  }
  // Step 3: bind mailbox.
  self.mailbox.bind_run(run_id, turn_id)
  // Step 4: transition to Active. `drive_run` commits the initial boundary
  // before it can dispatch the first model effect.
  self.phase_gate = self.phase_gate.transition(Active)
  // Step 5: run the pump.
  let result = self.drive_run(
    run_id,
    turn_id,
    session_id,
    request.initial_messages.copy(),
    snap,
  )
  // Step 7: release lease and return.
  result
}

// ──────────────────────────────────────────────────────────────────────────
// wait_idle — delegate to mailbox
// ──────────────────────────────────────────────────────────────────────────

///|
/// Wait until the Puppet reaches a quiescent status. Returns Idle,
/// Suspended, Terminal, or Shutdown (typed, distinct). Implemented via
/// `@cond_var.Cond::wait` — NOT polling.
pub async fn Puppet::wait_idle(self : Puppet) -> QuiescentStatus {
  self.mailbox.wait_idle()
}

// ──────────────────────────────────────────────────────────────────────────
// Post-event hook fire helper
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fire every registered hook's `on_post_event_at` for a completed effect.
/// The `PipelineHook::on_post_event_at` contract is non-raising: handlers cannot fail
/// in a typed way, and a contract violation aborts loudly (aborts are not
/// catchable). Components with fallible internal work must catch it
/// themselves and surface it as a `secondary_failure` observer event —
/// see the Agent's `emit_secondary_failure` wiring. Post-event stages only
/// exist inside a run, so
/// the attribution scope is always delivered as `Some`.

///|
/// Async because `on_post_event_at` is an async slot; the noraise slot
/// contract keeps this helper non-failing.
async fn Puppet::fire_post_event_hooks(
  self : Puppet,
  input : RunInput,
  scope : @types.EventScope,
) -> Unit noraise {
  // Fast path: skip stage translation entirely when no hook could care
  // about post-effect events.
  if self.config.hooks.is_empty() {
    return
  }
  let stage : HookStage = match input {
    ModelCompleted(payload~) =>
      HookStage::ModelCompleted(completion=payload.completion)
    ModelFailed(payload~) => HookStage::ModelFailed(failure=payload.failure)
    ToolCompleted(payload~) =>
      HookStage::ToolCompleted(
        call=ToolCall::{
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        },
        outcome=payload.outcome,
      )
    ToolFailed(payload~) =>
      HookStage::ToolFailed(
        call=ToolCall::{
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        },
        reason=payload.reason,
      )
    _ => return
  }
  for hook in self.config.hooks {
    hook.on_post_event_at(Some(scope), stage)
  }
}
