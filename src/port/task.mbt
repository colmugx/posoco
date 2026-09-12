///|
/// Execution lifetime for work submitted through the composed task capability.
pub(all) enum TaskMode {
  Foreground
  Background
} derive(Eq, Debug)

///|
/// A unit of Agent-owned work. The Agent supplies the structured scope and
/// records the terminal outcome; callers never supply a TaskGroup.
pub(all) struct TaskSpec {
  session_id : String
  mode : TaskMode
  label : String
  timeout_ms : Int?
  run : async () -> @kernel.Message
}

///|
/// Stable identity returned at admission. The id is opaque to the caller.
pub(all) struct TaskReceipt {
  id : String
  session_id : String
  mode : TaskMode
  label : String
  extension_id : String
} derive(Eq, Debug)

///|
/// The single terminal state shared by foreground waits and background inbox
/// delivery.
pub(all) enum TaskStatus {
  Completed(message~ : @kernel.Message)
  Failed(reason~ : String)
  TimedOut
  Cancelled(reason~ : String)
} derive(Eq, Debug)

///|
/// A task's terminal result. Background outcomes are retained by session
/// until the owning Agent successfully commits them.
pub(all) struct TaskOutcome {
  receipt : TaskReceipt
  status : TaskStatus
} derive(Eq, Debug)

///|
/// Admission failures are explicit so an extension cannot mistake an
/// inactive scope or a closed Agent for accepted work.
pub(all) enum TaskSubmitError {
  Unavailable
  Closed
  QueueFull
  InvalidSession(reason~ : String)
} derive(Eq, Debug)

///|
/// Opaque handle for one admitted task. The callbacks are installed by core
/// composition; extensions only receive wait/cancel operations.
pub struct TaskHandle {
  priv receipt_ : TaskReceipt
  priv wait_ : async (TaskReceipt) -> TaskOutcome
  priv cancel_ : (TaskReceipt) -> Unit
}

///|
pub fn TaskHandle::receipt(self : TaskHandle) -> TaskReceipt {
  self.receipt_
}

///|
pub async fn TaskHandle::wait(self : TaskHandle) -> TaskOutcome {
  (self.wait_)(self.receipt_)
}

///|
pub fn TaskHandle::cancel(self : TaskHandle) -> Unit {
  (self.cancel_)(self.receipt_)
}

///|
/// Concrete composed capability. It is deliberately a value rather than a
/// public trait: task admission is Agent-owned and has no replacement port.
pub struct Tasks {
  priv submit_ : (TaskSpec) -> Result[TaskHandle, TaskSubmitError]
}

///|
pub fn Tasks::submit(
  self : Tasks,
  spec : TaskSpec,
) -> Result[TaskHandle, TaskSubmitError] {
  (self.submit_)(spec)
}

///|
/// Framework construction hook. Product extensions obtain the value through
/// CompositionView and do not need this constructor.
pub fn Tasks::from_submit(
  submit~ : (TaskSpec) -> Result[TaskHandle, TaskSubmitError],
) -> Tasks {
  { submit_: fn(spec) { submit(spec) }, }
}

///|
/// Framework construction hook for the opaque handle.
pub fn TaskHandle::from_callbacks(
  receipt~ : TaskReceipt,
  wait~ : async (TaskReceipt) -> TaskOutcome,
  cancel~ : (TaskReceipt) -> Unit,
) -> TaskHandle {
  { receipt_: receipt, wait_: wait, cancel_: cancel, }
}
