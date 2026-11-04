///|
/// One delivered event with the metadata the system produced for it.
/// Subscribers read `namespace_`, `scope` and `event`; they never author
/// delivery metadata. `scope` is `None` for operation-level notifications
/// that belong to no run.
///
/// `namespace` is a reserved word in MoonBit, so the field is `namespace_`
/// and `namespace_of()` is the plain-reader accessor.
///
/// # Example
/// ```mbt check
/// test {
///   let envelope = @events.EventEnvelope(
///     namespace_=@events.Posoco,
///     event=@events.Core(TurnStarted),
///   )
///   assert_eq(envelope.namespace_of(), @events.Posoco)
///   assert_eq(envelope.scope, None)
///   guard envelope.event is @events.Core(TurnStarted) else {
///     fail("expected a core turn start")
///   }
/// }
/// ```
pub struct EventEnvelope {
  namespace_ : EventNamespace
  scope : @types.EventScope?
  event : Event
}

///|
/// Framework construction hook: the runtime stamps real delivery metadata.
/// Subscribers receive envelopes and do not need this constructor.
pub fn EventEnvelope::EventEnvelope(
  namespace_~ : EventNamespace,
  event~ : Event,
  scope~ : @types.EventScope? = None,
) -> EventEnvelope {
  { namespace_, scope, event, }
}

///|
pub fn EventEnvelope::namespace_of(self : EventEnvelope) -> EventNamespace {
  self.namespace_
}
