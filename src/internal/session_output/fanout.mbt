///|
/// Multi-store session output execution: the write-all and append-safe
/// checkpoint waves. These are pure IO mechanics — every store receives its own
/// deep snapshot, all stores are dispatched, and the first failure in port
/// order is reported. Operation selection, cursor/dirty accounting and event
/// ordering stay with the caller.

///|
pub fn contextualize_session_error(
  error : @error.SessionError,
  session_id : String,
  operation : String,
) -> @error.AgentError {
  let cause = @diagnostic.safe_error_label(error.to_string())
  Session(
    match error {
      Load(_) =>
        Load(
          "session_id='\{@diagnostic.safe_error_label(session_id)}', operation='\{operation}', category='SessionError::Load', cause='\{cause}'",
        )
      Save(_) =>
        Save(
          "session_id='\{@diagnostic.safe_error_label(session_id)}', operation='\{operation}', category='SessionError::Save', cause='\{cause}'",
        )
      Conflict(_) =>
        Conflict(
          "session_id='\{@diagnostic.safe_error_label(session_id)}', operation='\{operation}', category='SessionError::Conflict', cause='\{cause}'",
        )
    },
  )
}

///|
/// Contextualize a generic `Error` raised by a parallel session-save wave as a
/// `SessionError::Save`. The thunks themselves return `Result[Unit,
/// SessionError]`, so this path only handles async-runtime/cancellation errors
/// that escape `@async.all` itself.
fn save_error_context(
  error : Error,
  session_id : String,
  operation : String,
) -> @error.AgentError {
  let context = "session_id='\{@diagnostic.safe_error_label(session_id)}', operation='\{operation}', category='SessionError::Save', cause='\{@diagnostic.safe_error_label(error.to_string())}'"
  Session(Save(context))
}

///|
/// Save one session body to every configured store (write-all). Each store
/// receives its own deep snapshot so a misbehaving store cannot mutate
/// another store's payload; `operation` labels both error contexts verbatim.
/// An empty store list dispatches nothing and succeeds.
pub async fn save_all(
  stores : Array[&@port.SessionPort],
  session_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
  operation : String,
) -> Unit raise @error.AgentError {
  let save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
    stores.map(fn(store) {
      () => {
        let session : @types.Session = {
          messages: @message_snapshot.snapshot_messages(messages),
          metadata: @message_snapshot.snapshot_metadata(metadata),
        }
        Ok(store.save(session_id, session)) catch {
          error => Err(error)
        }
      }
    }),
  ) catch {
    error => raise save_error_context(error, session_id, operation)
  }
  for result in save_results {
    match result {
      Err(error) =>
        raise contextualize_session_error(error, session_id, operation)
      Ok(_) => ()
    }
  }
}

///|
/// Commit one append-safe session boundary to every configured store. Each
/// store receives its own snapshot of the tail and of the metadata
/// replacement; `operation` labels both error contexts verbatim. Cursor
/// accounting belongs to the caller and only happens after this returns.
pub async fn checkpoint_all(
  stores : Array[&@port.SessionPort],
  session_id : String,
  from_index : Int32,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json]?,
  operation : String,
) -> Unit raise @error.AgentError {
  let results : Array[Result[Unit, @error.SessionError]] = @async.all(
    stores.map(fn(store) {
      () => {
        let metadata_snapshot = match metadata {
          Some(value) => Some(@message_snapshot.snapshot_metadata(value))
          None => None
        }
        let checkpoint : @port.SessionCheckpoint = {
          from_index,
          messages: @message_snapshot.snapshot_messages(messages),
          metadata: metadata_snapshot,
        }
        Ok(store.checkpoint(session_id, checkpoint)) catch {
          error => Err(error)
        }
      }
    }),
  ) catch {
    error => raise save_error_context(error, session_id, operation)
  }
  for result in results {
    match result {
      Ok(_) => ()
      Err(error) =>
        raise contextualize_session_error(error, session_id, operation)
    }
  }
}
