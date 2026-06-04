///|
/// InMemorySessionStore — stores sessions in a mutable Map for the REPL demo
pub(all) struct InMemorySessionStore {
  mut store : Map[String, @posoco.Session]
}

///|
pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { store: {} }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn load(
  self,
  id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok(@posoco.Session::{ messages: [], metadata: {} })
  }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
  self.store[id] = session
  Ok(())
}
