///|
/// Typed failure of an `Events` operation. Operations never fail silently.
#derive(Eq, Debug)
pub(all) enum EventError {
  /// The Agent that owned this runtime has shut down: publish and subscribe
  /// are rejected, and remaining subscriptions are released.
  Closed
  /// An extension capability tried to publish a Posoco-owned core event.
  ReservedEvent
}

///|
pub extend EventError with Eq::{not_equal, equal}

///|
pub extend EventError with Debug::{to_repr}
