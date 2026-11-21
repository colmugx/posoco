///|

///|
/// One append-safe session durability boundary. `from_index` is the number
/// of messages the caller believes are already persisted. `messages` is the
/// canonical tail to append. `metadata=None` means metadata is unchanged;
/// `Some(metadata)` replaces the session metadata at the same checkpoint.
///
/// Keeping message and metadata deltas in one operation prevents callers from
/// committing transcript progress while silently dropping session state such
/// as an automatic title, context state, or task bookkeeping.
#derive(Eq, Debug)
pub(all) struct SessionCheckpoint {
  from_index : Int32
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]?
}

///|
pub extend SessionCheckpoint with Eq::{not_equal, equal}

///|
pub extend SessionCheckpoint with Debug::{to_repr}

///|
pub(open) trait SessionPort {
  async fn load(Self, id : String) -> @types.Session raise @error.SessionError
  async fn save(Self, id : String, session : @types.Session) -> Unit raise @error.SessionError
  /// Append a slice of messages to a session starting at `from_index`.
  /// Default implementation loads the session, concatenates the messages, and
  /// performs a full save, preserving existing third-party stores.
  async fn append_messages(
    Self,
    id : String,
    from_index : Int32,
    messages : ArrayView[@kernel.Message],
  ) -> Unit raise @error.SessionError = _
  /// Commit an append-only transcript tail together with an optional metadata
  /// replacement. Stores with an atomic/native checkpoint primitive should
  /// override this method. The default preserves compatibility: unchanged
  /// metadata delegates to `append_messages`; changed metadata performs a
  /// checked load + full save so the two pieces cannot diverge.
  async fn checkpoint(Self, id : String, checkpoint : SessionCheckpoint) -> Unit raise @error.SessionError = _
  /// Drop persisted messages at `from_index` and after, keeping
  /// `[0, from_index)`. `from_index` is clamped to the message bounds, so
  /// out-of-range values do not raise. Default implementation loads the
  /// session, slices the messages, and performs a full save (the same legal
  /// whole-session path compact uses), preserving metadata.
  async fn truncate(Self, id : String, from_index : Int32) -> Unit raise @error.SessionError = _
}

///|
impl SessionPort with fn truncate(self, id : String, from_index : Int32) -> Unit raise @error.SessionError {
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
impl SessionPort with fn append_messages(
  self,
  id : String,
  from_index : Int32,
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
impl SessionPort with fn checkpoint(
  self,
  id : String,
  checkpoint : SessionCheckpoint,
) -> Unit raise @error.SessionError {
  match checkpoint.metadata {
    None => self.append_messages(id, checkpoint.from_index, checkpoint.messages)
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
