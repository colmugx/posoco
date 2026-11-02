///|
/// Pending Replace body outputs that were committed to the core fact but whose
/// full-store projection has not been confirmed yet. The map is private; only
/// the staged snapshot and retry lifecycle cross the package boundary.
pub struct SessionOutput {
  priv body_recovery : Map[String, @types.Session]
  priv pending_new_thread : Map[String, NewThreadOutput]
}

///|
/// Immutable callback view of one core-confirmed NewThread output. The module
/// still owns the authoritative pending snapshot; callbacks receive a deep copy.
pub struct NewThreadOutput {
  scope : @types.EventScope
  parent_session_id : String
  child_session_id : String
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]
  save_label : String
}

///|
fn NewThreadOutput::snapshot(self : NewThreadOutput) -> NewThreadOutput {
  {
    scope: self.scope,
    parent_session_id: self.parent_session_id,
    child_session_id: self.child_session_id,
    messages: @message_snapshot.snapshot_messages(self.messages),
    metadata: @message_snapshot.snapshot_metadata(self.metadata),
    save_label: self.save_label,
  }
}

///|
pub fn SessionOutput::SessionOutput() -> SessionOutput {
  {
    body_recovery: Map::from_array([]),
    pending_new_thread: Map::from_array([]),
  }
}

///|
/// Stage a committed Replace body before any store await. Deep snapshots keep
/// the pending output independent of caller-owned message/metadata arrays.
pub fn SessionOutput::stage_body(
  self : SessionOutput,
  session_id : String,
  session : @types.Session,
) -> Unit {
  self.body_recovery[session_id] = {
    messages: @message_snapshot.snapshot_messages(session.messages),
    metadata: @message_snapshot.snapshot_metadata(session.metadata),
  }
}

///|
/// Retry the affected session's pending body through the supplied all-store
/// save. The pending snapshot is removed only after `save` returns success; a
/// failure keeps it for the next operation.
pub async fn SessionOutput::recover_body(
  self : SessionOutput,
  session_id : String,
  save : async (@types.Session) -> Unit raise @error.AgentError,
) -> Unit raise @error.AgentError {
  let pending = match self.body_recovery.get(session_id) {
    Some(value) => value
    None => return
  }
  save({
    messages: @message_snapshot.snapshot_messages(pending.messages),
    metadata: @message_snapshot.snapshot_metadata(pending.metadata),
  })
  self.body_recovery.remove(session_id)
}

///|
pub fn SessionOutput::stage_new_thread(
  self : SessionOutput,
  scope : @types.EventScope,
  parent_session_id : String,
  child_session_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
  save_label : String,
) -> Unit {
  self.pending_new_thread[child_session_id] = {
    scope,
    parent_session_id,
    child_session_id,
    messages: @message_snapshot.snapshot_messages(messages),
    metadata: @message_snapshot.snapshot_metadata(metadata),
    save_label,
  }
}

///|
/// Execute one core-confirmed NewThread output. The callback receives an
/// isolated snapshot; the authoritative pending record is removed only after
/// the callback returns success.
pub async fn SessionOutput::execute_new_thread(
  self : SessionOutput,
  child_session_id : String,
  save : async (NewThreadOutput) -> Unit raise @error.AgentError,
) -> Unit raise @error.AgentError {
  let pending = match self.pending_new_thread.get(child_session_id) {
    Some(value) => value
    None => return
  }
  save(pending.snapshot())
  self.pending_new_thread.remove(child_session_id)
}

///|
/// Retry every core-confirmed NewThread output in deterministic child-id order.
/// Each callback receives an isolated snapshot; a failure keeps the failing
/// record (and all later records) for the next operation.
pub async fn SessionOutput::recover_new_threads(
  self : SessionOutput,
  save : async (NewThreadOutput) -> Unit raise @error.AgentError,
) -> Unit raise @error.AgentError {
  let ids = self.pending_new_thread.keys().to_array()
  ids.sort()
  for child_id in ids {
    self.execute_new_thread(child_id, save)
  }
}
