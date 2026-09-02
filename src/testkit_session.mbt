// ---------------------------------------------------------------------------
// RecordingSessionStore — load/save history with metadata snapshots.
// ---------------------------------------------------------------------------

///|
/// A recorded session operation. Constructors are prefixed with `Op` to avoid
/// ambiguity with `SessionError::Load`/`SessionError::Save`.
pub(all) enum SessionOp {
  OpLoad(id~ : String, result~ : Result[@types.Session, @error.SessionError])
  OpSave(
    id~ : String,
    metadata~ : Map[String, Json],
    result~ : Result[Unit, @error.SessionError]
  )
  OpAppend(
    id~ : String,
    from_index~ : Int,
    messages~ : Array[@kernel.Message],
    result~ : Result[Unit, @error.SessionError]
  )
  OpTruncate(
    id~ : String,
    from_index~ : Int,
    result~ : Result[Unit, @error.SessionError]
  )
} derive(Debug)

///|
/// SessionStore fake that keeps an in-memory map and records every load/save
/// with the metadata snapshot at save time. Load/save failures are
/// configurable per id.
pub(all) struct RecordingSessionStore {
  store : Map[String, @types.Session]
  mut load_failures : Map[String, @error.SessionError]
  mut save_failures : Array[String]
  mut ops : Array[SessionOp]
}

///|
pub fn RecordingSessionStore::RecordingSessionStore() -> RecordingSessionStore {
  {
    store: Map::from_array([]),
    load_failures: Map::from_array([]),
    save_failures: [],
    ops: [],
  }
}

///|
/// Seed a session id with an existing session (including metadata).
pub fn RecordingSessionStore::seed(
  self : RecordingSessionStore,
  id : String,
  session : @types.Session,
) -> Unit {
  self.store[id] = snapshot_session(session.messages, session.metadata)
}

///|
/// Configure load to fail for a given id.
pub fn RecordingSessionStore::fail_load(
  self : RecordingSessionStore,
  id : String,
  err : @error.SessionError,
) -> Unit {
  self.load_failures[id] = err
}

///|
/// Configure save to fail for a given id (all subsequent saves to that id).
pub fn RecordingSessionStore::fail_save(
  self : RecordingSessionStore,
  id : String,
) -> Unit {
  self.save_failures.push(id)
}

///|
/// Recorded operations in order.
pub fn RecordingSessionStore::ops(
  self : RecordingSessionStore,
) -> Array[SessionOp] {
  self.ops.map(fn(op) {
    match op {
      OpLoad(id~, result~) =>
        OpLoad(
          id~,
          result=match result {
            Ok(session) =>
              Ok(snapshot_session(session.messages, session.metadata))
            Err(error) => Err(error)
          },
        )
      OpSave(id~, metadata~, result~) =>
        OpSave(id~, metadata=snapshot_metadata(metadata), result~)
      OpAppend(id~, from_index~, messages~, result~) =>
        OpAppend(
          id~,
          from_index~,
          messages=snapshot_messages(messages),
          result~,
        )
      OpTruncate(id~, from_index~, result~) =>
        OpTruncate(id~, from_index~, result~)
    }
  })
}

///|
/// All save operations, in order, as (id, metadata_snapshot) pairs.
pub fn RecordingSessionStore::save_snapshots(
  self : RecordingSessionStore,
) -> Array[(String, Map[String, Json])] {
  let out : Array[(String, Map[String, Json])] = []
  for op in self.ops {
    match op {
      OpSave(id~, metadata~, ..) => out.push((id, snapshot_metadata(metadata)))
      _ => ()
    }
  }
  out
}

///|
/// The configured save failure for `id`, if one was armed via `fail_save`.
/// Shared guard of every mutating store operation.
fn RecordingSessionStore::guard_save(
  self : RecordingSessionStore,
  id : String,
) -> @error.SessionError? {
  if self.save_failures.contains(id) {
    Some(Save("configured save failure for '\{id}'"))
  } else {
    None
  }
}

///|
/// Record an operation, then surface its failure: ops keep arrival order and
/// a configured error raises only after being recorded. Shared tail of
/// load/save/append/truncate.
fn[T] RecordingSessionStore::record(
  self : RecordingSessionStore,
  op : SessionOp,
  result : Result[T, @error.SessionError],
) -> T raise @error.SessionError {
  self.ops.push(op)
  match result {
    Ok(value) => value
    Err(e) => raise e
  }
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn load(
  self,
  id : String,
) -> @types.Session raise @error.SessionError {
  let result : Result[@types.Session, @error.SessionError] = match
    self.load_failures.get(id) {
    Some(e) => Err(e)
    None =>
      match self.store.get(id) {
        Some(s) => Ok(snapshot_session(s.messages, s.metadata))
        None => Ok({ messages: [], metadata: Map::from_array([]), })
      }
  }
  let recorded_result = match result {
    Ok(session) => Ok(snapshot_session(session.messages, session.metadata))
    Err(error) => Err(error)
  }
  self.record(OpLoad(id~, result=recorded_result), result)
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  let meta_copy = snapshot_metadata(session.metadata)
  let result : Result[Unit, @error.SessionError] = match self.guard_save(id) {
    Some(e) => Err(e)
    None => {
      self.store[id] = snapshot_session(session.messages, session.metadata)
      Ok(())
    }
  }
  self.record(OpSave(id~, metadata=meta_copy, result~), result)
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int,
  messages : ArrayView[@kernel.Message],
) -> Unit raise @error.SessionError {
  let msg_copy = snapshot_messages(messages.to_owned())
  let result : Result[Unit, @error.SessionError] = match self.guard_save(id) {
    Some(e) => Err(e)
    None => {
      let session = match self.store.get(id) {
        Some(s) => snapshot_session(s.messages, s.metadata)
        None => { messages: [], metadata: Map::from_array([]), }
      }
      let merged = session.messages.copy()
      for msg in msg_copy {
        merged.push(msg)
      }
      self.store[id] = { messages: merged, metadata: session.metadata, }
      Ok(())
    }
  }
  self.record(OpAppend(id~, from_index~, messages=msg_copy, result~), result)
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int,
) -> Unit raise @error.SessionError {
  let result : Result[Unit, @error.SessionError] = match self.guard_save(id) {
    Some(e) => Err(e)
    None => {
      let session = match self.store.get(id) {
        Some(s) => snapshot_session(s.messages, s.metadata)
        None => { messages: [], metadata: Map::from_array([]), }
      }
      let len = session.messages.length()
      let keep = if from_index < 0 {
        0
      } else if from_index > len {
        len
      } else {
        from_index
      }
      let kept = session.messages[:keep].to_owned()
      self.store[id] = { messages: kept, metadata: session.metadata, }
      Ok(())
    }
  }
  self.record(OpTruncate(id~, from_index~, result~), result)
}
