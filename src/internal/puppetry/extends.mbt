// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration re-enables `value.method()` syntax for
// one trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form. Keep this list limited to methods
// that are actually dot-called within this module.

///|
pub extend ContributionError with Show::{to_string}

///|
pub extend ControlMailbox with Mailbox::{
  abort_requested,
  active_run_id,
  active_turn_id,
  bind_run,
  clear_run,
  compact_depth,
  consume_one_compact,
  consume_one_follow_up,
  consume_one_fork,
  consume_steers,
  enqueue_abort,
  enqueue_compact,
  enqueue_follow_up,
  enqueue_fork,
  enqueue_resume,
  enqueue_steer,
  follow_up_depth,
  fork_depth,
  quiescent_status,
  set_quiescent,
  steer_depth,
  take_resume,
  wait_idle,
}

///|
pub extend InMemoryJournal with RunJournal::{
  append,
  entries_for_run,
  entries_for_savepoint,
  revision,
}

///|
pub extend NoopContributor with JournalContributor::{contribute}

///|
pub extend OperationClass with Show::{to_string}

///|
pub extend PromptResult with Show::{to_string}

///|
pub extend PuppetError with Show::{to_string}

///|
pub extend PuppetPhase with Show::{to_string}

///|
pub extend QuiescentStatus with Show::{to_string}

///|
pub extend SavepointFailureCause with Show::{to_string}

///|
pub extend SavepointKind with Show::{to_string}

///|
pub extend SubscriberError with Show::{to_string}

///|
pub extend TurnSnapshot with Show::{to_string}
