///|
/// SessionStore: persist and load conversation sessions by id.
pub(open) trait SessionStore {
  fn load(Self, id : String) -> Result[Session, SessionError]
  fn save(Self, id : String, session : Session) -> Result[Unit, SessionError]
}
