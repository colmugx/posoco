///|
/// JSON Schema validator for tool arguments (ADR §2.7).
///
/// Scope: a deliberately small JSON Schema subset. Unknown keywords are
/// rejected at catalog composition time (not silently ignored) so that
/// callers cannot accidentally rely on keywords this validator does not
/// understand. The supported subset covers everything M1 needs to validate
/// tool arguments and is the same subset `CanonicalToolDef.input_schema`
/// is built against.
///
/// Supported schema forms:
/// - `{ "type": "object", "properties": { ... }, "required": [...] }`
/// - `{ "type": "string" }`, `"number"`, `"integer"`, `"boolean"`, `"null"`, `"array"`
/// - `{ "type": "object", "additionalProperties": false }` (only declared properties allowed)
/// - `{ "enum": [ ... ] }` (any JSON value must equal one of the listed values)
/// - `{ "const": <value> }` (must equal the constant exactly)
///
/// Rejected (composition hard failure if encountered in a tool definition):
/// - `$ref`, `$defs`, `allOf`, `anyOf`, `oneOf`, `not`
/// - `pattern`, `format`, `minimum`, `maximum`, `minLength`, `maxLength`,
///   `minItems`, `maxItems`, `multipleOf`
/// - String-encoded union types like `"type": ["string", "null"]`
///
/// The subset is frozen here so behavior is testable. A future adapter
/// (post-M1) may swap this for a fuller validator without changing the
/// contract this module exposes to the reducer.

// ──────────────────────────────────────────────────────────────────────────
// Public entry point
// ──────────────────────────────────────────────────────────────────────────

///|
/// Validate `instance` against `schema`. Returns `Ok(())` on success, or
/// `Err(SchemaDiagnostic)` carrying a safe JSON path + expected/actual pair.
///
/// The diagnostic never includes the raw instance payload — only a JSON path
/// and a type expectation. This is the function the reducer (T03) calls when
/// folding a `ModelCompleted` completion whose tool calls have already
/// parsed.
pub fn validate_arguments(
  schema : Json,
  instance : Json,
) -> Result[Unit, SchemaDiagnostic] {
  validate_at(schema, instance, "$")
}

// ──────────────────────────────────────────────────────────────────────────
// Recursive validator
// ──────────────────────────────────────────────────────────────────────────

///|
fn validate_at(
  schema : Json,
  instance : Json,
  path : String,
) -> Result[Unit, SchemaDiagnostic] {
  match schema {
    Json::Object(_) => validate_object_schema(schema, instance, path)
    Json::True => Ok(()) // JSON Schema "true" = always valid
    Json::False =>
      // JSON Schema "false" = always invalid.
      Err({
        json_path: path,
        expected: "schema=false rejects everything",
        actual: "any value",
      })
    _ =>
      Err({
        json_path: path,
        expected: "schema must be object or boolean",
        actual: schema_kind(schema),
      })
  }
}

///|
fn validate_object_schema(
  schema : Json,
  instance : Json,
  path : String,
) -> Result[Unit, SchemaDiagnostic] {
  // Reject unsupported keywords first.
  match find_unsupported_keyword(schema) {
    Some(keyword) =>
      return Err({
        json_path: path,
        expected: "supported JSON Schema subset only",
        actual: "unsupported keyword: " + keyword,
      })
    None => ()
  }
  // "type" check
  match schema.get("type") {
    Some(type_spec) =>
      match check_type(type_spec, instance) {
        Err(msg) =>
          return Err({
            json_path: path,
            expected: "type " + type_label(type_spec),
            actual: msg,
          })
        Ok(_) => ()
      }
    None => ()
  }
  // "enum" check
  match schema.get("enum") {
    Some(Json::Array(allowed)) =>
      if !array_contains_json(allowed, instance) {
        return Err({
          json_path: path,
          expected: "one of enum values",
          actual: schema_kind(instance),
        })
      }
    Some(_) =>
      return Err({
        json_path: path,
        expected: "enum must be array",
        actual: "non-array enum",
      })
    None => ()
  }
  // "const" check
  match schema.get("const") {
    Some(const_value) =>
      if !json_equal(const_value, instance) {
        return Err({
          json_path: path,
          expected: "const value",
          actual: schema_kind(instance),
        })
      }
    None => ()
  }
  // "properties" + "required" + "additionalProperties" (object instance only)
  match instance {
    Json::Object(_) =>
      match validate_object_props(schema, instance, path) {
        Err(d) => return Err(d)
        Ok(_) => ()
      }
    _ => ()
  }
  // "items" (array instance only)
  match (instance, schema.get("items")) {
    (Json::Array(items), Some(items_schema)) =>
      for i = 0; i < items.length(); i = i + 1 {
        match validate_at(items_schema, items[i], "\{path}[\{i}]") {
          Err(d) => return Err(d)
          Ok(_) => ()
        }
      }
    _ => ()
  }
  Ok(())
}

