///|

///|
fn compile_tool_schema(
  visible_name : String,
  schema : Json,
) -> @json-schema.Schema raise CatalogCompositionError {
  @json-schema.Schema::compile(schema) catch {
    UnsupportedKeyword(keyword~, ..) =>
      raise UnsupportedSchemaKeyword(visible_name~, keyword~)
    UnsupportedPattern(..) =>
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
    NumericBudget(path~) => "numeric budget \{path}"
  }
}

///|
fn validate_compiled(
  schema : @json-schema.Schema,
  arguments : Json,
) -> Result[Unit, @kernel.SchemaDiagnostic] {
  let faults = schema.faults(arguments) catch {
    error => return Err(evaluation_error_diagnostic(error))
  }
  match faults {
    [fault, ..] =>
      Err({
        json_path: dollar_path(fault.instance_path),
        expected: "\{fault.keyword} (\{fault.schema_path})",
        actual: fault.message,
      })
    [] => Ok(())
  }
}

///|
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
