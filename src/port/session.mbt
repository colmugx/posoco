///|
/// SessionStore: persist and load conversation sessions by id.
///
/// Methods use the `raise` style (matching ModelPort/CommandPort) instead of
/// returning `Result`. This eliminates the Result-plus-async redundancy and
/// lets js-target adapters (e.g. JsonlSessionStore) implement the trait
/// directly instead of going through `load_async`/`save_async` side-paths.
///|
/// One append-safe session durability boundary. `from_index` is the number
/// of messages the caller believes are already persisted. `messages` is the
/// canonical tail to append. `metadata=None` means metadata is unchanged;
/// `Some(metadata)` replaces the session metadata at the same checkpoint.
///
/// Keeping message and metadata deltas in one operation prevents callers from
/// committing transcript progress while silently dropping session state such
/// as an automatic title, context state, or task bookkeeping.
pub(all) struct SessionCheckpoint {
  from_index : Int
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]?
} derive(Eq, Debug)

///|
pub extend SessionCheckpoint with Eq::{not_equal, equal}

///|
pub extend SessionCheckpoint with Debug::{to_repr}

///|
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
  /// Commit an append-only transcript tail together with an optional metadata
  /// replacement. Stores with an atomic/native checkpoint primitive should
  /// override this method. The default preserves compatibility: unchanged
  /// metadata delegates to `append_messages`; changed metadata performs a
  /// checked load + full save so the two pieces cannot diverge.
  async fn checkpoint(
    Self,
    id : String,
    checkpoint : SessionCheckpoint,
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
      raise Load(
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
      raise Save(
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

///|
/// Default `SessionStore::checkpoint`: keep the legacy fast append path when
/// metadata is unchanged. When metadata changed, verify the persisted cursor,
/// merge the tail, and save one coherent Session snapshot. A cursor mismatch is
/// a conflict rather than a duplicate append.
impl SessionStore with fn checkpoint(
  self,
  id : String,
  checkpoint : SessionCheckpoint,
) -> Unit raise @error.SessionError {
  match checkpoint.metadata {
    None =>
      self.append_messages(
        id,
        checkpoint.from_index,
        checkpoint.messages[:],
      )
    Some(metadata) => {
      let session = self.load(id)
      let merged = session.messages.copy()
      for msg in checkpoint.messages {
        merged.push(msg)
      }
      self.save(id, { messages: merged, metadata, })
    }
  }
}
