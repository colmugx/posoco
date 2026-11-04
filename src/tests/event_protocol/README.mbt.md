# Typed community events

Posoco delivers core notifications and community events through one
synchronous, Agent-owned runtime. A protocol package contributes its own
constructor to the open `@events.Event` type; nobody edits a core event list,
encodes JSON, or casts at the listener.

Every extension capability is bound to the publishing manifest id: an
extension publishes in its own namespace, may listen to any namespace, and can
never publish a Posoco core notification.

## Declare a typed event in a protocol package

```mbt check
///|
pub(all) extenum @events.Event += {
  SprintMilestone(stage~ : String, done~ : Int32)
}
```

The payload is a normal MoonBit ADT, so a consumer's `match` on it is
exhaustive; only the match on the open `Event` needs a wildcard.

## Publish and listen

```mbt check
///|
test "an extension publishes and a host listens" {
  let seen : Array[String] = []
  let runtime = @event_runtime.EventRuntime([])
  guard runtime.subscribe(fn(envelope) {
      match envelope.event {
        SprintMilestone(stage~, done~) =>
          seen.push(stage + ":" + done.to_string())
        _ => ()
      }
    })
    is Ok(_) else {
    fail("subscribe failed")
  }
  let publisher = runtime.capability("sprint-tools")
  guard publisher.publish(SprintMilestone(stage="build", done=2)) is Ok(_) else {
    fail("publish failed")
  }
  assert_eq(seen, ["build:2"])
}
```

`runtime.capability(owner)` is the value an extension receives from
`CompositionView::events`; the concrete runtime belongs to the Agent.

## Core publication stays reserved, shutdown stays loud

```mbt check
///|
test "an extension capability cannot publish core and dies with the Agent" {
  let runtime = @event_runtime.EventRuntime([])
  let publisher = runtime.capability("sprint-tools")
  guard publisher.publish(@events.Core(TurnStarted))
    is Err(@events.ReservedEvent) else {
    fail("expected ReservedEvent")
  }
  runtime.close()
  guard publisher.publish(SprintMilestone(stage="build", done=0))
    is Err(@events.Closed) else {
    fail("expected Closed")
  }
}
```

`Subscription::cancel` is idempotent, so a host may cancel defensively after
shutdown without knowing whether the Agent already released the listener.
