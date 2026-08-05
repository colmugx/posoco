///|
/// The prompt's RunPolicy owns provider options; the pump snapshots and
/// forwards the opaque value into every model effect for that turn.

///|
async test "puppet/call_options_reach_model_effect" {
  let host = FixtureHost([Ok(fixture_stop("done"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let options = Json::object(
    Map::from_array([
      ("temperature", Json::number(0.25)),
      ("max_output_tokens", Json::number(128.0)),
    ]),
  )
  let catalog = fixture_empty_catalog()
  let config = canonical_puppet_config(
    host as &@kernel_exec.HostRuntime,
    catalog,
    journal,
    [],
    [],
    None,
  )
  let puppet = Puppet(config)

  assert_true(
    puppet.prompt({
      run_id: RunId::unchecked("run_call_options"),
      turn_id: TurnId::unchecked("turn_call_options"),
      session_id: SessionId::unchecked("session_call_options"),
      initial_messages: [UserMessage(content=[Text("hello")])],
      operation_id: "operation_call_options",
      policy: fixture_run_policy("fixture-model", options),
    })
    is Accepted(_),
  )
  assert_eq(host.observed_call_options(), [options])
}
