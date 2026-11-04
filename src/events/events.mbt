///|
/// Owner-bound event capability. `publish` is fixed to the namespace the
/// Agent granted — an extension's manifest id — while `subscribe` may listen
/// to any namespace. Product code obtains the value from
/// `CompositionView::events`; only Posoco core holds the core publish handle.
pub struct Events {
  priv publish_ : (Event, @types.EventScope?) -> Result[Unit, EventError]
  priv subscribe_ : ((EventEnvelope) -> Unit, EventNamespace?) -> Result[
    Subscription,
    EventError,
  ]
}

///|
/// Framework construction hook. Product code obtains the value through
/// `CompositionView::events` and does not need this constructor.
pub fn Events::from_callbacks(
  publish~ : (Event, @types.EventScope?) -> Result[Unit, EventError],
  subscribe~ : ((EventEnvelope) -> Unit, EventNamespace?) -> Result[
    Subscription,
    EventError,
  ],
) -> Events {
  { publish_: publish, subscribe_: subscribe, }
}

///|
/// Publish one event in the namespace this capability is bound to. `scope`
/// carries session/run/turn attribution when the notification belongs to a
/// run. An extension capability holding a core payload fails with
/// `ReservedEvent`; a closed Agent fails with `Closed`; no listener succeeds
/// with no side effect. A community payload is delivered as published, so it
/// must be immutable data rather than a value the publisher mutates later.
///
/// # Example
/// ```mbt check
/// test {
///   // This fake models the real Agent's reserved-payload rejection.
///   // Extensions receive their capability from CompositionView, not this factory.
///   let events = @events.Events::from_callbacks(
///     publish=fn(event, _scope) {
///       match event {
///         @events.Core(_) => Err(@events.ReservedEvent)
///         _ => Ok(())
///       }
///     },
///     subscribe=fn(_handler, _namespace_) { Err(@events.Closed) },
///   )
///   guard events.publish(@events.Core(TurnStarted)) is Err(ReservedEvent) else {
///     fail("extensions must not publish core notifications")
///   }
/// }
/// ```
pub fn Events::publish(
  self : Events,
  event : Event,
  scope~ : @types.EventScope? = None,
) -> Result[Unit, EventError] {
  (self.publish_)(event, scope)
}

///|
/// Register one synchronous, non-raising listener. Delivery follows
/// registration order; the `namespace_` argument narrows delivery to one
/// namespace, and `None` listens to every namespace including Posoco. A
/// listener added or cancelled inside a delivery batch takes effect from the
/// next batch, and a new listener receives no history.
///
/// # Example
/// ```mbt check
/// test {
///   let seen_filter : Ref[@events.EventNamespace?] = Ref(None)
///   let events = @events.Events::from_callbacks(
///     publish=fn(_event, _scope) { Ok(()) },
///     subscribe=fn(_handler, namespace_) {
///       seen_filter.val = namespace_
///       Ok(@events.Subscription::from_cancel(fn() { () }))
///     },
///   )
///   let subscription = events.subscribe(
///     fn(_envelope) { () },
///     namespace_=Some(@events.Posoco),
///   )
///   guard subscription is Ok(_) else { fail("expected a subscription") }
///   assert_eq(seen_filter.val, Some(@events.Posoco))
/// }
/// ```
pub fn Events::subscribe(
  self : Events,
  handler : (EventEnvelope) -> Unit,
  namespace_~ : EventNamespace? = None,
) -> Result[Subscription, EventError] {
  (self.subscribe_)(handler, namespace_)
}
