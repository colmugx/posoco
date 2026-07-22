///|
/// Focused Harness-pump regression tests using the canonical FixtureHost.

///|
async test "harness/pump_forwards_catalog_definitions_to_host" {
  let host = FixtureHost::new([Ok(fixture_stop("done"))], Map::from_array([]))
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("visible"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "forward_catalog") is Accepted(_))
  assert_eq(host.observed_definition_count(), 1)
}

///|
async test "harness/pump_executes_only_reducer_declared_effects" {
  let host = FixtureHost::new(
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
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("known"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "declared_effects") is Accepted(_))
  // Unknown tools become reducer-owned NotExecuted messages and therefore
  // never cross the HostRuntime execute boundary.
  assert_eq(host.tool_call_count(), 1)
}

///|
async test "harness/pump_releases_lease_after_terminal" {
  let host = FixtureHost::new(
    [Ok(fixture_stop("done")), Ok(fixture_stop("again"))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "lease_first") is Accepted(_))
  assert_true(fixture_prompt(harness, "lease_second") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_true(harness.phase() == Idle)
}
