///|
pub(all) struct CursorState {
  cursor : Int32
  dirty : Bool
}

///|
pub fn cursor_init() -> CursorState where {
  proof_ensure: result => {
    cursor_inv(result) && result.cursor == 0 && !result.dirty
  },
} {
  { cursor: 0, dirty: false, }
}

///|
pub fn set_cursor_checked(
  state : CursorState,
  next_cursor : Int32,
) -> CursorState where {
  proof_require: cursor_inv(state),
  proof_ensure: result => {
    cursor_inv(result) &&
    result.dirty == state.dirty &&
    (next_cursor >= 0 → result.cursor == next_cursor) &&
    (next_cursor < 0 → result.cursor == 0)
  },
} {
  let clamped = if next_cursor < 0 { 0 } else { next_cursor }
  { cursor: clamped, dirty: state.dirty, }
}

///|
pub fn advance_one_if_clean(
  state : CursorState,
) -> CursorState where {
  proof_require: cursor_inv(state) && state.cursor < 2_147_483_647,
  proof_ensure: result => {
    cursor_inv(result) &&
    result.dirty == state.dirty &&
    result.cursor >= state.cursor &&
    (state.dirty → result.cursor == state.cursor) &&
    (!state.dirty → result.cursor == state.cursor + 1)
  },
} {
  if state.dirty {
    state
  } else {
    { cursor: state.cursor + 1, dirty: false, }
  }
}

///|
pub fn mark_dirty(
  state : CursorState,
) -> CursorState where {
  proof_require: cursor_inv(state),
  proof_ensure: result => {
    cursor_inv(result) && result.cursor == state.cursor && result.dirty
  },
} {
  { cursor: state.cursor, dirty: true, }
}

///|
pub fn mark_clean(
  state : CursorState,
) -> CursorState where {
  proof_require: cursor_inv(state),
  proof_ensure: result => {
    cursor_inv(result) && result.cursor == state.cursor && !result.dirty
  },
} {
  { cursor: state.cursor, dirty: false, }
}
