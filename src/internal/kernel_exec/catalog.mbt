///|
/// Why catalog composition failed. Each variant is a composition hard
/// failure: the catalog was not built, no Run was started, no model/tool
/// effect was declared.
pub(all) suberror CatalogCompositionError {
  /// A tool declared an empty/illegal call-visible name.
  InvalidToolName(detail~ : String)
  /// Two tools declared the same call-visible name.
  NameCollision(
    visible_name~ : String,
    first_provenance~ : String,
    conflicting_provenance~ : String
  )
  /// Two tools came from the same source with conflicting definitions.
  DuplicateProvenance(visible_name~ : String, provenance~ : String)
  /// A tool's input schema uses an unsupported JSON Schema keyword.
  UnsupportedSchemaKeyword(visible_name~ : String, keyword~ : String)
  /// A tool's input schema is not a valid JSON object or boolean.
  MalformedSchema(visible_name~ : String, detail~ : String)
  /// A tool declared an execution policy the catalog does not recognise.
  /// (Reserved for future policy extensions; current code never produces
  /// this because `ExecutionPolicy` is a closed enum.)
  InvalidExecutionPolicy(visible_name~ : String, detail~ : String)
  /// No tools at all. Allowed when the caller explicitly opts in; otherwise
  /// a composition failure because the catalog version would have no
  /// model-visible content.
  Empty
}

///|
pub impl Show for CatalogCompositionError with fn to_string(
  self : CatalogCompositionError,
) -> String {
  match self {
    InvalidToolName(detail~) => "InvalidToolName(\{detail})"
    NameCollision(visible_name~, first_provenance~, conflicting_provenance~) =>
      "NameCollision(\{visible_name}; first=\{first_provenance}, conflicting=\{conflicting_provenance})"
    DuplicateProvenance(visible_name~, provenance~) =>
      "DuplicateProvenance(\{visible_name}, provenance=\{provenance})"
    UnsupportedSchemaKeyword(visible_name~, keyword~) =>
      "UnsupportedSchemaKeyword(\{visible_name}, keyword=\{keyword})"
    MalformedSchema(visible_name~, detail~) =>
      "MalformedSchema(\{visible_name}, \{detail})"
    InvalidExecutionPolicy(visible_name~, detail~) =>
      "InvalidExecutionPolicy(\{visible_name}, \{detail})"
    Empty => "Empty"
  }
}

///|
/// Internal entry: bundles a `ToolDef` with its position in the
/// catalog (for stable enumeration). The snapshot exposes read-only
/// accessors; callers cannot mutate entries.
pub(all) struct CatalogEntry {
  /// Stable 0-based position in declaration order. Used by the scheduler
  /// (T06) to preserve source order across execution waves.
  position : Int
  definition : @kernel.ToolDef
} derive(Eq, Debug)

///|
/// Immutable, versioned catalog. Built by `ToolCatalogBuilder`; consumed
/// read-only by the reducer and executor.
pub struct ToolCatalogSnapshot {
  version : CatalogVersion
  entries : Array[CatalogEntry]
  by_name : Map[String, CatalogEntry]
} derive(Eq, Debug)

///|
/// Incremental builder for `ToolCatalogSnapshot`. Validates each insertion
/// atomically: any composition failure aborts the build and the builder
/// cannot be reused.
///
/// Typical use:
/// ```moonbit nocheck
/// let snapshot = ToolCatalogBuilder()
///   .add(def1)
///   .add(def2)
///   .finish(version=CatalogVersion(1))
/// ```
pub struct ToolCatalogBuilder {
  entries : Array[CatalogEntry]
  by_name : Map[String, CatalogEntry]
  mut finished : Bool
}

///|
pub fn ToolCatalogBuilder::ToolCatalogBuilder() -> ToolCatalogBuilder {
  { entries: [], by_name: Map::from_array([]), finished: false }
}

///|
/// Add a tool definition. Validates:
/// - non-empty name (already enforced by `ToolDef`, but double-check)
/// - no name collision
/// - no duplicate provenance+name
/// - supported schema keywords only
/// - well-formed schema (object or boolean at top level)
///
/// Returns the builder for chaining. Raises `CatalogCompositionError` on
/// any composition hard failure.
pub fn ToolCatalogBuilder::add(
  self : ToolCatalogBuilder,
  def : @kernel.ToolDef,
) -> ToolCatalogBuilder raise CatalogCompositionError {
  if self.finished {
    raise InvalidToolName(detail="builder is finished (finish() was called)")
  }
  let visible_name = def.name.to_string()
  if visible_name == "" {
    raise InvalidToolName(detail="tool name must be non-empty")
  }
  if self.by_name.contains(visible_name) {
    let prev = self.by_name[visible_name]
    let prev_prov = match prev.definition.provenance {
      Some(p) => p
      None => "(unlabeled)"
    }
    let curr_prov = match def.provenance {
      Some(p) => p
      None => "(unlabeled)"
    }
    raise NameCollision(
      visible_name~,
      first_provenance=prev_prov,
      conflicting_provenance=curr_prov,
    )
  }
  // Schema validation: must be object or boolean at top level, and only
  // use supported keywords (recursively).
  match check_schema_top_level(def.input_schema) {
    Err(detail) => raise MalformedSchema(visible_name~, detail~)
    Ok(_) => ()
  }
  match check_schema_supported(def.input_schema) {
    Err(keyword) => raise UnsupportedSchemaKeyword(visible_name~, keyword~)
    Ok(_) => ()
  }
  let entry : CatalogEntry = {
    position: self.entries.length(),
    definition: def,
  }
  self.entries.push(entry)
  self.by_name[visible_name] = entry
  self
}

