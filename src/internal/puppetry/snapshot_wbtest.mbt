///|
/// Whitebox tests for TurnSnapshot.

///|
fn snapshot_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  let _ = builder.add(
    ToolDef(
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
  builder.finish(version=CatalogVersion(1))
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
    policy: {
      model_id,
      call_options: options,
      budget,
      context_window: None,
      compact_threshold: 0.9,
    },
    deadline: None,
    hook_provenance: ["hook_a"],
    lifecycle_provenance: ["lc_a"],
    subscriber_provenance: ["sub_a"],
  }
}

///|
test "puppet_snapshot/redacted_view_excludes_options_payload" {
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
