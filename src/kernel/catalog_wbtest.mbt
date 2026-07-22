///|
/// Whitebox tests for the M1-T05 ToolCatalogSnapshot and schema validator.
///
/// Coverage:
/// - Builder happy path
/// - Composition hard failures: name collision, duplicate provenance,
///   unsupported schema keyword, malformed schema
/// - Snapshot accessors: find, contains, definitions, size
/// - Schema validation: type check, required, additionalProperties, enum,
///   const, items, nested properties, unsupported keyword detection
/// - Unknown-tool handling

// ──────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────

fn make_def(
  name : String,
  owner : String,
  schema : Json,
  policy : ExecutionPolicy,
) -> CanonicalToolDef {
  CanonicalToolDef::new(
    name=ToolName::unchecked(name),
    description="test",
    input_schema=schema,
    owner=OwnerId::unchecked(owner),
    policy~,
    provenance=Some("test-suite"),
  )
}

///|
fn empty_object_schema() -> Json {
  Json::object(Map::from_array([("type", Json::string("object"))]))
}

///|
fn make_snapshot(
  defs : Array[CanonicalToolDef],
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder::new()
  for d in defs {
    let _ = builder.add(d)
  }
  builder.finish(version=CatalogVersion::new(1))
}

// ──────────────────────────────────────────────────────────────────────────
// Builder happy path
// ──────────────────────────────────────────────────────────────────────────

///|
test "ToolCatalogBuilder: empty finish produces empty snapshot" {
  let snapshot = ToolCatalogBuilder::new().finish(
    version=CatalogVersion::new(1),
  )
  assert_eq(snapshot.size(), 0)
  assert_eq(snapshot.version().to_int(), 1)
}

///|
test "ToolCatalogBuilder: add + finish produces ordered entries" {
  let d1 = make_def("tool_a", "owner1", empty_object_schema(), Parallel)
  let d2 = make_def("tool_b", "owner2", empty_object_schema(), Sequential)
  let snapshot = make_snapshot([d1, d2])
  assert_eq(snapshot.size(), 2)
  let entries = snapshot.entries()
  assert_eq(entries[0].position, 0)
  assert_eq(entries[0].definition.name.to_string(), "tool_a")
  assert_eq(entries[1].position, 1)
  assert_eq(entries[1].definition.name.to_string(), "tool_b")
}

// ──────────────────────────────────────────────────────────────────────────
// Composition hard failures
// ──────────────────────────────────────────────────────────────────────────

///|
test "ToolCatalogBuilder: name collision fails" {
  let d1 = make_def("dup", "owner1", empty_object_schema(), Parallel)
  let d2 = make_def("dup", "owner2", empty_object_schema(), Parallel)
  let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
    make_snapshot([d1, d2]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(NameCollision(visible_name~, ..)) => assert_eq(visible_name, "dup")
    _ => fail("expected NameCollision for duplicate name 'dup'")
  }
}

///|
test "ToolCatalogBuilder: unsupported schema keyword fails" {
  let bad_schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("pattern", Json::string(".*")),
    ]),
  )
  let d = make_def("bad", "owner1", bad_schema, Parallel)
  let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
    make_snapshot([d]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(UnsupportedSchemaKeyword(visible_name~, keyword~)) => {
      assert_eq(visible_name, "bad")
      assert_eq(keyword, "pattern")
    }
    _ => fail("expected UnsupportedSchemaKeyword")
  }
}

///|
test "ToolCatalogBuilder: nested unsupported keyword fails" {
  let bad_schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "x",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  ("minLength", Json::number(1.0)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
  let d = make_def("nested_bad", "owner1", bad_schema, Parallel)
  let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
    make_snapshot([d]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(UnsupportedSchemaKeyword(visible_name~, keyword~)) => {
      assert_eq(visible_name, "nested_bad")
      assert_eq(keyword, "minLength")
    }
    _ => fail("expected UnsupportedSchemaKeyword for nested minLength")
  }
}

///|
test "ToolCatalogBuilder: malformed top-level schema fails" {
  let d = make_def("bad", "owner1", Json::string("not-a-schema"), Parallel)
  let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
    make_snapshot([d]),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(MalformedSchema(visible_name~, ..)) => assert_eq(visible_name, "bad")
    _ => fail("expected MalformedSchema for non-object schema")
  }
}

