///|
/// The notification value listeners receive. Posoco owns the core wrapper;
/// a community protocol package adds its own constructor:
///
/// ```mbt nocheck
/// pub(all) extenum @events.Event += {
///   SprintChanged(SprintEvent)
/// }
/// ```
///
/// Consumers import the protocol package and pattern match the payload with
/// its static type — no JSON codec, downcast or runtime registry. Matching on
/// the open type needs a wildcard branch; the business ADT stays exhaustive.
///
/// A community payload is a value, not a serialization boundary: publish it as
/// immutable data. Posoco snapshots core `TurnEvent` payloads but does not
/// deep-copy arbitrary ADTs.
pub extenum Event

///|
/// Core notifications. The payload is the canonical `TurnEvent`, so an
/// `Observer` and a new listener see one shape for the same fact.
pub(all) extenum Event += {
  Core(@types.TurnEvent)
}
