///|
/// Child invocation results do not conflate an interrupted scope with a
/// completed business outcome. A propagated cancel is not proof of rollback.
pub(all) enum InvocationResult {
  Completed(ToolOutcome)
  Interrupted(
    reason~ : String,
    cancellation~ : CancelDisposition,
    side_effects_possible~ : Bool
  )
} derive(Eq, Debug)

///|
pub extend InvocationResult with Eq::{equal, not_equal}

///|
pub extend InvocationResult with Debug::{to_repr}
