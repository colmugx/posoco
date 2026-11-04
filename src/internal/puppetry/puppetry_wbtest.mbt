///|
/// Focused Puppet-pump regression tests using the canonical FixtureHost.

// "puppet/pump_forwards_catalog_definitions_to_host" removed: the catalog
// definition count it asserted is already pinned by "puppet/C-SINGLE-TOOL"
// (`host.observed_definition_count() == 1`) in fixture_wbtest.

///|
async test "puppet/pump_executes_only_reducer_declared_effects" {
  let host = FixtureHost(
    [
      Ok(
        fixture_tool_calls([
          fixture_call("known", "known_call"),
          fixture_call("unknown", "unknown_call"),
        ]),
      ),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("known_call", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("known"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "declared_effects") is Accepted(_))
  // Unknown tools become reducer-owned NotExecuted messages and therefore
  // never cross the HostRuntime execute boundary.
  assert_eq(host.tool_call_count(), 1)
}