///|
test "ToolCatalogBuilder: cannot add after finish" {
  let result : Result[ToolCatalogBuilder, CatalogCompositionError] = try {
    let b = ToolCatalogBuilder::new()
    let _ = b.finish(version=CatalogVersion::new(1))
    Ok(b.add(make_def("x", "o", empty_object_schema(), Parallel)))
  } catch {
    e => Err(e)
  }
  match result {
    Err(InvalidToolName(detail~)) => assert_true(detail.contains("finished"))
    _ => fail("expected InvalidToolName after finish")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Snapshot accessors
// ──────────────────────────────────────────────────────────────────────────

///|
test "ToolCatalogSnapshot: find by name" {
  let snapshot = make_snapshot([
    make_def("alpha", "owner1", empty_object_schema(), Parallel),
    make_def("beta", "owner2", empty_object_schema(), Sequential),
  ])
  assert_true(snapshot.contains(ToolName::unchecked("alpha")))
  assert_false(snapshot.contains(ToolName::unchecked("missing")))
  match snapshot.find(ToolName::unchecked("beta")) {
    Some(entry) => assert_eq(entry.definition.name.to_string(), "beta")
    None => fail("expected to find 'beta'")
  }
}

///|
test "ToolCatalogSnapshot: definitions in source order" {
  let snapshot = make_snapshot([
    make_def("first", "o", empty_object_schema(), Parallel),
    make_def("second", "o", empty_object_schema(), Parallel),
    make_def("third", "o", empty_object_schema(), Parallel),
  ])
  let defs = snapshot.definitions()
  assert_eq(defs.length(), 3)
  assert_eq(defs[0].name.to_string(), "first")
  assert_eq(defs[2].name.to_string(), "third")
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validator — type checks
// ──────────────────────────────────────────────────────────────────────────

///|
test "Schema: object type matches object instance" {
  let schema = Json::object(Map::from_array([("type", Json::string("object"))]))
  let instance = Json::object(Map::from_array([]))
  let result = validate_arguments(schema, instance)
  match result {
    Ok(_) => ()
    Err(d) => fail("expected Ok for object instance, got \{d.to_string()}")
  }
}

///|
test "Schema: string type rejects number" {
  let schema = Json::object(Map::from_array([("type", Json::string("string"))]))
  let instance = Json::number(42.0)
  let result = validate_arguments(schema, instance)
  match result {
    Err(d) => assert_true(d.expected.contains("string"))
    Ok(_) => fail("expected Err for number against string schema")
  }
}

///|
test "Schema: integer accepts integral number" {
  let schema = Json::object(
    Map::from_array([("type", Json::string("integer"))]),
  )
  let instance = Json::number(42.0)
  let result = validate_arguments(schema, instance)
  match result {
    Ok(_) => ()
    Err(_) => fail("integer should accept 42.0")
  }
}

///|
test "Schema: integer rejects fractional number" {
  let schema = Json::object(
    Map::from_array([("type", Json::string("integer"))]),
  )
  let instance = Json::number(42.5)
  let result = validate_arguments(schema, instance)
  match result {
    Err(_) => ()
    Ok(_) => fail("integer should reject 42.5")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validator — required, additionalProperties
// ──────────────────────────────────────────────────────────────────────────

///|
test "Schema: required missing fails with path" {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "name",
              Json::object(Map::from_array([("type", Json::string("string"))])),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("name")])),
    ]),
  )
  let instance = Json::object(Map::from_array([]))
  let result = validate_arguments(schema, instance)
  match result {
    Err(d) => {
      assert_true(d.json_path.contains("name"))
      assert_true(d.actual.contains("missing"))
    }
    Ok(_) => fail("required missing should fail")
  }
}

