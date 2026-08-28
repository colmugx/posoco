///|
/// SessionStore: persist and load conversation sessions by id.
///
/// Methods use the `raise` style (matching ModelPort/CommandPort) instead of
/// returning `Result`. This eliminates the Result-plus-async redundancy and
/// lets js-target adapters (e.g. JsonlSessionStore) implement the trait
/// directly instead of going through `load_async`/`save_async` side-paths.
pub(open) trait SessionStore {
  async fn load(Self, id : String) -> @types.Session raise @error.SessionError
  async fn save(Self, id : String, session : @types.Session) -> Unit raise @error.SessionError
  /// Append a slice of messages to a session starting at `from_index`.
  /// Default implementation loads the session, concatenates the messages, and
  /// performs a full save, preserving existing third-party stores.
  async fn append_messages(
    Self,
    id : String,
    from_index : Int,
    messages : ArrayView[@kernel.Message],
  ) -> Unit raise @error.SessionError = _
}

///|
/// Default `SessionStore::append_messages`: compatibility fallback for stores
/// that do not implement true append. Loads, concatenates, and saves.
impl SessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int,
  messages : ArrayView[@kernel.Message],
) -> Unit raise @error.SessionError {
  let _ = from_index
  let session = self.load(id)
  let merged = session.messages.copy()
  for msg in messages {
    merged.push(msg)
  }
  self.save(id, { messages: merged, metadata: session.metadata, })
}
