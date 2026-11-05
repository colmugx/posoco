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

A capability publishes only in the namespace its owner was granted while
`subscribe` may listen to any namespace. Handlers are synchronous and
non-raising; `cancel` is idempotent and a new listener receives no history.

## One resource per Agent

`EventSystem()` is the host-owned resource behind every capability and
subscription. Create it before the ports and the Agent that will consume it,
then hand the same value to exactly one `Agent(exts~, config~, events~)`:

1. Define an ADT and extend the open `@posoco.Event`.
2. `let system = @posoco.EventSystem()`. While no Agent owns it, the system
   already grants `publisher(owner~)` capabilities and accepts `subscribe`.
3. Give a plain object its `Events` with `system.publisher(owner="status_bar")`.
   The grant is bound to `Extension("status_bar")`, the object needs no
   `Lifecycle`, and the capability stays valid after the Agent takes over.
4. Compose `Agent(exts~, config~, events=system)`. Construction takes exclusive
   ownership before aggregation; a second Agent on the same value is rejected
   and leaves the first Agent working.
5. Extensions can still declare `requires: [@posoco.Capability::Events]` and
   `lifecycle: [self]`, then obtain `view.events()` in `Lifecycle::on_compose`.
   An object that needs to publish earlier can instead receive its capability
   from the host, including before that object's construction.
6. Hosts subscribe with `system.subscribe(handler)` before composition or with
   `agent.subscribe_events(handler)` afterwards, optionally filtering with
   `namespace_=Some(Extension(id))` or `namespace_=Some(Posoco)`. `None` means
   all namespaces.
7. Handle every `Result`, retain the subscription, and call `cancel()` when
   done. After `Agent::shutdown` — or `system.close()` on a system no Agent
   owns — publisher grants, publications and new subscriptions return
   `Err(Closed)`; an extension publishing `Core` returns `Err(ReservedEvent)`.

A failed or cancelled turn does not close the resource. Any composition failure
after takeover does close it and revokes the capabilities already handed out, so
a failed construction never leaves a usable half-composed resource. A closed or
already-owned system is reported with a typed error; it is never reopened,
replaced, or silently handed to a second owner.

```moonbit nocheck
///|
let system = @posoco.EventSystem()
// An untaken system already accepts listeners and grants capabilities.

///|
let subscription = system.subscribe(handler).unwrap()
// `publisher.publish(...)` is tagged Extension("status_bar") from now on,
// including after the Agent takes the resource over.

///|
let publisher = system.publisher(owner="status_bar").unwrap()

///|
let agent = @posoco.Agent(exts~, config~, events=system)
// Retain subscription until its listener is no longer needed, then cancel it.
// `Agent::shutdown` closes the resource; retained capabilities return Closed.
```

`publisher` rejects a blank owner with `Err(InvalidOwner)`, publishing `Core`
returns `Err(ReservedEvent)`, closing an owned resource returns `Err(Owned)`,
and community publication and subscription return `Err(Closed)` after shutdown.
The shared `EventError` describes both capability and resource operations;
it does not give a capability access to resource management. The runnable
end-to-end version of this host flow is
[`examples/quickstart`](../../examples/quickstart/README.md).

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
[cross-package protocol examples](../tests/event_protocol/README.mbt.md), the
[runnable host example](../../examples/quickstart/README.md), and the
[resource and migration contract](MIGRATION.md).

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
