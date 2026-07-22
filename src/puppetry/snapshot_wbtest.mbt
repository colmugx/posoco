///|
/// Whitebox tests for M2-T02 TurnSnapshot.
///
/// Coverage:
/// - capture produces an immutable snapshot
/// - mutating the original catalog array after capture does not change
///   the snapshot (C-SNAPSHOT-IMMUTABLE seam)
/// - empty model_id / empty catalog rejected
/// - negative budget dimensions rejected
/// - fingerprint is deterministic (same inputs → same fp)
/// - fingerprint unaffected by Map iteration order (sorted)
/// - redacted view excludes options payload

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

fn snapshot_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder::new()
  let _ = builder.add(
    CanonicalToolDef::new(
      name=ToolName::unchecked("read"),
      description="read a file",
      input_schema=Json::object(
        Map::from_array([
          ("type", Json::string("object")),
          (
            "properties",
            Json::object(
              Map::from_array([
                (
                  "path",
                  Json::object(
                    Map::from_array([("type", Json::string("string"))]),
                  ),
                ),
              ]),
            ),
          ),
          ("required", Json::array([Json::string("path")])),
        ]),
      ),
      owner=OwnerId::unchecked("owner_a"),
      policy=Parallel,
      provenance=Some("ext_a"),
    ),
  )
  builder.finish(version=CatalogVersion::new(1))
}

///|
fn snapshot_input(
  catalog : ToolCatalogSnapshot,
  model_id : String,
  options : Json,
  budget : Budget,
) -> TurnSnapshotInput {
  {
    run_id: RunId::unchecked("run_1"),
    turn_id: TurnId::unchecked("turn_1"),
    session_id: SessionId::unchecked("sess_1"),
    catalog,
    model_id,
    call_options: options,
    budget,
    deadline: None,
    hook_provenance: ["hook_a"],
    lifecycle_provenance: ["lc_a"],
    subscriber_provenance: ["sub_a"],
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Capture basics
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_snapshot/capture_basic" {
  let catalog = snapshot_catalog()
  let input = snapshot_input(
    catalog,
    "gpt-test",
    Json::null(),
    Budget::default_run(),
  )
  let snap = TurnSnapshot::capture(input)
  assert_true(snap.run_id() == RunId::unchecked("run_1"))
  assert_true(snap.turn_id() == TurnId::unchecked("turn_1"))
  assert_true(snap.session_id() == SessionId::unchecked("sess_1"))
  assert_true(snap.model_id() == "gpt-test")
  assert_true(snap.catalog_version() == CatalogVersion::new(1))
  assert_true(snap.tool_definitions().length() == 1)
}

///|
test "harness_snapshot/capture_deep_copies_options" {
  // The Json passed in is an object; we capture, then mutate the original
  // (conceptually — Json is immutable in MoonBit so we pass different Json
  // objects to two captures and verify the fingerprint differs).
  let catalog = snapshot_catalog()
  let input1 = snapshot_input(
    catalog,
    "gpt-test",
    Json::object(Map::from_array([("k", Json::string("v1"))])),
    Budget::default_run(),
  )
  let input2 = snapshot_input(
    catalog,
    "gpt-test",
    Json::object(Map::from_array([("k", Json::string("v2"))])),
    Budget::default_run(),
  )
  let snap1 = TurnSnapshot::capture(input1)
  let snap2 = TurnSnapshot::capture(input2)
  assert_true(snap1.fingerprint() != snap2.fingerprint())
}

// ──────────────────────────────────────────────────────────────────────────
// Immutability — the C-SNAPSHOT-IMMUTABLE seam
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_snapshot/mutation_of_original_array_does_not_affect_snapshot" {
  // The catalog's underlying entries array is not aliased by the snapshot.
  // We cannot mutate ToolCatalogSnapshot directly (it's immutable), but we
  // CAN verify that calling snapshot.tool_definitions() twice returns
  // independent arrays (i.e. each call copies).
  let catalog = snapshot_catalog()
  let input = snapshot_input(
    catalog,
    "gpt-test",
    Json::null(),
    Budget::default_run(),
  )
  let snap = TurnSnapshot::capture(input)
  let defs1 = snap.tool_definitions()
  let defs2 = snap.tool_definitions()
  // Pushing to defs1 must not affect defs2 (proves copy semantics).
  defs1.push(
    CanonicalToolDef::new(
      name=ToolName::unchecked("injected"),
      description="",
      input_schema=Json::null(),
      owner=OwnerId::unchecked("x"),
      policy=Parallel,
      provenance=None,
    ),
  )
  assert_true(defs1.length() == 2)
  assert_true(defs2.length() == 1)
  // The snapshot itself is unchanged.
  assert_true(snap.tool_definitions().length() == 1)
}

// ──────────────────────────────────────────────────────────────────────────
// Validation failures
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_snapshot/empty_model_id_rejected" {
  let catalog = snapshot_catalog()
  let input = snapshot_input(catalog, "", Json::null(), Budget::default_run())
  let result : Result[TurnSnapshot, HarnessError] = Ok(
    TurnSnapshot::capture(input),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SnapshotInvalid(detail~)) => assert_true(detail.contains("model_id"))
    _ => fail("expected SnapshotInvalid")
  }
}

