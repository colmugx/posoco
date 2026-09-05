///|
/// Pure result returned by Agent-owned host control operations.
pub(all) enum EnqueueOutcome {
  /// Command accepted; carries the command id for diagnostics/correlation.
  Accepted(command_id~ : String)
  /// Rejected because there is no active run, or the target went stale.
  RejectedStale(reason~ : String)
  /// Rejected because the follow-up queue is full.
  RejectedQueueFull(depth~ : Int)
  /// Abort arrived after a previous abort already fired for the active run.
  AbortAlreadyRequested
  /// A queue operation failed for a reason other than queue capacity.
  RejectedQueueFailure(reason~ : String)
} derive(Eq, Debug)

///|
pub impl Show for EnqueueOutcome with fn to_string(self : EnqueueOutcome) -> String {
  match self {
    Accepted(command_id~) => "Accepted(\{command_id})"
    RejectedStale(reason~) => "RejectedStale(\{reason})"
    RejectedQueueFull(depth~) => "RejectedQueueFull(depth=\{depth})"
    AbortAlreadyRequested => "AbortAlreadyRequested"
    RejectedQueueFailure(reason~) => "RejectedQueueFailure(\{reason})"
  }
}