///|
test "Schema: additionalProperties=false rejects extra keys" {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "x",
              Json::object(Map::from_array([("type", Json::string("string"))])),
            ),
          ]),
        ),
      ),
      ("additionalProperties", Json::boolean(false)),
    ]),
  )
  let instance = Json::object(
    Map::from_array([("x", Json::string("ok")), ("y", Json::string("extra"))]),
  )
  let result = validate_arguments(schema, instance)
  match result {
    Err(d) => assert_true(d.json_path.contains("y"))
    Ok(_) => fail("additionalProperties=false should reject 'y'")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validator — enum, const
// ──────────────────────────────────────────────────────────────────────────

///|
test "Schema: enum accepts matching value" {
  let schema = Json::object(
    Map::from_array([
      ("enum", Json::array([Json::string("a"), Json::string("b")])),
    ]),
  )
  let instance = Json::string("b")
  let result = validate_arguments(schema, instance)
  match result {
    Ok(_) => ()
    Err(_) => fail("enum should accept 'b'")
  }
}

///|
test "Schema: enum rejects non-matching value" {
  let schema = Json::object(
    Map::from_array([
      ("enum", Json::array([Json::string("a"), Json::string("b")])),
    ]),
  )
  let instance = Json::string("c")
  let result = validate_arguments(schema, instance)
  match result {
    Err(_) => ()
    Ok(_) => fail("enum should reject 'c'")
  }
}

///|
test "Schema: const matches exactly" {
  let schema = Json::object(Map::from_array([("const", Json::number(42.0))]))
  let result_ok = validate_arguments(schema, Json::number(42.0))
  match result_ok {
    Ok(_) => ()
    Err(_) => fail("const should accept 42")
  }
  let result_bad = validate_arguments(schema, Json::number(43.0))
  match result_bad {
    Err(_) => ()
    Ok(_) => fail("const should reject 43")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validator — array items
// ──────────────────────────────────────────────────────────────────────────

///|
test "Schema: items validates each array element" {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("array")),
      (
        "items",
        Json::object(Map::from_array([("type", Json::string("string"))])),
      ),
    ]),
  )
  let ok_instance = Json::array([Json::string("a"), Json::string("b")])
  match validate_arguments(schema, ok_instance) {
    Ok(_) => ()
    Err(_) => fail("items should accept array of strings")
  }
  let bad_instance = Json::array([Json::string("a"), Json::number(1.0)])
  match validate_arguments(schema, bad_instance) {
    Err(d) => assert_true(d.json_path.contains("[1]"))
    Ok(_) => fail("items should reject mixed array")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validator — unsupported keyword at instance validation
// ──────────────────────────────────────────────────────────────────────────

///|
test "Schema: unsupported keyword produces diagnostic even at validate time" {
  // Schema with $ref should be rejected by the validator even if it slipped
  // past composition (defensive).
  let schema = Json::object(
    Map::from_array([("$ref", Json::string("#/defs/X"))]),
  )
  let instance = Json::object(Map::from_array([]))
  let result = validate_arguments(schema, instance)
  match result {
    Err(d) =>
      assert_true(d.actual.contains("$ref") || d.expected.contains("supported"))
    Ok(_) => fail("validator should reject unsupported keyword")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Catalog.validate_arguments
// ──────────────────────────────────────────────────────────────────────────

///|
test "Catalog: validate_arguments against known tool" {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "path",
              Json::object(Map::from_array([("type", Json::string("string"))])),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("path")])),
    ]),
  )
  let snapshot = make_snapshot([
    make_def("read_file", "owner1", schema, Sequential),
  ])
  let ok = snapshot.validate_arguments(
    ToolName::unchecked("read_file"),
    Json::object(Map::from_array([("path", Json::string("/tmp/x"))])),
  )
  match ok {
    Ok(_) => ()
    Err(_) => fail("validate_arguments should accept valid args")
  }
  let bad = snapshot.validate_arguments(
    ToolName::unchecked("read_file"),
    Json::object(Map::from_array([])),
  )
  match bad {
    Err(_) => ()
    Ok(_) => fail("validate_arguments should reject missing required 'path'")
  }
}

///|
test "Catalog: validate_arguments against unknown tool" {
  let snapshot = make_snapshot([
    make_def("known", "owner1", empty_object_schema(), Parallel),
  ])
  let result = snapshot.validate_arguments(
    ToolName::unchecked("unknown"),
    Json::null(),
  )
  match result {
    Err(d) => assert_true(d.actual.contains("unknown tool"))
    Ok(_) => fail("unknown tool should produce Err")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Dynamic refresh invariant: same snapshot returned twice is stable
// ──────────────────────────────────────────────────────────────────────────

///|
test "Catalog: same version always yields same definitions" {
  let snapshot = make_snapshot([
    make_def("alpha", "owner1", empty_object_schema(), Parallel),
  ])
  let d1 = snapshot.definitions()
  let d2 = snapshot.definitions()
  assert_eq(d1.length(), d2.length())
  assert_eq(d1[0].name.to_string(), d2[0].name.to_string())
}
