///|
/// Runtime-only shadow of the core transcript facts.
///
/// This is deliberately separate from `CoreVersionStore`: the store is the
/// immutable version model, while this struct owns the per-operation state,
/// source capture, and duplicate-event bookkeeping. Nothing here feeds
/// `load_session_for_operation`; it only mirrors facts the Agent has already
/// committed or admitted. Running `Tracking` is not the same as a completed
/// readable transcript. A `RewriteStopped` state may recover only at the
/// terminal of the same run; admission conflicts and missing child provenance
/// never recover by later terminal success.
priv struct CoreSourceCapture {
  session_id : String
  /// Deep snapshot taken before the compact model call / fork result.
  messages : Array[@kernel.Message]
  /// Fork's trimmed prefix; full length for NewThread compact.
  prefix : Int32
}

///|
priv enum CoreShadowState {
  /// The current operation may append committed facts and capture a source.
  Tracking(run_id~ : String)
  /// Terminal transcript or child provenance is recorded in the core.
  Complete
  /// A same-run transcript rewrite was observed; only this run's terminal may
  /// replace the pre-rewrite core with the final transcript.
  RewriteStopped(run_id~ : String)
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
  /// Metadata captured at admission; committed messages do not change it.
  metadata : Map[String, Map[String, Json]]
  /// (run id, last recorded event sequence) for duplicate suppression.
  last_event : Map[String, (String, Int32)]
  /// Frozen safe-point source keyed by run id. Captured before a compact model
  /// call so a misbehaving model cannot mutate the source later.
  pending_source : Map[String, CoreSourceCapture]
}

///|
fn CoreShadowRecording::CoreShadowRecording() -> CoreShadowRecording {
  {
    store: CoreVersionStore::CoreVersionStore(),
    state: Map::from_array([]),
    metadata: Map::from_array([]),
    last_event: Map::from_array([]),
    pending_source: Map::from_array([]),
  }
}

