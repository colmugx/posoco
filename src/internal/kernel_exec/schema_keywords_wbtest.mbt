///|
/// Keyword-matrix tests for the compiled JSON Schema validator
/// (colmugx/json-schema 0.1.3) behind the catalog contract. These pin the
/// formerly-rejected keywords (`oneOf`, `anyOf`, `allOf`, `$ref`, `pattern`,
/// `minimum`, …) as composed-and-enforced — the guarantee extension-side
/// schema debts rely on — plus the payload-leak guard for diagnostics.

///|
test "Schema: oneOf enforces exactly-one branch" {
  let schema = Json::object(
    Map::from_array([
      (
        "oneOf",
        Json::array([
          Json::object(
            Map::from_array([("required", Json::array([Json::string("code")]))]),
          ),
          Json::object(
            Map::from_array([
              ("required", Json::array([Json::string("source")])),
            ]),
          ),
        ]),
      ),
    ]),
  )
  guard validate_arguments(schema, { "code": "x" }) is Ok(_) else {
    fail("exactly one branch must pass")
  }
  guard validate_arguments(schema, { "source": "y" }) is Ok(_) else {
    fail("the other single branch must pass")
  }
  guard validate_arguments(schema, { "code": "x", "source": "y" }) is Err(_) else {
    fail("both branches matching must fail oneOf")
  }
  guard validate_arguments(schema, {}) is Err(_) else {
    fail("no branch matching must fail oneOf")
  }
}

///|
test "Schema: anyOf and allOf enforce union and intersection" {
  let any = Json::object(
    Map::from_array([
      (
        "anyOf",
        Json::array([
          { "type": Json::string("string") },
          { "type": Json::string("number") },
        ]),
      ),
    ]),
  )
  guard validate_arguments(any, Json::string("s")) is Ok(_) else {
    fail("anyOf string branch")
  }
  guard validate_arguments(any, Json::number(1.0)) is Ok(_) else {
    fail("anyOf number branch")
  }
  guard validate_arguments(any, Json::boolean(true)) is Err(_) else {
    fail("anyOf must reject unlisted type")
  }
  let all = Json::object(
    Map::from_array([
      (
        "allOf",
        Json::array([
          { "type": Json::string("string") },
          Json::object(Map::from_array([("minLength", Json::number(2.0))])),
        ]),
      ),
    ]),
  )
  guard validate_arguments(all, Json::string("abc")) is Ok(_) else {
    fail("allOf satisfied")
  }
  guard validate_arguments(all, Json::string("a")) is Err(_) else {
    fail("allOf minLength violation must fail")
  }
}

///|
test "Schema: $ref, pattern, and numeric bounds compose and enforce" {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "name",
              Json::object(
                Map::from_array([("$ref", Json::string("#/$defs/nonempty"))]),
              ),
            ),
            (
              "count",
              Json::object(
                Map::from_array([
                  ("type", Json::string("integer")),
                  ("minimum", Json::number(1.0)),
                  ("maximum", Json::number(10.0)),
                ]),
              ),
            ),
          ]),
        ),
      ),
      (
        "$defs",
        Json::object(
          Map::from_array([
            (
              "nonempty",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  ("pattern", Json::string("^[a-z]+$")),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
  guard validate_arguments(schema, { "name": "abc", "count": 3 }) is Ok(_) else {
    fail("conforming arguments must pass")
  }
  guard validate_arguments(schema, { "name": "ABC", "count": 3 }) is Err(_) else {
    fail("pattern violation must fail")
  }
  guard validate_arguments(schema, { "name": "abc", "count": 0 }) is Err(_) else {
    fail("minimum violation must fail")
  }
  guard validate_arguments(schema, { "name": "abc", "count": 2.5 }) is Err(_) else {
    fail("integer violation must fail")
  }
}

///|
test "Schema: diagnostics never leak argument payloads" {
  // Marker values appear only in the instance, never in the schema. Every
  // diagnostic field must stay payload-free (domain_tool.md contract).
  let marker = "SECRET_MARKER_PAYLOAD_7f3a"
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            ("path", { "type": Json::string("string") }),
            (
              "mode",
              Json::object(Map::from_array([("const", Json::string("rw"))])),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("path")])),
      ("additionalProperties", Json::boolean(false)),
    ]),
  )
  let bad_instances : Array[Json] = [
    {},
    { "path": 42 },
    { "mode": "rw" },
    { "path": "ok", "mode": "rw", "extra": marker },
    { "path": true, "mode": marker },
  ]
  for instance in bad_instances {
    guard validate_arguments(schema, instance) is Err(diag) else {
      fail("expected rejection")
    }
    let rendered = diag.to_string()
    guard !rendered.contains(marker) else {
      fail("diagnostic leaked argument payload: \{rendered}")
    }
  }
  // Conforming arguments pass — including an argument value equal to the
  // marker, which must not trip any diagnostic path at all.
  guard validate_arguments(schema, { "path": marker, "mode": "rw" }) is Ok(_) else {
    fail("conforming arguments must pass")
  }
  guard validate_arguments(schema, { "path": "ok", "mode": "rw" }) is Ok(_) else {
    fail("conforming arguments must pass")
  }
}
