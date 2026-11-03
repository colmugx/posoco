///|
/// One ordinary turn's armed input cutoff, keyed by its unique run id so
/// commit and unwind can never touch another turn's arm.
priv struct WakeupCutoffArm {
  key : String
  session : String
  /// Latest requirement generation captured at arm time.
  cutoff : Int32
  /// Actual root operation id of the arming turn.
  operation_id : String
}

///|
/// Arm the input cutoff before the snapshot reads pending outcomes and runs
/// async memory, so requests arriving later form a newer generation.
pub fn WakeupRuntime::arm_cutoff(
  self : WakeupRuntime,
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
/// A turn clears only its own arm; a mismatched key is already committed or
/// owned by a later turn.
pub fn WakeupRuntime::disarm_cutoff(self : WakeupRuntime, key : String) -> Unit {
  match self.cutoff_arm {
    Some(arm) if arm.key == key => self.cutoff_arm = None
    _ => ()
  }
}

///|
/// Commit when the armed run's `RunStarted` is committed: `before_model`
/// succeeded and the initial real input is durable.
fn WakeupRuntime::commit_cutoff(
  self : WakeupRuntime,
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
/// arming run's committed `RunStarted`.
pub struct WakeupCutoffSubscriber {
  priv runtime : WakeupRuntime
}

///|
pub fn WakeupCutoffSubscriber::WakeupCutoffSubscriber(
  runtime : WakeupRuntime,
) -> WakeupCutoffSubscriber {
  { runtime, }
}

///|
pub extend WakeupCutoffSubscriber with @puppetry.EventSubscriber::{
  on_event,
  provenance,
  subscriber_id,
}

///|
pub impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn subscriber_id(
  _self : WakeupCutoffSubscriber,
) -> String {
  "agent_wakeup_cutoff"
}

///|
pub impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn provenance(
  _self : WakeupCutoffSubscriber,
) -> String {
  "posoco.agent.wakeup"
}

///|
pub impl @puppetry.EventSubscriber for WakeupCutoffSubscriber with fn on_event(
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