///|
fn validate_object_props(
  schema : Json,
  instance : Json,
  path : String,
) -> Result[Unit, SchemaDiagnostic] {
  let obj = match instance {
    Json::Object(m) => m
    _ => return Ok(())
  }
  let properties = match schema.get("properties") {
    Some(Json::Object(p)) => p
    _ => Map::from_array([])
  }
  let additional_properties_blocked = match schema.get("additionalProperties") {
    Some(Json::False) => true
    _ => false
  }
  let required = match schema.get("required") {
    Some(Json::Array(arr)) => arr
    _ => []
  }
  for r in required {
    match r {
      Json::String(name) =>
        if !obj.contains(name) {
          return Err({
            json_path: "\{path}.\{name}",
            expected: "required property present",
            actual: "missing",
          })
        }
      _ => ()
    }
  }
  for key in obj.keys() {
    let value = obj[key]
    match properties.get(key) {
      Some(prop_schema) =>
        match validate_at(prop_schema, value, "\{path}.\{key}") {
          Err(d) => return Err(d)
          Ok(_) => ()
        }
      None =>
        if additional_properties_blocked {
          return Err({
            json_path: "\{path}.\{key}",
            expected: "declared property only (additionalProperties=false)",
            actual: "additional property",
          })
        }
    }
  }
  Ok(())
}

// ──────────────────────────────────────────────────────────────────────────
// Type check
// ──────────────────────────────────────────────────────────────────────────

///|
fn check_type(type_spec : Json, instance : Json) -> Result[Unit, String] {
  let type_str = match type_spec {
    Json::String(s) => s
    _ => return Err("type spec must be a string")
  }
  let actual = json_type_name(instance)
  let matches = match type_str {
    "object" => actual == "object"
    "array" => actual == "array"
    "string" => actual == "string"
    "integer" => actual == "integer" // strictly integer-valued numbers only
    "number" => actual == "number" || actual == "integer"
    "boolean" => actual == "boolean"
    "null" => actual == "null"
    _ => return Err("unknown type '\{type_str}'")
  }
  if matches {
    Ok(())
  } else {
    Err("instance is \{actual}, expected \{type_str}")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// JSON helpers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Get a key from a Json object. Returns None for non-objects or missing keys.
fn Json::get(self : Json, key : String) -> Json? {
  match self {
    Json::Object(m) => m.get(key)
    _ => None
  }
}

///|
fn schema_kind(value : Json) -> String {
  json_type_name(value)
}

///|
fn json_type_name(value : Json) -> String {
  match value {
    Json::Null => "null"
    Json::True => "boolean"
    Json::False => "boolean"
    Json::Number(n, ..) => if n == n.floor() { "integer" } else { "number" }
    Json::String(_) => "string"
    Json::Array(_) => "array"
    Json::Object(_) => "object"
  }
}

///|
fn type_label(type_spec : Json) -> String {
  match type_spec {
    Json::String(s) => s
    _ => "(non-string type)"
  }
}

///|
fn json_equal(a : Json, b : Json) -> Bool {
  a == b
}

///|
fn array_contains_json(haystack : Array[Json], needle : Json) -> Bool {
  for v in haystack {
    if v == needle {
      return true
    }
  }
  false
}

// ──────────────────────────────────────────────────────────────────────────
// Unsupported keyword detection
// ──────────────────────────────────────────────────────────────────────────

///|
/// Frozen list of unsupported JSON Schema keywords. Encountering any of these
/// in a tool's input schema (at any nesting depth) is a composition hard
/// failure (ADR §2.7).
let unsupported_keywords : Array[String] = [
  "$ref", "$defs", "definitions", "allOf", "anyOf", "oneOf", "not", "pattern", "format",
  "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
  "minItems", "maxItems", "minProperties", "maxProperties", "multipleOf", "patternProperties",
  "uniqueItems", "dependencies", "dependentRequired", "dependentSchemas", "if", "then",
  "else", "contentEncoding", "contentMediaType",
]

///|
/// Walks the schema (and its nested properties/items) looking for an
/// unsupported keyword. Returns the first keyword found, or None.
fn find_unsupported_keyword(schema : Json) -> String? {
  match schema {
    Json::Object(m) => {
      for k in m.keys() {
        for bad in unsupported_keywords {
          if k == bad {
            return Some(k)
          }
        }
      }
      match m.get("properties") {
        Some(Json::Object(props)) =>
          for key in props.keys() {
            match find_unsupported_keyword(props[key]) {
              Some(b) => return Some(b)
              None => ()
            }
          }
        _ => ()
      }
      match m.get("items") {
        Some(items_schema) =>
          match find_unsupported_keyword(items_schema) {
            Some(b) => return Some(b)
            None => ()
          }
        None => ()
      }
      None
    }
    _ => None
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Schema-shape pre-check (used by T05 catalog builder)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Pre-check a tool's input schema at composition time. Returns Ok(()) if
/// the schema only uses supported keywords; returns Err with the first
/// offending keyword otherwise. This is what the catalog builder (T05)
/// invokes BEFORE attempting any runtime validation — composition hard
/// failure (ADR §2.7).
pub fn check_schema_supported(schema : Json) -> Result[Unit, String] {
  match find_unsupported_keyword(schema) {
    Some(k) => Err(k)
    None => Ok(())
  }
}
