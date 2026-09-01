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
  /// Drop persisted messages at `from_index` and after, keeping
  /// `[0, from_index)`. `from_index` is clamped to the message bounds, so
  /// out-of-range values do not raise. Default implementation loads the
  /// session, slices the messages, and performs a full save (the same legal
  /// whole-session path compact uses), preserving metadata.
  async fn truncate(Self, id : String, from_index : Int) -> Unit raise @error.SessionError = _
}

///|
/// Default `SessionStore::truncate`: compatibility fallback for stores that do
/// not implement native truncation. Failures from the underlying load/save are
/// re-raised with their variant preserved and an `operation='truncate'` context
/// label, mirroring the agent-boundary error contextualization style.
impl SessionStore with fn truncate(self, id : String, from_index : Int) -> Unit raise @error.SessionError {
  let session = self.load(id) catch {
    error =>
      raise @error.SessionError::Load(
        "session_id='\{id}', operation='truncate', category='SessionError::Load', cause='\{error.to_string()}'",
      )
  }
  let len = session.messages.length()
  let keep = if from_index < 0 {
    0
  } else if from_index > len {
    len
  } else {
    from_index
  }
  let kept : Array[@kernel.Message] = []
  for i in 0..<keep {
    kept.push(session.messages[i])
  }
  self.save(id, { messages: kept, metadata: session.metadata, }) catch {
    error =>
      raise @error.SessionError::Save(
        "session_id='\{id}', operation='truncate', category='SessionError::Save', cause='\{error.to_string()}'",
      )
  }
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
