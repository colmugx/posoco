///|
test "runtime/namespace_filter_selects_one_namespace" {
  let runtime = @event_runtime.EventRuntime()
  let all : Array[String] = []
  let posoco : Array[String] = []
  let alpha : Array[String] = []
  ignore(runtime.subscribe(fn(envelope) { all.push(envelope_label(envelope)) }))
  ignore(
    runtime.subscribe(
      fn(envelope) { posoco.push(envelope_label(envelope)) },
      namespace_=Some(@events.EventNamespace::Posoco),
    ),
  )
  ignore(
    runtime.subscribe(
      fn(envelope) { alpha.push(envelope_label(envelope)) },
      namespace_=Some(@events.EventNamespace::Extension("alpha")),
    ),
  )
  let alpha_owner = runtime.capability("alpha")
  let beta_owner = runtime.capability("beta")
  runtime.emit_core(None, TurnStarted)
  ignore(@protocol.publish_sprint(alpha_owner, Started(1)))
  ignore(@protocol.publish_sprint(beta_owner, Started(2)))
  assert_eq(all, ["posoco/TurnStarted", "alpha/started #1", "beta/started #2"])
  assert_eq(posoco, ["posoco/TurnStarted"])
  assert_eq(alpha, ["alpha/started #1"])
}
