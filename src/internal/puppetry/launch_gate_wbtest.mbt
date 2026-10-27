///|
/// The trusted "provider was never entered" fact is core-owned. A host that
/// invents `NotExecuted` on its own must stay a contract violation, otherwise
/// an ordinary runtime could disguise a business failure as a pre-admission
/// rejection.
priv struct NotExecutedHost {
  model : FixtureHost
}

///|
impl @kernel_exec.HostRuntime for NotExecutedHost with fn call_model(
  self,
  scope,
  messages,
  tools,
  options,
  chunks,
) {
  self.model.call_model(scope, messages, tools, options, chunks)
}

///|
impl @kernel_exec.HostRuntime for NotExecutedHost with fn compact(
  self,
  scope,
  messages,
  tools,
  options,
  trigger,
) {
  self.model.compact(scope, messages, tools, options, trigger)
}

///|
impl @kernel_exec.HostRuntime for NotExecutedHost with fn execute_tool(
  _self,
  _id,
  _owner,
  _call,
  _name,
  _arguments,
  _scope,
) {
  NotExecuted(
    reason=@kernel.NotExecutedReason::UnknownTool,
    original_call_id=@kernel.CallId::unchecked("invented"),
  )
}

///|
impl @kernel_exec.HostRuntime for NotExecutedHost with fn cancel_effects(
  _self,
  run_id~,
  ids,
  _reason,
) {
  let _ = run_id

  ids.map(id => (id, @kernel.CancelDisposition::AlreadySettled))
}

///|
async test "launch_gate/a_host_invented_not_executed_is_still_a_contract_violation" {
  let host = NotExecutedHost::{
    model: FixtureHost(
      [Ok(fixture_tool_calls([fixture_call("echo", "c1")]))],
      Map::from_array([]),
    ),
  }
  let builder = ToolCatalogBuilder()
  ignore(
    builder.add(
      @kernel.ToolDef(
        name=ToolName::unchecked("echo"),
        description="echo",
        input_schema=Json::object(Map::from_array([])),
        owner=OwnerId::unchecked("host"),
        policy=Sequential,
        provenance=None,
        exposure=Direct,
      ),
    ),
  )
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber::RecordingSubscriber("recording")
  let config = canonical_puppet_config(
    host,
    builder.finish(version=CatalogVersion(1)),
    journal,
    [subscriber as &EventSubscriber],
    [],
    None,
  )
  let puppet = Puppet(config)
  // The reducer turns the host's invented rejection into a runtime failure
  // instead of accepting it as a legitimate non-execution.
  match fixture_prompt(puppet, "host_not_executed") {
    Accepted(..) => ()
    other => fail("expected accepted prompt, got " + other.to_string())
  }
  let outcomes : Array[@kernel.ToolOutcome] = []
  for envelope in subscriber.received() {
    match envelope.event() {
      ToolCompleted(outcome~, ..) => outcomes.push(outcome)
      _ => ()
    }
  }
  guard outcomes is [RuntimeFailure(error_category="Parse", message~)] else {
    fail(
      "a host-invented NotExecuted must stay a violation: " +
      outcomes.map(o => o.summary()).join(","),
    )
  }
  assert_true(message.contains("host returned NotExecuted"))
}