///|
/// Seal the builder and produce an immutable snapshot. The builder is
/// marked sealed; further `add` calls raise.
pub fn ToolCatalogBuilder::finish(
  self : ToolCatalogBuilder,
  version~ : CatalogVersion,
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  if self.finished {
    raise InvalidToolName(detail="builder already finished")
  }
  self.finished = true
  { version, entries: self.entries.copy(), by_name: self.by_name.copy() }
}

///|
pub fn ToolCatalogSnapshot::version(
  self : ToolCatalogSnapshot,
) -> CatalogVersion {
  self.version
}

///|
/// Returns all entries in declaration (source) order. The result is a copy;
/// callers cannot mutate the snapshot.
pub fn ToolCatalogSnapshot::entries(
  self : ToolCatalogSnapshot,
) -> Array[CatalogEntry] {
  self.entries.copy()
}

///|
/// Look up an entry by call-visible name. Returns None if not present.
pub fn ToolCatalogSnapshot::find(
  self : ToolCatalogSnapshot,
  name : @kernel.ToolName,
) -> CatalogEntry? {
  self.by_name.get(name.to_string())
}

///|
/// Convenience: does the catalog contain a tool with this call-visible name?
pub fn ToolCatalogSnapshot::contains(
  self : ToolCatalogSnapshot,
  name : @kernel.ToolName,
) -> Bool {
  self.by_name.contains(name.to_string())
}

///|
/// Returns just the tool definitions in source order — what the model
/// adapter should be prompted with.
pub fn ToolCatalogSnapshot::definitions(
  self : ToolCatalogSnapshot,
) -> Array[@kernel.ToolDef] {
  let out : Array[@kernel.ToolDef] = []
  for entry in self.entries {
    out.push(entry.definition)
  }
  out
}

///|
/// Number of tools in the catalog.
pub fn ToolCatalogSnapshot::size(self : ToolCatalogSnapshot) -> Int {
  self.entries.length()
}

///|
/// Validate parsed arguments against the named tool's input schema. Used by
/// the reducer (T03) when folding `ModelCompleted`. Returns:
/// - Ok(()) if the args conform
/// - Err(SchemaDiagnostic) if the args are well-formed JSON but fail the
///   schema
///
/// Unknown tool name returns `Err` with a diagnostic that the reducer maps
/// to `ToolOutcome::NotExecuted(UnknownTool)`.
pub fn ToolCatalogSnapshot::validate_arguments(
  self : ToolCatalogSnapshot,
  name : @kernel.ToolName,
  arguments : Json,
) -> Result[Unit, @kernel.SchemaDiagnostic] {
  match self.find(name) {
    Some(entry) => validate_arguments(entry.definition.input_schema, arguments)
    None =>
      Err({
        json_path: "$",
        expected: "known tool",
        actual: "unknown tool '\{name.to_string()}'",
      })
  }
}

///|
fn check_schema_top_level(schema : Json) -> Result[Unit, String] {
  match schema {
    Json::Object(_) => Ok(())
    Json::True => Ok(())
    Json::False => Ok(())
    _ => Err("schema must be JSON object or boolean at top level")
  }
}

///|
/// Catalog version — bumped every time a snapshot is built. The reducer and
/// executor correlate `CallModel` and `ExecuteTool` effects back to the exact
/// snapshot version the model was prompted against; a mismatch is a kernel
/// invariant failure (`InvariantViolation::StaleSnapshot`).
pub(all) struct CatalogVersion {
  value : Int
} derive(Eq, Debug)

///|
pub fn CatalogVersion::CatalogVersion(value : Int) -> CatalogVersion {
  CatalogVersion::{ value, }
}

///|
pub fn CatalogVersion::to_int(self : CatalogVersion) -> Int {
  self.value
}

///|
pub impl Show for CatalogVersion with fn to_string(self : CatalogVersion) -> String {
  "CatalogVersion(\{self.value})"
}
