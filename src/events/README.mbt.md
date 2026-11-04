# Posoco events

`@events` owns the open `Event` type and the owner-bound `Events` capability.
Posoco publishes core notifications as `Core(TurnEvent)`. A community protocol
package adds its own constructor and keeps a closed payload ADT, so consumers
pattern match with static types: no JSON codec, no downcast, no runtime
registry.

```mbt check
///|
pub(all) enum SprintEvent {
  Started(Int32)
  Finished
}

///|
pub(all) extenum @events.Event += {
  SprintChanged(SprintEvent)
}

///|
test "a community protocol extends the open event type" {
  let event : @events.Event = SprintChanged(Started(3))
  let described = match event {
    SprintChanged(Started(sprint)) => "started #\{sprint}"
    SprintChanged(Finished) => "finished"
    @events.Core(_) => "core notification"
    _ => "another protocol"
  }
  assert_eq(described, "started #3")
}
```

A capability publishes only in the namespace the Agent granted it (an
extension's manifest id) while `subscribe` may listen to any namespace.
Handlers are synchronous and non-raising; `cancel` is idempotent and a new
listener receives no history.

Real extensions declare `Capability::Events` and obtain their capability in
`Lifecycle::on_compose`; hosts use `Agent::subscribe_events`:

1. Define an ADT and extend `@posoco.Event`.
2. Declare `requires: [@posoco.Capability::Events]` and `lifecycle: [self]` in
   the extension manifest.
3. Obtain `view.events()` in `Lifecycle::on_compose`; publish in `on_start` or
   a business method, not during construction.
4. Subscribe with `events.subscribe` (extensions) or `agent.subscribe_events`
   (hosts), optionally filtering with `namespace_=Some(Extension(id))` or
   `namespace_=Some(Posoco)`. `None` means all namespaces.
5. Handle the `Result`, retain the subscription, and call `cancel()` when done.
   After shutdown, new publications/subscriptions return `Err(Closed)`; an
   extension attempting to publish `Core` returns `Err(ReservedEvent)`.

The manifest id binds publishing identity and must be unique for Events users.
`Posoco` is reserved for core notifications, not an extra bus. `Observer` is a
core-only adapter on the same dispatcher; `Hook` remains interception, and
awaited journal/checkpoint commits remain separate from notifications.

For reusable protocols, export the payload ADT and constructor from a protocol
package. The root `@posoco.Event` facade can be extended, but an extenum
constructor must be qualified by its **defining package**, e.g. `@events.Core`
or `@protocol.SprintChanged`, not by a package that only re-exports the type.
Keep a wildcard for the open `Event`; exhaustively match the closed payload.

Delivery uses registration order and a per-batch listener snapshot; reentrant
publications queue rather than recurse. Changes to subscriptions during a batch
apply to the next batch. Use immutable community payloads: they are not deep
copied. `scope` is optional delivery attribution, not a routing filter.

See also the [public API integration tests](../agent_events_test.mbt),
[cross-package protocol examples](../tests/event_protocol/README.mbt.md), and
[composition and migration guide](MIGRATION.md).

The following isolated test uses fake callbacks only to illustrate the listener
shape; `from_callbacks` and envelope construction are framework/test seams, not
steps a product extension needs to perform.

```mbt check
///|
test "subscribe to typed deliveries and cancel" {
  let delivered : Array[String] = []
  let dispatch : Ref[(@events.EventEnvelope) -> Unit] = Ref(fn(_) { () })
  let events = @events.Events::from_callbacks(
    publish=fn(_event, _scope) { Ok(()) },
    subscribe=fn(handler, _namespace_) {
      // A real runtime records the handler and filters by namespace.
      dispatch.val = handler
      Ok(@events.Subscription::from_cancel(fn() { () }))
    },
  )
  let subscription = events.subscribe(fn(envelope) {
    match envelope.event {
      SprintChanged(Started(sprint)) =>
        // The envelope namespace is system-produced delivery metadata.
        match envelope.namespace_of() {
          Extension("sprint") => delivered.push("sprint started #\{sprint}")
          _ => delivered.push("unexpected namespace")
        }
      _ => ()
    }
  })
  guard subscription is Ok(handle) else { fail("expected a subscription") }
  (dispatch.val)(
    @events.EventEnvelope(
      namespace_=@events.Extension("sprint"),
      event=SprintChanged(Started(4)),
    ),
  )
  handle.cancel()
  handle.cancel()
  assert_eq(delivered, ["sprint started #4"])
}
```
