///|
test "protocol/community_adt_travels_typed_across_packages" {
  let runtime = @event_runtime.EventRuntime()
  let started : Array[Int32] = []
  let blocked : Array[String] = []
  let scoped : Array[(@types.EventScope?, String)] = []
  ignore(
    runtime.subscribe(fn(envelope) {
      match envelope.event {
        @protocol.SprintChanged(sprint) => {
          scoped.push((envelope.scope, sprint.describe()))
          // The payload is a plain enum from the protocol package: the match
          // is exhaustive without a wildcard inside the business ADT.
          match sprint {
            Started(sprint_no) => started.push(sprint_no)
            Blocked(reason~) => blocked.push(reason)
            Finished => ()
          }
        }
        _ => abort("expected a sprint protocol event")
      }
    }),
  )
  let ext = runtime.capability("sprints")
  let scope = test_scope("session-1", "run-1", "turn-1")
  guard @protocol.publish_sprint(ext, Started(7), scope=Some(scope)) is Ok(_) else {
    fail("protocol publish failed")
  }
  ignore(@protocol.publish_sprint(ext, Blocked(reason="review pending")))
  assert_eq(started, [7])
  assert_eq(blocked, ["review pending"])
  assert_eq(scoped, [
    (Some(scope), "started #7"),
    (None, "blocked: review pending"),
  ])
}
