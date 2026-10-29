///|
/// Runtime-only shadow of the core transcript facts.
///
/// This is deliberately separate from `CoreVersionStore`: the store is the
/// immutable version model, while this struct owns the per-operation state,
/// source capture, and duplicate-boundary bookkeeping. Nothing here feeds
/// `load_session_for_operation`. A committed boundary is captured
/// synchronously from the Puppet after the journal barrier; `Tracking` alone
/// never means a complete readable transcript.
priv struct CoreSourceCapture {
  session_id : String
  /// Deep snapshot of the exact source the model consumer receives.
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]
  /// Fork's trimmed prefix; full length for NewThread compact.
  prefix : Int32
}

///|
priv struct CoreCommit {
  run_id : String
  revision : Int32
  savepoint_id : String
}

///|
priv enum CoreShadowState {
  /// The current operation may accept committed boundaries and capture a
  /// source. It is not a completion claim.
  Tracking(run_id~ : String)
  /// A full terminal transcript or child provenance is recorded.
  Complete
  /// Untracked/incomplete. Never used as a source or terminal replacement.
  Stopped(run_id~ : String, reason~ : String)
  /// A child sid is known but its source edge could not be recorded; later
  /// loads must not silently hydrate it as an unknown root.
  MissingProvenance
}

///|
priv struct CoreShadowRecording {
  store : CoreVersionStore
  state : Map[String, CoreShadowState]
  /// Metadata captured at admission; committed boundaries do not change it.
  metadata : Map[String, Map[String, Json]]
  /// Last committed boundary per session, for duplicate suppression and
  /// terminal metadata updates.
  last_commit : Map[String, CoreCommit]
  /// Frozen safe-point source keyed by run id.
  pending_source : Map[String, CoreSourceCapture]
  /// Synchronous-boundary failures waiting for the Agent diagnostic path.
  pending_errors : Array[String]
}

///|
fn CoreShadowRecording::CoreShadowRecording() -> CoreShadowRecording {
  {
    store: CoreVersionStore::CoreVersionStore(),
    state: Map::from_array([]),
    metadata: Map::from_array([]),
    last_commit: Map::from_array([]),
    pending_source: Map::from_array([]),
    pending_errors: [],
  }
}

///|
/// Record the first loaded view of a session as version 0. An existing sid is
/// never overwritten. A known child with lost provenance is refused instead of
/// being silently re-rooted.
fn CoreShadowRecording::hydrate(
  self : CoreShadowRecording,
  session_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Result[Unit, String] {
  match self.state.get(session_id) {
    Some(MissingProvenance) =>
      return Err("known child missing provenance; refusing root hydration")
    _ => ()
  }
  if self.store.sessions.contains(session_id) {
    return Ok(())
  }
  let recorded : Result[Int32, CoreVersionError] = Ok(
    self.store.record_full(session_id, messages, metadata),
  ) catch {
    error => Err(error)
  }
  match recorded {
    Ok(_) => Ok(())
    Err(error) => Err("hydrate failed: " + core_shadow_error_label(error))
  }
}

///|
/// Arm shadow tracking after admission has decided the operation baseline and
/// confirmed the core still matches the loaded view. No core fact is written
/// here: facts are recorded only from a journal-committed boundary.
fn CoreShadowRecording::admit(
  self : CoreShadowRecording,
  session_id : String,
  _baseline : Array[@kernel.Message],
  metadata : Map[String, Json],
  loaded : Array[@kernel.Message],
  run_id : String,
) -> Result[Unit, String] {
  match self.state.get(session_id) {
    Some(MissingProvenance) =>
      return Err("known child missing provenance; shadow tracking disabled")
    _ => ()
  }
  self.state[session_id] = Stopped(run_id~, reason="admission_pending")
  self.last_commit.remove(session_id)
  self.pending_source.remove(run_id)
  let current : Result[CoreCurrent, CoreVersionError] = Ok(
    self.store.current(session_id),
  ) catch {
    error => Err(error)
  }
  match current {
    Err(UnknownSession(..)) => {
      self.accept(session_id, metadata, run_id)
      Ok(())
    }
    Err(error) => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="admission_current_failed",
      )
      Err("admission current failed: " + core_shadow_error_label(error))
    }
    Ok(current) =>
      if !core_shadow_messages_equal(current.session.messages, loaded) {
        self.state[session_id] = Stopped(run_id~, reason="admission_conflict")
        Err(
          "core current does not match the loaded session; shadow tracking stopped for this operation",
        )
      } else {
        self.accept(session_id, metadata, run_id)
        Ok(())
      }
  }
}

