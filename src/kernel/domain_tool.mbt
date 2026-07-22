///|
/// Canonical tool-definition types for the M1 functional Kernel.
///
/// ADR §2.7, §2.8, §2.11: the catalog snapshot is the single source of truth
/// for tool definitions (model-visible) AND for execution owners. The
/// reducer/executor never re-resolves owners from a separate routing cache.
/// Tool execution policy is explicit data — not inferred from the tool name.

// ──────────────────────────────────────────────────────────────────────────
// Execution policy
// ──────────────────────────────────────────────────────────────────────────

///|
/// How a tool may be batched with other tools in the same model completion.
///
/// - `Sequential`: occupies a single-element wave. Safe default; file/shell
///   side effects never race.
/// - `Parallel`: may share a wave with adjacent `Parallel` calls.
/// - `Exclusive`: forms a barrier before and after; never shares a wave.
///
/// ADR §2.8 freezes the safe default as `Sequential`. The compatibility facade
/// (M1-T10) pins every legacy tool to `Parallel` to preserve M0's
/// `async.all`-every-batch behaviour byte-for-byte.
pub(all) enum ExecutionPolicy {
  Sequential
  Parallel
  Exclusive
} derive(Eq, Debug)

///|
pub impl Show for ExecutionPolicy with fn to_string(self : ExecutionPolicy) -> String {
  match self {
    Sequential => "Sequential"
    Parallel => "Parallel"
    Exclusive => "Exclusive"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Tool definition
// ──────────────────────────────────────────────────────────────────────────

///|
/// Stable identifier for the provider that owns a tool. The Kernel uses this
/// only for owner lookup in the runtime registry; it does not call into the
/// owner through this type.
pub(all) struct OwnerId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn OwnerId::new(value : String) -> Result[OwnerId, String] {
  if value == "" {
    Err("OwnerId must be non-empty")
  } else {
    Ok(OwnerId::{ value, })
  }
}

///|
pub fn OwnerId::unchecked(value : String) -> OwnerId {
  OwnerId::{ value, }
}

///|
pub fn OwnerId::to_string(self : OwnerId) -> String {
  self.value
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
pub fn CatalogVersion::new(value : Int) -> CatalogVersion {
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

///|
/// A single tool's definition as the model and the executor see it. Owned by
/// the catalog snapshot (T05), not by individual providers.
pub(all) struct CanonicalToolDef {
  name : ToolName
  description : String
  input_schema : Json
  owner : OwnerId
  policy : ExecutionPolicy
  /// Optional provenance label (e.g. provider name, MCP server id). Included
  /// in collision diagnostics; never used for routing decisions.
  provenance : String?
} derive(Eq, Debug)

///|
/// Internal builder used by the catalog. Most fields are required; provenance
/// is optional. The catalog builder (T05) validates the schema and policy
/// before constructing this, so by the time a `CanonicalToolDef` reaches the
/// reducer, it has already passed composition.
pub fn CanonicalToolDef::new(
  name~ : ToolName,
  description~ : String,
  input_schema~ : Json,
  owner~ : OwnerId,
  policy~ : ExecutionPolicy,
  provenance~ : String?,
) -> CanonicalToolDef {
  { name, description, input_schema, owner, policy, provenance }
}

///|
pub impl Show for CanonicalToolDef with fn to_string(self : CanonicalToolDef) -> String {
  "Tool(\{self.name.to_string()} @ \{self.owner.to_string()}, policy=\{self.policy.to_string()})"
}

// ──────────────────────────────────────────────────────────────────────────
// Schema validation outcome (used by reducer to build NotExecuted outcomes)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Result of validating parsed tool arguments against a `CanonicalToolDef`'s
/// input schema. The validator (T05) returns this; the reducer (T03) maps
/// `Err` into a `ToolOutcome::NotExecuted(SchemaMismatch)` carrying the
/// original call id.
///
/// The diagnostic deliberately excludes the raw argument payload; it reports
/// only a JSON path and a type expectation, so that prompts and tool arguments
/// never leak into logs.
pub(all) struct SchemaDiagnostic {
  json_path : String
  expected : String
  actual : String
} derive(Eq, Debug)

///|
pub impl Show for SchemaDiagnostic with fn to_string(self : SchemaDiagnostic) -> String {
  "SchemaDiagnostic(path=\{self.json_path}, expected=\{self.expected}, actual=\{self.actual})"
}
