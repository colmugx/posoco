///|

///|
/// Complete input for one prompt on a long-lived Puppet. Composition-static
/// ports and catalog wiring remain in `PuppetConfig`; every value that may
/// differ from one turn to the next travels through this request.
#derive(Eq, Debug)
pub(all) struct PromptRequest {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  initial_messages : Array[Message]
  operation_id : String
  policy : RunPolicy
}

///|
pub extend PromptRequest with Eq::{not_equal, equal}

///|
pub extend PromptRequest with Debug::{to_repr}

///|
/// Result of `prompt`.
pub(all) enum PromptResult {
  /// Run accepted; the puppet has entered Active phase and is driving.
  Accepted(run_id~ : RunId, turn_id~ : TurnId)
  /// Rejected because a lease is already held.
  LeaseBusy(held_by~ : String)
  /// Rejected for another typed reason.
  Rejected(error~ : PuppetError)
  /// Fork completed. The pump consumed a `ForkCommand` at a safe
  /// point, snapshotted the transcript's first `fork_index` messages,
  /// wrote them as a new session (carrying `parent_thread_id` lineage) to
  /// the configured SessionPort if any, and stopped the current turn.
  /// Product code should switch its active thread to `new_session_id`.
  /// `forked_messages` is the new thread's body (deep copy of the parent's
  /// transcript prefix). The original thread is untouched and may continue
  /// accepting turns (copy-on-write semantics).
  ForkCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    parent_session_id~ : String,
    new_session_id~ : String,
    forked_messages~ : Array[@kernel.Message],
  )
  /// Compact completed. The pump consumed a `CompactCommand`
  /// (manual `/compact`) or auto-triggered compact (90% context-window
  /// pressure) and applied the modelport's `CompactResult` to the current
  /// transcript. `mode` reports how the modelport asked posoco to apply
  /// the result:
  /// - **NewThread**: a new session was created with `parent_thread_id`
  ///   lineage. `new_session_id` is `Some(id)`; product code should switch
  ///   its active thread. The original thread is preserved unchanged.
  /// - **Replace**: the current session's message body was replaced with
  ///   the modelport-supplied compacted_messages. `new_session_id` is
  ///   `None`; product code keeps the same active thread. The current turn
  ///   continues with that body.
  CompactCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    mode~ : @kernel.CompactMode,
    trigger~ : @kernel.CompactTrigger,
    new_session_id~ : String?,
    compacted_messages~ : Array[@kernel.Message],
  )
}

///|
pub extend PromptResult with Show::{output}

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
      forked_messages~,
    ) =>
      "ForkCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, parent=\{parent_session_id}, new=\{new_session_id}, msgs=\{forked_messages.length()})"
    CompactCompleted(
      run_id~,
      turn_id~,
      mode~,
      trigger~,
      new_session_id~,
      compacted_messages~,
    ) =>
      "CompactCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, mode=\{mode}, trigger=\{trigger}, new=\{match new_session_id { Some(id) => id; None => "-" }}, msgs=\{compacted_messages.length()})"
  }
}

///|
/// Prompt the Puppet with an initial user message. Only legal when the
/// phase is Idle.
pub async fn Puppet::prompt(
  self : Puppet,
  request : PromptRequest,
) -> PromptResult raise PuppetError {
  let run_id = request.run_id
  let turn_id = request.turn_id
  let session_id = request.session_id
  let (gate_with_lease, _lease) = self.phase_gate.acquire_prompt(
    request.operation_id,
    run_id,
    turn_id,
  ) catch {
    e => return Rejected(error=e)
  }
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
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
  let snap = TurnSnapshot::capture(snap_input) catch {
    // Roll back the lease on snapshot failure.
    e => return self.finalize_rejected(error=e)
  }
  self.mailbox.bind_run(run_id, turn_id)
  self.phase_gate = self.phase_gate.transition(Active)
  let result = self.drive_run(
    run_id,
    turn_id,
    session_id,
    request.initial_messages.copy(),
    snap,
  )
  result
}

///|
/// Wait until the Puppet reaches a quiescent status. Returns Idle,
/// Suspended, Terminal, or Shutdown (typed, distinct). Implemented via
/// `@cond_var.Cond::wait` — NOT polling.
pub async fn Puppet::wait_idle(self : Puppet) -> QuiescentStatus {
  self.mailbox.wait_idle()
}

///|

///|
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
    ModelCompleted(payload~) | ModelCompletedContinue(payload~) =>
      ModelCompleted(completion=payload.completion)
    ModelFailed(payload~) => ModelFailed(failure=payload.failure)
    ToolCompleted(payload~) =>
      ToolCompleted(call=payload.tool_call(), outcome=payload.outcome)
    ToolFailed(payload~) =>
      ToolFailed(call=payload.tool_call(), reason=payload.reason)
    _ => return
  }
  for hook in self.config.hooks {
    hook.on_post_event(Some(scope), stage)
  }
}
