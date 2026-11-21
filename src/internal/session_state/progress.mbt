///|
pub struct SessionProgress {
  priv states : Map[String, @proof_progress.CursorState]
}

///|
pub fn SessionProgress::SessionProgress() -> SessionProgress {
  { states: Map::from_array([]), }
}

///|
fn SessionProgress::state_of(
  self : SessionProgress,
  session_id : String,
) -> @proof_progress.CursorState {
  match self.states.get(session_id) {
    Some(value) => value
    None => @proof_progress.cursor_init()
  }
}

///|
pub fn SessionProgress::set_cursor(
  self : SessionProgress,
  session_id : String,
  length : Int32,
) -> Unit {
  self.states[session_id] = @proof_progress.set_cursor_checked(
    self.state_of(session_id),
    length,
  )
}

///|
pub fn SessionProgress::advance_one(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  self.states[session_id] = @proof_progress.advance_one_if_clean(
    self.state_of(session_id),
  )
}

///|
pub fn SessionProgress::cursor(
  self : SessionProgress,
  session_id : String,
) -> Int32? {
  self.states.get(session_id).map(fn(s) { s.cursor })
}

///|
pub fn SessionProgress::tracked_sessions(
  self : SessionProgress,
) -> Array[String] {
  Array::from_iter(self.states.keys())
}

///|
pub fn SessionProgress::cursor_or_zero(
  self : SessionProgress,
  session_id : String,
) -> Int32 {
  self.state_of(session_id).cursor
}

///|
pub fn SessionProgress::mark_dirty(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  self.states[session_id] = @proof_progress.mark_dirty(
    self.state_of(session_id),
  )
}

///|
pub fn SessionProgress::mark_clean(
  self : SessionProgress,
  session_id : String,
) -> Unit {
  self.states[session_id] = @proof_progress.mark_clean(
    self.state_of(session_id),
  )
}

///|
pub fn SessionProgress::is_dirty(
  self : SessionProgress,
  session_id : String,
) -> Bool {
  self.state_of(session_id).dirty
}
