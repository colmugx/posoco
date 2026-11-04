///|
/// Whitebox tests for the ToolCatalogSnapshot and schema validator.
fn make_def(
  name : String,
  owner : String,
  schema : Json,
  policy : @kernel.ExecutionPolicy,
) -> @kernel.ToolDef {
  ToolDef(
    name=@kernel.ToolName::unchecked(name),
    description="test",
    input_schema=schema,
    owner=@kernel.OwnerId::unchecked(owner),
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
  defs : Array[@kernel.ToolDef],
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  for d in defs {
    let _ = builder.add(d)
  }
  builder.finish(version=CatalogVersion(1))
}

///|
/// Test shim mirroring the production path (compile once, validate against
/// the compiled plan) for direct schema/instance checks. A fixture that does
/// not compile is a test bug and aborts loudly.
fn validate_arguments(
  schema : Json,
  instance : Json,
) -> Result[Unit, @kernel.SchemaDiagnostic] {
  validate_compiled(try! @json-schema.Schema::compile(schema), instance)
}

///|
test "ToolCatalogBuilder: composition-time rejection of malformed schemas" {
  // The compiler rejects malformed keyword values; pattern/keyword
  // rejections keep the dedicated UnsupportedSchemaKeyword variant, so a
  // plain well-formed keyword set now composes (see the validation tests).
  let cases : Array[(String, Json)] = [
    ("required-not-array", { "required": "path" }),
    ("type-unknown", { "type": "octet" }),
    ("properties-not-object", { "properties": 7 }),
  ]
  for case in cases {
    let (label, schema) = case
    let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
      make_snapshot([make_def(label, "owner1", schema, Parallel)]),
    ) catch {
      e => Err(e)
    }
    guard result is Err(MalformedSchema(visible_name~, detail~)) else {
      fail("expected MalformedSchema for \{label}")
    }
    assert_eq(visible_name, label)
    assert_false(detail == "")
  }
}

///|
test "Schema: string type rejects number" {
  let schema = Json::object(Map::from_array([("type", Json::string("string"))]))
  let instance = Json::number(42.0)
  let result = validate_arguments(schema, instance)
  match result {
    Err(d) => {
      assert_true(d.expected.contains("type"))
      assert_true(d.json_path == "$")
    }
    Ok(_) => fail("expected Err for number against string schema")
  }
}

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
      // Required faults report at the owning object; the missing property
      // name is schema-declared and appears in the message.
      assert_true(d.json_path == "$")
      assert_true(d.actual.contains("missing required property: name"))
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

///|
test "Schema: unresolvable $ref is rejected at composition, not validate time" {
  // The compiled validator cannot hold a broken plan: reference resolution
  // happens once, at composition. The old validate-time defensive rejection
  // is subsumed by the composition gate.
  let schema = Json::object(
    Map::from_array([("$ref", Json::string("#/defs/X"))]),
  )
  let result : Result[ToolCatalogSnapshot, CatalogCompositionError] = Ok(
    make_snapshot([make_def("broken_ref", "owner1", schema, Parallel)]),
  ) catch {
    e => Err(e)
  }
  guard result is Err(MalformedSchema(visible_name~, detail~)) else {
    fail("expected MalformedSchema for unresolvable $ref")
  }
  assert_eq(visible_name, "broken_ref")
  assert_false(detail == "")
}
