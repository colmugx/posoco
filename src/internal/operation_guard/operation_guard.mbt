///|
pub suberror OperationBusy {
  Busy(operation_id~ : String, session~ : String)
}

///|
priv struct Execution {
  operation_id : String
  mut cancel_requested : Bool
  mut cancel_worker : (() -> Unit)?
  settle : @async.CondVar
  mut settled : Bool
}

///|
pub struct OperationGuard {
  priv mut current_id : String?
  priv mut current_session : String?
  priv mut current_origin : String?
  priv mut execution : Execution?
}

///|
pub fn OperationGuard::OperationGuard() -> OperationGuard {
  {
    current_id: None,
    current_session: None,
    current_origin: None,
    execution: None,
  }
}

///|
pub fn OperationGuard::try_admit(
  self : OperationGuard,
  operation_id : String,
  session_id : String,
  origin : String,
) -> Unit raise OperationBusy {
  match self.current_id {
    Some(id) =>
      raise Busy(
        operation_id=id,
        session=match self.current_session {
          Some(value) => value
          None => ""
        },
      )
    None => ()
  }
  self.current_id = Some(operation_id)
  self.current_session = Some(session_id)
  self.current_origin = Some(origin)
}

///|
pub fn OperationGuard::busy(self : OperationGuard) -> OperationBusy? {
  match self.current_id {
    Some(id) =>
      Some(
        Busy(
          operation_id=id,
          session=match self.current_session {
            Some(value) => value
            None => ""
          },
        ),
      )
    None => None
  }
}

///|
/// Roll back an admission that failed before `begin_execution`/turn activity.
/// This is the pre-guard-ownership rollback: no settled projection or wakeup.
pub fn OperationGuard::abort_admit(
  self : OperationGuard,
  operation_id : String,
) -> Unit {
  match self.current_id {
    Some(current) if current == operation_id => {
      self.current_id = None
      self.current_session = None
      self.current_origin = None
    }
    _ => ()
  }
}

///|
pub fn OperationGuard::has_current(self : OperationGuard) -> Bool {
  self.current_id is Some(_)
}

///|
pub fn OperationGuard::current_id(self : OperationGuard) -> String? {
  self.current_id
}

///|
pub fn OperationGuard::current_session(self : OperationGuard) -> String? {
  self.current_session
}

///|
pub fn OperationGuard::begin_execution(
  self : OperationGuard,
  operation_id : String,
) -> Unit {
  match self.current_id {
    Some(current) if current == operation_id =>
      self.execution = Some({
        operation_id,
        cancel_requested: false,
        cancel_worker: None,
        settle: @async.CondVar::Cond(),
        settled: false,
      })
    _ => ()
  }
}

///|
pub fn OperationGuard::register_cancel(
  self : OperationGuard,
  operation_id : String,
  cancel : () -> Unit,
) -> Unit {
  match self.execution {
    Some(execution) if execution.operation_id == operation_id => {
      execution.cancel_worker = Some(cancel)
      if execution.cancel_requested {
        cancel()
      }
    }
    _ => ()
  }
}

///|
pub fn OperationGuard::request_cancel(self : OperationGuard) -> Unit {
  match self.execution {
    Some(execution) => {
      execution.cancel_requested = true
      match execution.cancel_worker {
        Some(cancel) => cancel()
        None => ()
      }
    }
    None => ()
  }
}

///|
pub fn OperationGuard::has_execution(self : OperationGuard) -> Bool {
  self.execution is Some(_)
}

///|
/// Clear matching current admission only. The caller owns the exact ordering
/// around version release and execution settlement.
pub fn OperationGuard::clear_current(
  self : OperationGuard,
  operation_id : String,
) -> Bool {
  match self.current_id {
    Some(current) if current == operation_id => {
      self.current_id = None
      self.current_session = None
      self.current_origin = None
      true
    }
    _ => false
  }
}

///|
pub fn OperationGuard::settle_execution(
  self : OperationGuard,
  operation_id : String,
) -> Unit {
  match self.execution {
    Some(execution) if execution.operation_id == operation_id => {
      execution.settled = true
      execution.settle.broadcast()
      self.execution = None
    }
    _ => ()
  }
}

///|
pub async fn OperationGuard::wait_settled(
  self : OperationGuard,
  timeout_ms : Int32,
) -> Bool raise Error {
  match self.execution {
    None => true
    Some(execution) => {
      let waited = @async.with_timeout_opt(timeout_ms, async fn() {
        while !execution.settled {
          execution.settle.wait()
        }
      })
      waited is Some(_)
    }
  }
}

///|
pub fn OperationGuard::straggler_detail(self : OperationGuard) -> String {
  match self.current_id {
    Some(id) => {
      let session = match self.current_session {
        Some(value) => value
        None => ""
      }
      let origin = match self.current_origin {
        Some(value) => value
        None => ""
      }
      "operation_id=" + id + " session=" + session + " origin=" + origin
    }
    None => "no active operation"
  }
}
