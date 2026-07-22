///|
/// Whitebox tests for the M1-T06 deterministic ToolScheduler.

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

fn make_catalog(
  defs : Array[(String, ExecutionPolicy)],
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder::new()
  for pair in defs {
    let (name, policy) = pair
    let _ = builder.add(
      CanonicalToolDef::new(
        name=ToolName::unchecked(name),
        description="test",
        input_schema=Json::object(
          Map::from_array([("type", Json::string("object"))]),
        ),
        owner=OwnerId::unchecked("owner1"),
        policy~,
        provenance=Some("test"),
      ),
    )
  }
  builder.finish(version=CatalogVersion::new(1))
}

///|
fn make_call(call_id : String, name : String) -> CanonicalToolCall {
  {
    call_id: CallId::unchecked(call_id),
    name: ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Happy paths
// ──────────────────────────────────────────────────────────────────────────

///|
test "Scheduler: empty calls produces empty plan" {
  let catalog = make_catalog([("a", Parallel)])
  let plan = schedule(catalog, CatalogVersion::new(1), [])
  assert_eq(plan.wave_count(), 0)
  assert_eq(plan.total_calls(), 0)
}

///|
test "Scheduler: single Parallel call → 1 wave" {
  let catalog = make_catalog([("a", Parallel)])
  let plan = schedule(catalog, CatalogVersion::new(1), [make_call("c1", "a")])
  assert_eq(plan.wave_count(), 1)
  assert_eq(plan.total_calls(), 1)
}

///|
test "Scheduler: P/P/P → 1 wave of 3" {
  let catalog = make_catalog([("a", Parallel), ("b", Parallel), ("c", Parallel)])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("c1", "a"),
    make_call("c2", "b"),
    make_call("c3", "c"),
  ])
  assert_eq(plan.wave_count(), 1)
  assert_eq(plan.waves()[0].calls.length(), 3)
  // Source order preserved inside wave
  assert_eq(plan.waves()[0].calls[0].call_id.to_string(), "c1")
  assert_eq(plan.waves()[0].calls[2].call_id.to_string(), "c3")
}

///|
test "Scheduler: S/P/S → 3 single-element waves" {
  let catalog = make_catalog([
    ("a", Sequential),
    ("b", Parallel),
    ("c", Sequential),
  ])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("c1", "a"),
    make_call("c2", "b"),
    make_call("c3", "c"),
  ])
  assert_eq(plan.wave_count(), 3)
  for w in plan.waves() {
    assert_eq(w.calls.length(), 1)
  }
}

///|
test "Scheduler: P/E/P → 3 waves, Exclusive alone" {
  let catalog = make_catalog([
    ("a", Parallel),
    ("b", Exclusive),
    ("c", Parallel),
  ])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("c1", "a"),
    make_call("c2", "b"),
    make_call("c3", "c"),
  ])
  assert_eq(plan.wave_count(), 3)
  // Wave 0: just c1 (Parallel before Exclusive forms a wave boundary)
  assert_eq(plan.waves()[0].calls.length(), 1)
  assert_eq(plan.waves()[0].calls[0].call_id.to_string(), "c1")
  // Wave 1: just c2 (Exclusive alone)
  assert_eq(plan.waves()[1].calls.length(), 1)
  assert_eq(plan.waves()[1].calls[0].call_id.to_string(), "c2")
  // Wave 2: just c3
  assert_eq(plan.waves()[2].calls.length(), 1)
}

///|
test "Scheduler: E/E forms two separate waves" {
  let catalog = make_catalog([("a", Exclusive), ("b", Exclusive)])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("c1", "a"),
    make_call("c2", "b"),
  ])
  assert_eq(plan.wave_count(), 2)
  assert_eq(plan.waves()[0].calls[0].call_id.to_string(), "c1")
  assert_eq(plan.waves()[1].calls[0].call_id.to_string(), "c2")
}

// ──────────────────────────────────────────────────────────────────────────
// Invariant failures
// ──────────────────────────────────────────────────────────────────────────

///|
test "Scheduler: duplicate call_id raises" {
  let catalog = make_catalog([("a", Parallel)])
  let result : Result[ExecutionPlan, SchedulingError] = Ok(
    schedule(catalog, CatalogVersion::new(1), [
      make_call("dup", "a"),
      make_call("dup", "a"),
    ]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(DuplicateCallId(call_id~)) => assert_eq(call_id.to_string(), "dup")
    _ => fail("expected DuplicateCallId")
  }
}

///|
test "Scheduler: unknown tool reaching scheduler raises" {
  let catalog = make_catalog([("a", Parallel)])
  let result : Result[ExecutionPlan, SchedulingError] = Ok(
    schedule(catalog, CatalogVersion::new(1), [make_call("c1", "missing")]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(UnknownToolReachedScheduler(name~, ..)) =>
      assert_eq(name.to_string(), "missing")
    _ => fail("expected UnknownToolReachedScheduler")
  }
}

///|
test "Scheduler: stale snapshot version raises" {
  let catalog = make_catalog([("a", Parallel)])
  let result : Result[ExecutionPlan, SchedulingError] = Ok(
    schedule(catalog, CatalogVersion::new(99), [make_call("c1", "a")]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(StaleSnapshotVersion(expected~, ..)) => assert_eq(expected.to_int(), 99)
    _ => fail("expected StaleSnapshotVersion")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Trace (sanitised output)
// ──────────────────────────────────────────────────────────────────────────

///|
test "Scheduler: trace excludes arguments" {
  let catalog = make_catalog([("a", Parallel), ("b", Exclusive)])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("c1", "a"),
    make_call("c2", "b"),
  ])
  let trace = plan.trace()
  assert_true(trace.contains("c1"))
  assert_true(trace.contains("c2"))
  assert_true(trace.contains("Parallel"))
  assert_true(trace.contains("Exclusive"))
  // Arguments must NOT appear in trace
  // (the call has no arguments in this test, but the trace format itself
  // must be just id:name:policy — assert no JSON braces inside wave elements)
  // The wave delimiters `{` `}` are OK; what we forbid is the JSON arguments
  // payload that might leak from a poorly-written trace.
  assert_false(trace.contains("arguments"))
  assert_false(trace.contains("schema"))
}

// ──────────────────────────────────────────────────────────────────────────
// Source-order preservation
// ──────────────────────────────────────────────────────────────────────────

///|
test "Scheduler: source order preserved within parallel wave" {
  let catalog = make_catalog([
    ("a", Parallel),
    ("b", Parallel),
    ("c", Parallel),
    ("d", Parallel),
  ])
  let plan = schedule(catalog, CatalogVersion::new(1), [
    make_call("z", "a"),
    make_call("y", "b"),
    make_call("x", "c"),
    make_call("w", "d"),
  ])
  let wave = plan.waves()[0]
  assert_eq(wave.calls[0].call_id.to_string(), "z")
  assert_eq(wave.calls[1].call_id.to_string(), "y")
  assert_eq(wave.calls[2].call_id.to_string(), "x")
  assert_eq(wave.calls[3].call_id.to_string(), "w")
}
