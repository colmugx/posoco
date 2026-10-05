///|
/// Wakeup input cutoff (port §4). An ordinary turn arms one cutoff keyed by
/// its unique run id — never by session alone — capturing the session's
/// latest requirement generation immediately before the task-outcome peek
/// and the async memory injection. The arm commits only on the run's
/// committed `RunStarted` — the point where `before_model` hooks succeeded
/// and the initial real input is durable — and carries the arming turn's
/// actual root operation id for event correlation. Replay-resumes never
/// arm. A run that never starts (hook abort, defect, raw cancellation)
/// clears its arm on unwind; the key match makes that cleanup unable to
/// remove another turn's arm.

///|
priv struct WakeupCutoffArm {
  key : String
  session : String
  /// Latest requirement generation captured for `session` at arm time.
  cutoff : Int
  /// Actual root operation id of the arming turn, captured at arm time.
  operation_id : String
}

///|
/// Arm the input cutoff for one ordinary input. Called synchronously
/// before the snapshot reads pending outcomes and runs async memory.
fn AgentWakeupRuntime::arm_cutoff(
  self : AgentWakeupRuntime,
  key : String,
  session : String,
  operation_id : String,
) -> Unit {
  let cutoff = match self.generations.get(session) {
    Some(value) => value
    None => 0
  }
  self.cutoff_arm = Some({ key, session, cutoff, operation_id, })
}

///|
/// Drop the arm owned by `key`. A turn clears only its own arm: an armed
/// key that no longer matches — already committed, or owned by a later
/// turn — is left untouched.
fn AgentWakeupRuntime::disarm_cutoff(
  self : AgentWakeupRuntime,
  key : String,
) -> Unit {
  match self.cutoff_arm {
    Some(arm) if arm.key == key => self.cutoff_arm = None
    _ => ()
  }
}

///|
/// Commit the armed cutoff when the Puppet reports `RunStarted` committed
/// for the armed run: before_model succeeded and the initial real input
/// entered the transcript. Pending entries at or before the captured
/// generation are satisfied with the arm's actual root operation id;
/// the arm is consumed either way it matches.
fn AgentWakeupRuntime::commit_cutoff(
  self : AgentWakeupRuntime,
  key : String,
  session : String,
) -> Unit {
  match self.cutoff_arm {
    Some(arm) if arm.key == key && arm.session == session => {
      self.cutoff_arm = None
      self.satisfy_covered(session, arm.cutoff, arm.operation_id)
    }
    _ => ()
  }
}

///|
/// Agent-private Puppet subscriber that commits the armed cutoff on the
/// arming run's committed `RunStarted`. Registered at composition, before
/// any turn can arm.
priv struct WakeupCutoffSubscriber {
  runtime : AgentWakeupRuntime
}

///|
fn WakeupCutoffSubscriber::WakeupCutoffSubscriber(
  runtime : AgentWakeupRuntime,
) -> WakeupCutoffSubscriber {
  { runtime, }
}

///|
impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn subscriber_id(
  _self : WakeupCutoffSubscriber,
) -> String {
  "agent_wakeup_cutoff"
}

///|
impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn provenance(
  _self : WakeupCutoffSubscriber,
) -> String {
  "posoco.agent.wakeup"
}

///|
impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn on_event(
  self : WakeupCutoffSubscriber,
  envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  match envelope.event() {
    RunStarted(..) =>
      self.runtime.commit_cutoff(
        envelope.run_id().to_string(),
        envelope.session_id().to_string(),
      )
    _ => ()
  }
}