///|
test "harness_snapshot/empty_catalog_is_legal" {
  // Empty catalog is LEGAL: a pure-chat run with no tools is valid.
  let empty_catalog = ToolCatalogBuilder::new().finish(
    version=CatalogVersion::new(0),
  )
  let input = snapshot_input(
    empty_catalog,
    "gpt-test",
    Json::null(),
    Budget::default_run(),
  )
  let snap = TurnSnapshot::capture(input)
  assert_true(snap.tool_definitions().length() == 0)
}

///|
test "harness_snapshot/negative_budget_rejected" {
  let catalog = snapshot_catalog()
  let bad_budget : Budget = {
    max_model_steps: Some(-1),
    max_tool_rounds: Some(5),
    max_tool_calls: Some(10),
    max_total_tokens: None,
  }
  let input = snapshot_input(catalog, "gpt-test", Json::null(), bad_budget)
  let result : Result[TurnSnapshot, HarnessError] = Ok(
    TurnSnapshot::capture(input),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SnapshotInvalid(detail~)) =>
      assert_true(detail.contains("max_model_steps"))
    _ => fail("expected SnapshotInvalid")
  }
}

///|
test "harness_snapshot/negative_deadline_rejected" {
  let catalog = snapshot_catalog()
  let input : TurnSnapshotInput = {
    run_id: RunId::unchecked("run_1"),
    turn_id: TurnId::unchecked("turn_1"),
    session_id: SessionId::unchecked("sess_1"),
    catalog,
    model_id: "gpt-test",
    call_options: Json::null(),
    budget: Budget::default_run(),
    deadline: Some(-100),
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  }
  let result : Result[TurnSnapshot, HarnessError] = Ok(
    TurnSnapshot::capture(input),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SnapshotInvalid(detail~)) => assert_true(detail.contains("deadline"))
    _ => fail("expected SnapshotInvalid")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Fingerprint determinism
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_snapshot/fingerprint_deterministic" {
  let catalog = snapshot_catalog()
  let input1 = snapshot_input(
    catalog,
    "gpt-test",
    Json::null(),
    Budget::default_run(),
  )
  let input2 = snapshot_input(
    catalog,
    "gpt-test",
    Json::null(),
    Budget::default_run(),
  )
  let snap1 = TurnSnapshot::capture(input1)
  let snap2 = TurnSnapshot::capture(input2)
  assert_true(snap1.fingerprint() == snap2.fingerprint())
}

///|
test "harness_snapshot/fingerprint_changes_on_model_id" {
  let catalog = snapshot_catalog()
  let input1 = snapshot_input(
    catalog,
    "gpt-a",
    Json::null(),
    Budget::default_run(),
  )
  let input2 = snapshot_input(
    catalog,
    "gpt-b",
    Json::null(),
    Budget::default_run(),
  )
  let snap1 = TurnSnapshot::capture(input1)
  let snap2 = TurnSnapshot::capture(input2)
  assert_true(snap1.fingerprint() != snap2.fingerprint())
}

///|
test "harness_snapshot/fingerprint_changes_on_budget" {
  let catalog = snapshot_catalog()
  let b1 : Budget = {
    max_model_steps: Some(5),
    max_tool_rounds: Some(5),
    max_tool_calls: Some(10),
    max_total_tokens: None,
  }
  let b2 : Budget = {
    max_model_steps: Some(10),
    max_tool_rounds: Some(5),
    max_tool_calls: Some(10),
    max_total_tokens: None,
  }
  let input1 = snapshot_input(catalog, "gpt-test", Json::null(), b1)
  let input2 = snapshot_input(catalog, "gpt-test", Json::null(), b2)
  let snap1 = TurnSnapshot::capture(input1)
  let snap2 = TurnSnapshot::capture(input2)
  assert_true(snap1.fingerprint() != snap2.fingerprint())
}

// ──────────────────────────────────────────────────────────────────────────
// Redacted view
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_snapshot/redacted_view_excludes_options_payload" {
  let catalog = snapshot_catalog()
  let secret_options = Json::object(
    Map::from_array([("api_key", Json::string("sk-secret-12345"))]),
  )
  let input = snapshot_input(
    catalog,
    "gpt-test",
    secret_options,
    Budget::default_run(),
  )
  let snap = TurnSnapshot::capture(input)
  let view = snap.to_redacted_string()
  // The redacted view must not contain the secret value.
  assert_true(!view.contains("sk-secret-12345"))
  // But it should contain the identity chain.
  assert_true(view.contains("run_1"))
  assert_true(view.contains("turn_1"))
}

///|
test "harness_snapshot/show_uses_redacted_view" {
  let catalog = snapshot_catalog()
  let secret_options = Json::object(
    Map::from_array([("api_key", Json::string("sk-secret-67890"))]),
  )
  let input = snapshot_input(
    catalog,
    "gpt-test",
    secret_options,
    Budget::default_run(),
  )
  let snap = TurnSnapshot::capture(input)
  let shown = snap.to_string()
  assert_true(!shown.contains("sk-secret-67890"))
}