///|
fn CoreShadowRecording::accept(
  self : CoreShadowRecording,
  session_id : String,
  metadata : Map[String, Json],
  run_id : String,
) -> Unit {
  self.metadata[session_id] = snapshot_metadata(metadata)
  self.state[session_id] = Tracking(run_id~)
}

///|
fn CoreShadowRecording::stop(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
  reason : String,
) -> Unit {
  match self.state.get(session_id) {
    Some(MissingProvenance) => ()
    Some(Stopped(run_id=state_run, reason=state_reason)) if state_run == run_id =>
      self.state[session_id] = Stopped(run_id~, reason=state_reason)
    _ => self.state[session_id] = Stopped(run_id~, reason~)
  }
  self.pending_source.remove(run_id)
}

///|
/// Demote an unfinished run to `Stopped`; `Complete` and `MissingProvenance`
/// survive, and a different run's state is left alone.
fn CoreShadowRecording::finish_run(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
  reason : String,
) -> Unit {
  match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id =>
      self.state[session_id] = Stopped(run_id~, reason~)
    _ => ()
  }
  self.pending_source.remove(run_id)
}

///|
fn CoreShadowRecording::mark_complete(
  self : CoreShadowRecording,
  session_id : String,
) -> Unit {
  self.state[session_id] = Complete
}

///|
/// Remember that a child sid's source edge could not be recorded. Only a child
/// with no core body is marked: an existing core body already has its own
/// provenance.
fn CoreShadowRecording::mark_missing_provenance(
  self : CoreShadowRecording,
  session_id : String,
) -> Unit {
  if !self.store.sessions.contains(session_id) {
    self.state[session_id] = MissingProvenance
  }
}

///|
fn CoreShadowRecording::is_tracked(
  self : CoreShadowRecording,
  session_id : String,
) -> Bool {
  match self.state.get(session_id) {
    Some(Tracking(..)) => true
    _ => false
  }
}

///|
fn CoreShadowRecording::take_errors(
  self : CoreShadowRecording,
) -> Array[String] {
  let errors = self.pending_errors.copy()
  self.pending_errors.clear()
  errors
}

///|
/// Freeze the exact source the model consumer receives. No permanent source
/// snapshot is allocated here: Replace, model failure, cancellation, and
/// unrelated paths must leave no orphan snapshot.
fn CoreShadowRecording::capture_source(
  self : CoreShadowRecording,
  run_id : String,
  session_id : String,
  messages : Array[@kernel.Message],
  prefix : Int32,
) -> Unit {
  self.pending_source.remove(run_id)
  if !self.is_tracked(session_id) {
    return
  }
  match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id => ()
    _ => return
  }
  let metadata = match self.metadata.get(session_id) {
    Some(value) => value
    None => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="source_missing_admission_metadata",
      )
      self.pending_errors.push(
        "source capture failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", missing admission metadata",
      )
      return
    }
  }
  self.pending_source[run_id] = {
    session_id,
    messages: snapshot_messages(messages),
    metadata: snapshot_metadata(metadata),
    prefix,
  }
}

