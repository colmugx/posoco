///|
/// `EnqueueOutcome` stays in the runtime package as a pure result value;
/// AgentControl's mailbox ownership and queue drain live in the root package.

///|
test "runtime control outcome remains displayable" {
  assert_eq(
    EnqueueOutcome::Accepted(command_id="follow_up_1").to_string(),
    "Accepted(follow_up_1)",
  )
  assert_eq(
    EnqueueOutcome::RejectedQueueFull(depth=64).to_string(),
    "RejectedQueueFull(depth=64)",
  )
}
