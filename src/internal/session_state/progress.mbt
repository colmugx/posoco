///|
/// Persisted-prefix bookkeeping owned by the Agent and shared by two writers:
/// the terminal/full-save path (absolute cursor positions) and the
/// committed-event checkpoint subscriber (one message per boundary). `cursors`
/// tracks how much of a session's transcript is confirmed written to every
/// store; `dirty` marks sessions whose canonical transcript was rewritten
/// (compact/hook rewrite) so incremental projection pauses until the next
/// terminal full save re-establishes a canonical prefix. Both maps have a
/// single mutation surface — these methods.
pub struct SessionProgress {
  cursors : Map[String, Int32]
  dirty : Map[String, Bool]
}

///|
pub fn SessionProgress::SessionProgress() -> SessionProgress {
  { cursors: Map::from_array([]), dirty: Map::from_array([]), }
}

///|
/// Absolute cursor set: the next incremental append starts at this length.
/// Used by rewrites, restores, and full saves.
pub fn SessionProgress::set_cursor(
  self : SessionProgress,
  session_id : String,
  length : Int32,
) -> Unit {
  self.cursors[session_id] = length
}

///|
/// Cursor after one more committed message (boundary subscriber path).
pub fn SessionProgress::advance_one(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  let cursor = match self.cursors.get(session_id) {
    Some(value) => value
    None => 0
  }
  self.cursors[session_id] = cursor + 1
}

///|
pub fn SessionProgress::cursor_or_zero(
  self : SessionProgress,
  session_id : String,
) -> Int32 {
  match self.cursors.get(session_id) {
    Some(value) => value
    None => 0
  }
}

///|
pub fn SessionProgress::mark_dirty(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  self.dirty[session_id] = true
}

///|
pub fn SessionProgress::mark_clean(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  self.dirty.remove(session_id)
}

///|
pub fn SessionProgress::is_dirty(
  self : SessionProgress,
  session_id : String,
) -> Bool {
  self.dirty.contains(session_id)
}