///|
/// Create the child core version from the frozen safe-point capture.
fn CoreShadowRecording::record_new_thread(
  self : CoreShadowRecording,
  run_id : String,
  parent_session_id : String,
  child_session_id : String,
  child_messages : Array[@kernel.Message],
  child_metadata : Map[String, Json],
) -> Result[Unit, String] {
  let capture = match self.pending_source.get(run_id) {
    Some(value) => value
    None => return Err("no frozen source capture for this run")
  }
  self.pending_source.remove(run_id)
  if capture.session_id != parent_session_id {
    return Err("frozen source session does not match the parent")
  }
  match self.state.get(parent_session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id => ()
    _ => return Err("parent shadow tracking is not active for this run")
  }
  let mut allocated_snapshot : Int32? = None
  let source_result : Result[CoreSource, CoreVersionError] = Ok(
    match self.store.current(parent_session_id) {
      current if core_shadow_messages_equal(
          current.session.messages,
          capture.messages,
        ) =>
        {
          sid: parent_session_id,
          version: current.version,
          prefix: capture.prefix,
        }
      _ => {
        let version = self.store.record_source_snapshot(
          parent_session_id,
          capture.messages,
          capture.metadata,
        )
        allocated_snapshot = Some(version)
        { sid: parent_session_id, version, prefix: capture.prefix, }
      }
    },
  ) catch {
    error => Err(error)
  }
  let source = match source_result {
    Ok(value) => value
    Err(error) => {
      self.state[parent_session_id] = Stopped(
        run_id~,
        reason="child_source_snapshot_failed",
      )
      return Err(
        "child source snapshot failed: run=" +
        safe_error_label(run_id) +
        ", parent=" +
        safe_error_label(parent_session_id) +
        ", " +
        core_shadow_error_label(error),
      )
    }
  }
  let validated : Result[@types.Session, CoreVersionError] = Ok(
    self.store.resolve_source(source),
  ) catch {
    error => Err(error)
  }
  match validated {
    Ok(_) => ()
    Err(error) => {
      self.revoke_source_snapshot(parent_session_id, allocated_snapshot)
      return Err(
        "frozen source invalid: run=" +
        safe_error_label(run_id) +
        ", parent=" +
        safe_error_label(parent_session_id) +
        ", " +
        core_shadow_error_label(error),
      )
    }
  }
  let recorded : Result[Int32, CoreVersionError] = Ok(
    self.store.record_derived_content(
      child_session_id, source, child_messages, child_metadata,
    ),
  ) catch {
    error => Err(error)
  }
  match recorded {
    Ok(_) => {
      self.mark_complete(child_session_id)
      Ok(())
    }
    Err(error) => {
      self.revoke_source_snapshot(parent_session_id, allocated_snapshot)
      Err("child provenance record failed: " + core_shadow_error_label(error))
    }
  }
}

///|
fn CoreShadowRecording::revoke_source_snapshot(
  self : CoreShadowRecording,
  session_id : String,
  version : Int32?,
) -> Unit {
  match version {
    Some(value) => self.store.remove_source_snapshot(session_id, value)
    None => ()
  }
}

///|
/// Record one journal-committed boundary from the full RunState transcript.
/// Called synchronously after the journal barrier and before dispatch.
fn CoreShadowRecording::record_boundary(
  self : CoreShadowRecording,
  run_id : String,
  session_id : String,
  committed_revision : Int32,
  savepoint_id : String,
  is_terminal : Bool,
  messages : Array[@kernel.Message],
) -> Unit {
  match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id => ()
    _ => return
  }
  match self.last_commit.get(session_id) {
    Some(commit) if commit.run_id == run_id &&
      commit.revision == committed_revision &&
      commit.savepoint_id == savepoint_id => return
    _ => ()
  }
  let metadata = match self.metadata.get(session_id) {
    Some(value) => value
    None => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="missing_admission_metadata",
      )
      self.pending_errors.push(
        "boundary record failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", missing admission metadata",
      )
      return
    }
  }
  if !self.store.sessions.contains(session_id) {
    let recorded : Result[Int32, CoreVersionError] = Ok(
      self.store.record_full(session_id, messages, metadata),
    ) catch {
      error => Err(error)
    }
    match recorded {
      Ok(_) => {
        self.last_commit[session_id] = {
          run_id,
          revision: committed_revision,
          savepoint_id,
        }
        if is_terminal {
          self.state[session_id] = Complete
        }
      }
      Err(error) => {
        self.state[session_id] = Stopped(
          run_id~,
          reason="boundary_record_failed",
        )
        self.pending_errors.push(
          "boundary record failed: run=" +
          safe_error_label(run_id) +
          ", session=" +
          safe_error_label(session_id) +
          ", " +
          core_shadow_error_label(error),
        )
      }
    }
    return
  }
  let current : Result[CoreCurrent, CoreVersionError] = Ok(
    self.store.current(session_id),
  ) catch {
    error => Err(error)
  }
  let current = match current {
    Ok(value) => value
    Err(error) => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="boundary_current_failed",
      )
      self.pending_errors.push(
        "boundary record failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", " +
        core_shadow_error_label(error),
      )
      return
    }
  }
  if core_shadow_messages_equal(current.session.messages, messages) {
    self.last_commit[session_id] = {
      run_id,
      revision: committed_revision,
      savepoint_id,
    }
    if is_terminal {
      self.state[session_id] = Complete
    }
    return
  }
  let recorded : Result[Int32, CoreVersionError] = Ok(
    if core_shadow_messages_is_prefix(current.session.messages, messages) {
      let tail = messages[current.session.messages.length():].to_owned()
      self.store.append(session_id, tail, metadata)
    } else {
      self.store.rewrite(session_id, messages, metadata)
    },
  ) catch {
    error => Err(error)
  }
  match recorded {
    Ok(_) => {
      self.last_commit[session_id] = {
        run_id,
        revision: committed_revision,
        savepoint_id,
      }
      if is_terminal {
        self.state[session_id] = Complete
      }
    }
    Err(error) => {
      self.state[session_id] = Stopped(run_id~, reason="boundary_record_failed")
      self.pending_errors.push(
        "boundary record failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", " +
        core_shadow_error_label(error),
      )
    }
  }
}

