///|
test "core_facts/source_lifecycle_has_no_orphan_and_keeps_referenced" {
  let facts = CoreFacts::CoreFacts()
  ignore(
    facts.hydrate("parent", [@testkit.tk_user_msg("old")], Map::from_array([])),
  )
  ignore(
    facts.admit(
      "parent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-replace",
    ),
  )
  facts.capture_source(
    "run-replace",
    "parent",
    [@testkit.tk_user_msg("old")],
    1,
  )
  facts.finish_run("parent", "run-replace", "replace")
  assert_eq(facts.store.source_snapshots.length(), 0)
  ignore(
    facts.admit(
      "parent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-failure",
    ),
  )
  facts.capture_source(
    "run-failure",
    "parent",
    [@testkit.tk_user_msg("old"), @testkit.tk_user_msg("failed")],
    1,
  )
  facts.finish_run("parent", "run-failure", "failed")
  assert_eq(facts.store.source_snapshots.length(), 0)
  ignore(
    facts.admit(
      "parent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-cancel",
    ),
  )
  facts.capture_source(
    "run-cancel",
    "parent",
    [@testkit.tk_user_msg("old"), @testkit.tk_user_msg("cancelled")],
    1,
  )
  facts.finish_run("parent", "run-cancel", "cancelled")
  assert_eq(facts.store.source_snapshots.length(), 0)
  // A successful fixated child allocates exactly one permanent source.
  ignore(
    facts.admit(
      "parent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-child",
    ),
  )
  facts.capture_source(
    "run-child",
    "parent",
    [@testkit.tk_user_msg("old"), @testkit.tk_user_msg("fixated")],
    1,
  )
  let child = match
    facts.record_new_thread(
      "run-child",
      "parent",
      "child",
      [@testkit.tk_user_msg("child-body")],
      Map::from_array([]),
    ) {
    Ok(_) => "child"
    Err(detail) => fail(detail)
  }
  assert_eq(facts.store.source_snapshots.length(), 1)
  let source_before = facts.read_source(child)
  guard source_before is Some(before) else { fail("expected child source") }
  assert_eq(before.messages.length(), 1)
  // Parent rewrite later cannot retarget the child's pinned source.
  ignore(
    facts.store.rewrite(
      "parent",
      [@testkit.tk_user_msg("parent-rewritten")],
      Map::from_array([]),
    ),
  )
  let after = facts.read_source(child)
  guard after is Some(after) else {
    fail("expected source after parent rewrite")
  }
  assert_eq(after.messages[0], @testkit.tk_user_msg("old"))
  // A failed second child revokes only its own allocation.
  ignore(
    facts.admit(
      "parent",
      [@testkit.tk_user_msg("parent-rewritten")],
      Map::from_array([]),
      [@testkit.tk_user_msg("parent-rewritten")],
      "run-bad",
    ),
  )
  facts.capture_source("run-bad", "parent", [@testkit.tk_user_msg("other")], 2)
  let bad = facts.record_new_thread(
    "run-bad",
    "parent",
    "child-bad",
    [@testkit.tk_user_msg("bad")],
    Map::from_array([]),
  )
  assert_true(bad is Err(_))
  assert_eq(facts.store.source_snapshots.length(), 1)
  let kept = facts.read_source(child)
  guard kept is Some(kept) else { fail("expected the referenced child source") }
  assert_eq(kept.messages[0], @testkit.tk_user_msg("old"))
}

///|
test "core_facts/failed_validation_revokes_allocation" {
  let facts = CoreFacts::CoreFacts()
  ignore(
    facts.hydrate("vparent", [@testkit.tk_user_msg("old")], Map::from_array([])),
  )
  ignore(
    facts.admit(
      "vparent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-v",
    ),
  )
  facts.capture_source(
    "run-v",
    "vparent",
    [@testkit.tk_user_msg("old"), @testkit.tk_user_msg("extra")],
    3,
  )
  let result = facts.record_new_thread(
    "run-v",
    "vparent",
    "vchild",
    [@testkit.tk_user_msg("body")],
    Map::from_array([]),
  )
  assert_true(result is Err(_))
  assert_eq(facts.store.source_snapshots.length(), 0)
}

///|
test "core_facts/child_exists_revokes_allocation" {
  let facts = CoreFacts::CoreFacts()
  ignore(
    facts.hydrate("eparent", [@testkit.tk_user_msg("old")], Map::from_array([])),
  )
  ignore(
    facts.hydrate(
      "echild",
      [@testkit.tk_user_msg("existing")],
      Map::from_array([]),
    ),
  )
  ignore(
    facts.admit(
      "eparent",
      [@testkit.tk_user_msg("old")],
      Map::from_array([]),
      [@testkit.tk_user_msg("old")],
      "run-e",
    ),
  )
  facts.capture_source(
    "run-e",
    "eparent",
    [@testkit.tk_user_msg("old"), @testkit.tk_user_msg("fixated")],
    1,
  )
  let result = facts.record_new_thread(
    "run-e",
    "eparent",
    "echild",
    [@testkit.tk_user_msg("body")],
    Map::from_array([]),
  )
  assert_true(result is Err(_))
  assert_eq(facts.store.source_snapshots.length(), 0)
}
