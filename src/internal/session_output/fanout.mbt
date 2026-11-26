///|

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

///|
/// Fork a prefix of `from_id` into `session_id` across every configured store.
pub async fn fork_all(
  stores : Array[&@port.SessionPort],
  session_id : String,
  from_id : String,
  at_index : Int32,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
  operation : String,
) -> Unit raise @error.AgentError {
  let results : Array[Result[Unit, @error.SessionError]] = @async.all(
    stores.map(fn(store) {
      () => {
        let fork : @port.SessionFork = {
          from_id,
          at_index,
          messages: @message_snapshot.snapshot_messages(messages),
          metadata: @message_snapshot.snapshot_metadata(metadata),
        }
        Ok(store.fork(session_id, fork)) catch {
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

///|
/// Truncate `session_id` to `[0, from_index)` across every configured store.
pub async fn truncate_all(
  stores : Array[&@port.SessionPort],
  session_id : String,
  from_index : Int32,
  operation : String,
) -> Unit raise @error.AgentError {
  let results : Array[Result[Unit, @error.SessionError]] = @async.all(
    stores.map(fn(store) {
      () => {
        Ok(store.truncate(session_id, from_index)) catch {
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