///|
/// Update metadata for the terminal transcript already recorded by the
/// boundary sink. Only a same-run Tracking or a Complete whose last commit is
/// this run is eligible; conflict/stopped/missing never recover.
fn CoreShadowRecording::record_terminal(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Result[Unit, String] {
  let eligible = match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) =>
      if state_run == run_id {
        true
      } else {
        return Err("terminal run does not match the current shadow run")
      }
    Some(Complete) =>
      match self.last_commit.get(session_id) {
        Some(commit) =>
          if commit.run_id == run_id {
            true
          } else {
            return Err("terminal run does not match the last committed run")
          }
        None => false
      }
    _ => false
  }
  if !eligible {
    return Ok(())
  }
  let current : Result[CoreCurrent, CoreVersionError] = Ok(
    self.store.current(session_id),
  ) catch {
    error => Err(error)
  }
  let current = match current {
    Ok(value) => value
    Err(error) =>
      return Err(
        "terminal current failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", " +
        core_shadow_error_label(error),
      )
  }
  if !core_shadow_messages_equal(current.session.messages, messages) {
    self.state[session_id] = Stopped(run_id~, reason="terminal_body_mismatch")
    return Err(
      "terminal body does not match the committed core: run=" +
      safe_error_label(run_id) +
      ", session=" +
      safe_error_label(session_id),
    )
  }
  let updated : Result[Int32, CoreVersionError] = Ok(
    self.store.append(session_id, [], metadata),
  ) catch {
    error => Err(error)
  }
  match updated {
    Ok(_) => {
      self.mark_complete(session_id)
      Ok(())
    }
    Err(error) => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="terminal_metadata_failed",
      )
      Err(
        "terminal metadata update failed: run=" +
        safe_error_label(run_id) +
        ", session=" +
        safe_error_label(session_id) +
        ", " +
        core_shadow_error_label(error),
      )
    }
  }
}

///|
fn core_shadow_messages_equal(
  left : Array[@kernel.Message],
  right : Array[@kernel.Message],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    if left[i] != right[i] {
      return false
    }
  }
  true
}

///|
fn core_shadow_messages_is_prefix(
  prefix : Array[@kernel.Message],
  full : Array[@kernel.Message],
) -> Bool {
  if prefix.length() > full.length() {
    return false
  }
  for i in 0..<prefix.length() {
    if prefix[i] != full[i] {
      return false
    }
  }
  true
}

///|
fn core_shadow_error_label(error : CoreVersionError) -> String {
  match error {
    UnknownSession(sid~) => "UnknownSession(sid=" + safe_error_label(sid) + ")"
    SessionExists(sid~) => "SessionExists(sid=" + safe_error_label(sid) + ")"
    UnknownVersion(sid~, version~) =>
      "UnknownVersion(sid=" +
      safe_error_label(sid) +
      ", version=" +
      version.to_string() +
      ")"
    PrefixOutOfRange(sid~, version~, prefix~, available~) =>
      "PrefixOutOfRange(sid=" +
      safe_error_label(sid) +
      ", version=" +
      version.to_string() +
      ", prefix=" +
      prefix.to_string() +
      ", available=" +
      available.to_string() +
      ")"
  }
}
