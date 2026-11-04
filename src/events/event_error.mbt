///|
/// Typed failure of event capability and resource operations.
#derive(Eq, Debug)
pub(all) enum EventError {
  /// The resource was closed explicitly, by failed composition, or by shutdown.
  Closed
  /// An extension capability tried to publish a Posoco-owned core event.
  ReservedEvent
  /// Publication owners must not be empty or entirely whitespace.
  InvalidOwner
  /// Only the owning Agent may close a resource after taking ownership.
  Owned
}

///|
pub extend EventError with Eq::{not_equal, equal}

///|
pub extend EventError with Debug::{to_repr}
