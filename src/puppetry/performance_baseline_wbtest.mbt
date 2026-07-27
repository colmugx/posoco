///|
/// Scripted operation-count baselines for Lean Puppetry.
///
/// These are deliberately clock-free. Fixed-runner wall-clock measurement is
/// separate; this fixture prevents structural regressions while the pump is
/// made long-lived, wave-aware, and boundary-batched.

///|
async test "puppet/BASELINE-NO-TOOLS-COUNTERS" {
  let host = FixtureHost([Ok(fixture_stop("done"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )

  assert_true(fixture_prompt(puppet, "baseline_no_tools") is Accepted(_))
  assert_eq(host.model_call_count(), 1)
  assert_eq(host.tool_call_count(), 0)
  assert_eq(journal.append_count(), 2)
}

///|
async test "puppet/BASELINE-ONE-TOOL-COUNTERS" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "one")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("one", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )

  assert_true(fixture_prompt(puppet, "baseline_one_tool") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 1)
  assert_eq(journal.append_count(), 4)
}

///|
async test "puppet/BASELINE-FOUR-TOOL-COUNTERS" {
  let host = FixtureHost(
    [
      Ok(
        fixture_tool_calls([
          fixture_call("echo", "one"),
          fixture_call("echo", "two"),
          fixture_call("echo", "three"),
          fixture_call("echo", "four"),
        ]),
      ),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("one", Success(content="one", structured=None)),
      ("two", Success(content="two", structured=None)),
      ("three", Success(content="three", structured=None)),
      ("four", Success(content="four", structured=None)),
    ]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )

  assert_true(fixture_prompt(puppet, "baseline_four_tools") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 4)
  assert_eq(journal.append_count(), 7)
}
