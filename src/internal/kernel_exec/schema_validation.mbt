///|
/// Tool-argument schema validation (ADR §2.7), backed by `colmugx/json-schema`
/// (JSON Schema 2020-12). Schemas compile once at catalog composition: any
/// `Schema::compile` failure is a composition hard failure, and the compiled
/// plan validates every call. Nothing is silently skipped.
///
/// Diagnostic contract (unchanged from the previous subset validator): a
/// `SchemaDiagnostic` reports only a structural JSON path plus schema-side
/// expectations. `Fault.instance_path` is a structural pointer, every
/// `Fault.message` in json-schema 0.1.3 is a fixed category string (only
/// schema-declared names are ever interpolated), and a payload-leak guard
/// test pins this contract.

///|
/// Compile a tool input schema at composition time. Maps compiler failures
/// onto the established composition error surface: unsupported keywords and
/// patterns keep the dedicated `UnsupportedSchemaKeyword` variant; malformed
/// schemas, unknown dialects/vocabularies and depth overruns report as
/// `MalformedSchema`.
fn compile_tool_schema(
  visible_name : String,
  schema : Json,
) -> @json-schema.Schema raise CatalogCompositionError {
  @json-schema.Schema::compile(schema) catch {
    @json-schema.CompileError::UnsupportedKeyword(keyword~, ..) =>
      raise UnsupportedSchemaKeyword(visible_name~, keyword~)
    @json-schema.CompileError::UnsupportedPattern(..) =>
      raise UnsupportedSchemaKeyword(visible_name~, keyword="pattern")
    error =>
      raise MalformedSchema(visible_name~, detail=explain_compile_error(error))
  }
}

///|
fn explain_compile_error(error : @json-schema.CompileError) -> String {
  match error {
    InvalidKeyword(path~, reason~) => "invalid schema at \{path}: \{reason}"
    UnknownDialect(uri) => "unknown schema dialect \{uri}"
    UnsupportedVocabulary(dialect~, vocabulary~) =>
      "unsupported vocabulary \{vocabulary} required by dialect \{dialect}"
    DepthLimit(limit) => "schema exceeds depth limit \{limit}"
    UnsupportedKeyword(path~, keyword~) =>
      "unsupported keyword \{keyword} at \{path}"
    UnsupportedPattern(path~, pattern~, ..) =>
      "unsupported pattern \{pattern} at \{path}"
  }
}

///|
/// Validate arguments against a compiled schema. Returns the first fault as a
/// payload-free diagnostic, or `Ok(())` when the arguments conform.
fn validate_compiled(
  schema : @json-schema.Schema,
  arguments : Json,
) -> Result[Unit, @kernel.SchemaDiagnostic] {
  let faults = schema.faults(arguments) catch {
    error => return Err(evaluation_error_diagnostic(error))
  }
  match faults.get(0) {
    Some(fault) =>
      Err({
        json_path: dollar_path(fault.instance_path),
        expected: "\{fault.keyword} (\{fault.schema_path})",
        actual: fault.message,
      })
    None => Ok(())
  }
}

///|
/// Evaluation-stage failures describe pathological arguments (depth, numeric
/// representation), not compiler defects, so they surface through the same
/// `SchemaDiagnostic` channel as ordinary mismatches.
fn evaluation_error_diagnostic(error : Error) -> @kernel.SchemaDiagnostic {
  match error {
    @json-schema.EvaluationError::DepthLimit(limit) =>
      {
        json_path: "$",
        expected: "arguments within evaluation depth limit",
        actual: "arguments exceed depth \{limit}",
      }
    @json-schema.EvaluationError::InvalidNumber(path~) =>
      {
        json_path: dollar_path(path),
        expected: "representable number",
        actual: "argument is not a representable number",
      }
    _ =>
      {
        json_path: "$",
        expected: "evaluable arguments",
        actual: "arguments failed schema evaluation",
      }
  }
}

///|
fn all_digits(text : String) -> Bool {
  for ch in text {
    if !(ch is ('0'..<='9')) {
      return false
    }
  }
  true
}

///|
/// Convert an RFC 6901 JSON Pointer to the catalog's "$"-rooted path
/// notation ("" → "$", "/a/0" → "$.a[0]"), matching the previous validator's
/// diagnostic format. Escapes (~0/~1) are decoded; property segments render
/// naively, exactly like the previous formatter.
fn dollar_path(pointer : String) -> String {
  if pointer == "" {
    return "$"
  }
  let builder = StringBuilder()
  builder.write_string("$")
  for segment in pointer.split("/") {
    if segment == "" {
      continue
    }
    let decoded = segment
      .replace_all(old="~1", new="/")
      .replace_all(old="~0", new="~")
      .to_owned()
    if all_digits(decoded) {
      builder.write_string("[\{decoded}]")
    } else {
      builder.write_string(".\{decoded}")
    }
  }
  builder.to_string()
}
