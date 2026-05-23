///|
/// InMemorySessionStore — stores sessions in a mutable Map for the REPL demo
pub(all) struct InMemorySessionStore {
  mut store : Map[String, @posoco.Session]
}

///|
pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { store: Map::from_array([]) }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with load(
  self,
  id : String,
) {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok(@posoco.Session::{ messages: [], metadata: Map::from_array([]) })
  }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with save(
  self,
  id : String,
  session : @posoco.Session,
) {
  self.store[id] = session
  Ok(())
}
