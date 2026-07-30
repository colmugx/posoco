///|
/// White-box tests for Session lineage helpers (M3.4).

///|
test "Session::parent_thread_id: fresh session has no parent" {
  let s : Session = { messages: [], metadata: Map::from_array([]) }
  assert_true(s.parent_thread_id() is None)
}

///|
test "Session::with_parent_thread_id: round-trips through metadata" {
  let base : Session = {
    messages: [],
    metadata: Map::from_array([("custom", Json::string("preserved"))]),
  }
  let derived = base.with_parent_thread_id("parent-123")
  // Lineage readable.
  assert_eq(derived.parent_thread_id(), Some("parent-123"))
  // Existing metadata preserved.
  assert_eq(derived.metadata.get("custom"), Some(Json::string("preserved")))
  // Base session unchanged.
  assert_true(base.parent_thread_id() is None)
}