///|
/// Record the first loaded view of a session as version 0. An existing sid is
/// never overwritten: the store is an output and may lag the core after a
/// save failure. A known child with lost provenance is refused instead of
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
/// Record the actual operation baseline after admission has decided its
/// messages and metadata. This rewrites the current version only when the core
/// still matches the loaded session; otherwise it stops tracking and reports a
/// conflict, so a stale store can never overwrite facts the core already
/// committed. The rewrite makes the fixated/injected baseline explicit.
fn CoreShadowRecording::admit(
  self : CoreShadowRecording,
  session_id : String,
  baseline : Array[@kernel.Message],
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
  self.last_event[session_id] = (run_id, -1)
  self.pending_source.remove(run_id)
  let current : Result[CoreCurrent, CoreVersionError] = Ok(
    self.store.current(session_id),
  ) catch {
    error => Err(error)
  }
  match current {
    Err(UnknownSession(..)) => {
      // Hydration should have created this. Keeping the fallback makes the
      // shadow self-contained without changing the production load path.
      let recorded : Result[Int32, CoreVersionError] = Ok(
        self.store.record_full(session_id, baseline, metadata),
      ) catch {
        error => Err(error)
      }
      match recorded {
        Ok(_) => {
          self.accept(session_id, metadata, run_id)
          Ok(())
        }
        Err(error) => {
          self.state[session_id] = Stopped(
            run_id~,
            reason="admission_record_failed",
          )
          Err("admission record failed: " + core_shadow_error_label(error))
        }
      }
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
        let rewritten : Result[Int32, CoreVersionError] = Ok(
          self.store.rewrite(session_id, baseline, metadata),
        ) catch {
          error => Err(error)
        }
        match rewritten {
          Ok(_) => {
            self.accept(session_id, metadata, run_id)
            Ok(())
          }
          Err(error) => {
            self.state[session_id] = Stopped(
              run_id~,
              reason="admission_rewrite_failed",
            )
            Err("admission rewrite failed: " + core_shadow_error_label(error))
          }
        }
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
/// Stop after a same-run transcript rewrite. Only the terminal of this exact
/// run may replace the pre-rewrite body with the final transcript.
fn CoreShadowRecording::stop_rewrite(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
) -> Unit {
  match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id =>
      self.state[session_id] = RewriteStopped(run_id~)
    Some(RewriteStopped(run_id=state_run)) if state_run == run_id => ()
    _ => ()
  }
  self.pending_source.remove(run_id)
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
      // Preserve the first reason for this run; later generic cleanup must not
      // overwrite the specific stop cause.
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
    Some(RewriteStopped(run_id=state_run)) if state_run == run_id =>
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
/// Freeze the actual safe-point source before a compact model call (or at the
/// fork safe point). Only a tracked parent captures; a stopped/incomplete
/// shadow never presents an old current as a source. The snapshot is taken
/// here, in the Agent package, so later model mutation of the input view
/// cannot change the captured source.
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
  self.pending_source[run_id] = {
    session_id,
    messages: snapshot_messages(messages),
    prefix,
  }
}

///|
/// Create the child core version from the frozen safe-point capture. The
/// source must still be the parent's current version exactly; otherwise the
/// child is not recorded and the caller diagnoses/marks missing rather than
/// presenting a stale core as provenance.
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
  let current : Result[CoreCurrent, CoreVersionError] = Ok(
    self.store.current(parent_session_id),
  ) catch {
    error => Err(error)
  }
  let current = match current {
    Ok(value) => value
    Err(error) =>
      return Err("parent current failed: " + core_shadow_error_label(error))
  }
  if !core_shadow_messages_equal(current.session.messages, capture.messages) {
    return Err(
      "frozen source does not match the tracked core current; child provenance not recorded",
    )
  }
  let source : CoreSource = {
    sid: parent_session_id,
    version: current.version,
    prefix: capture.prefix,
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
    Err(error) =>
      Err("child provenance record failed: " + core_shadow_error_label(error))
  }
}

///|
/// Mirror a terminal transcript before store I/O. Only a same-operation
/// `Tracking` or same-run `RewriteStopped` state may replace the core body.
/// Conflict/stopped/missing states return without touching the leading core.
fn CoreShadowRecording::record_terminal(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Result[Unit, String] {
  let active_run : String? = match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id => Some(state_run)
    Some(RewriteStopped(run_id=state_run)) if state_run == run_id =>
      Some(state_run)
    Some(Tracking(..)) | Some(RewriteStopped(..)) =>
      return Err("terminal run does not match the current shadow run")
    Some(Complete) => None
    Some(Stopped(..)) => None
    Some(MissingProvenance) => None
    None => None
  }
  match active_run {
    None => Ok(())
    Some(run_id) => {
      let rewritten : Result[Int32, CoreVersionError] = Ok(
        self.store.rewrite(session_id, messages, metadata),
      ) catch {
        error => Err(error)
      }
      match rewritten {
        Ok(_) => {
          self.mark_complete(session_id)
          Ok(())
        }
        Err(error) => {
          self.state[session_id] = Stopped(
            run_id~,
            reason="terminal_mirror_failed",
          )
          Err("terminal mirror failed: " + core_shadow_error_label(error))
        }
      }
    }
  }
}

///|
/// Append one committed event's assistant/tool messages before store I/O.
/// Event sequence deduplication makes a replayed envelope a no-op rather than
/// a duplicate append. Metadata stays the admission snapshot; committed
/// messages do not change it.
fn CoreShadowRecording::record_committed(
  self : CoreShadowRecording,
  session_id : String,
  run_id : String,
  seq : Int32,
  messages : Array[@kernel.Message],
) -> Result[Unit, String] {
  match self.state.get(session_id) {
    Some(Tracking(run_id=state_run)) if state_run == run_id => ()
    _ => return Ok(())
  }
  match self.last_event.get(session_id) {
    Some((last_run, last_seq)) if last_run == run_id && seq <= last_seq =>
      return Ok(())
    _ => ()
  }
  let metadata = match self.metadata.get(session_id) {
    Some(value) => value
    None => {
      self.state[session_id] = Stopped(
        run_id~,
        reason="missing_admission_metadata",
      )
      return Err("tracked session has no admission metadata")
    }
  }
  let appended : Result[Int32, CoreVersionError] = Ok(
    self.store.append(session_id, messages, metadata),
  ) catch {
    error => Err(error)
  }
  match appended {
    Ok(_) => {
      self.last_event[session_id] = (run_id, seq)
      Ok(())
    }
    Err(error) => {
      self.state[session_id] = Stopped(run_id~, reason="append_failed")
      Err("append failed: " + core_shadow_error_label(error))
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
