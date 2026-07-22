///|
/// SessionStore: persist and load conversation sessions by id.
pub(open) trait SessionStore {
  fn load(Self, id : String) -> Result[@types.Session, @error.SessionError]
  fn save(Self, id : String, session : @types.Session) -> Result[
    Unit,
    @error.SessionError,
  ]
}
