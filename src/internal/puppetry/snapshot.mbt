///|
/// Immutable TurnSnapshot (M2-T02).
///
/// ADR §4 rule 2: `TurnSnapshot` captured at turn start does NOT reference
/// caller-mutable Arrays/Maps. MoonBit containers must be explicitly copied
/// or converted to immutable domain values.
///
/// The snapshot captures:
/// - run/turn identity (typed wrappers)
/// - immutable per-turn run policy (including deep-copied call options)
/// - tool catalog identity (CatalogVersion + copied definitions array)
/// - budget envelope (immutable struct)
/// - deadline (optional)
/// - hook/lifecycle/subscriber provenance (string summaries only — never
///   trait references; the snapshot is data, not a live wiring)
///
/// What the snapshot does NOT carry:
/// - runtime port references (those are Puppet-owned; the snapshot only carries
///   provenance strings for diagnostics)
/// - prompt text or tool arguments (those are in the RunState transcript)
/// - mutable handles to the original config arrays
///
/// Snapshot identity is computed deterministically from the captured
/// values; Map iteration order does NOT affect it (sorted keys).

// ──────────────────────────────────────────────────────────────────────────
// TurnSnapshot
// ──────────────────────────────────────────────────────────────────────────

///|
/// Immutable capture of a turn's configuration. Constructed once via
/// `TurnSnapshot::capture`; the struct fields are read-only and the inner
/// Arrays/Maps are owned by the snapshot (caller cannot mutate them).
pub struct TurnSnapshot {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  /// Catalog version active for this turn. Same value as in the
  /// `ToolCatalogSnapshot::version()`.
  catalog_version : CatalogVersion
  /// Deep-copied canonical tool definitions. Mutating the original catalog
  /// after capture does not change this array.
  tool_definitions : Array[ToolDef]
  /// Immutable policy captured specifically for this turn. It is never read
  /// from PuppetConfig while the run is active.
  policy : RunPolicy
  /// Optional deadline wall-clock timestamp. Carried verbatim from the
  /// host; the Kernel sees it via RunInput::DeadlineReached.
  deadline : Int?
  /// Provenance summaries for hooks/lifecycle/subscribers. Strings only —
  /// the snapshot never holds trait references.
  hook_provenance : Array[String]
  lifecycle_provenance : Array[String]
  subscriber_provenance : Array[String]
  /// Computed fingerprint (deterministic; sorted-key hash of the above).
  /// Equal fingerprints imply byte-equal snapshots (excluding mutable
  /// backing arrays, which we have already copied).
  fingerprint : String
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Capture input (builder pattern)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Policy that may vary between prompts on the same long-lived Puppet.
/// `TurnSnapshot::capture` validates this value and recursively copies its
/// `call_options`.
pub(all) struct RunPolicy {
  model_id : String
  call_options : Json
  budget : Budget
  /// Token budget ceiling for auto-compact. `None` disables auto-compact.
  context_window : Int?
  /// Fraction of `context_window` at which auto-compact fires.
  compact_threshold : Double
} derive(Eq, Debug)

///|
/// Inputs to `TurnSnapshot::capture`. Kept separate from the snapshot struct
/// so callers cannot accidentally construct a snapshot with un-validated
/// fields; they go through `capture`, which copies and fingerprints.
pub(all) struct TurnSnapshotInput {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  catalog : ToolCatalogSnapshot
  policy : RunPolicy
  deadline : Int?
  hook_provenance : Array[String]
  lifecycle_provenance : Array[String]
  subscriber_provenance : Array[String]
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Capture — the only constructor
// ──────────────────────────────────────────────────────────────────────────

///|
/// Capture a `TurnSnapshot` from the given input. The snapshot owns a deep
/// copy of the catalog definitions and call options; the caller's original
/// arrays/maps are not aliased.
///
/// Raises `PuppetError::SnapshotInvalid` for:
/// - empty model_id
/// - empty catalog (zero tools is legal but warned)
/// - negative budget dimensions
/// - deadline in the past (caller's responsibility to check, but we still
///   reject if deadline < 0)
pub fn TurnSnapshot::capture(
  input : TurnSnapshotInput,
) -> TurnSnapshot raise PuppetError {
  // Validate inputs.
  if input.policy.model_id == "" {
    raise SnapshotInvalid(detail="model_id must be non-empty")
  }
  // Empty catalog is legal — a pure-chat run with no tools is valid. The
  // snapshot records zero definitions; the reducer's unknown-tool path
  // handles any tool calls emitted despite the empty catalog.
  // Validate budget dimensions are non-negative where Some.
  match check_budget(input.policy.budget) {
    Err(e) => raise e
    Ok(_) => ()
  }
  match input.policy.context_window {
    Some(value) if value <= 0 =>
      raise SnapshotInvalid(detail="context_window must be positive")
    _ => ()
  }
  if !(input.policy.compact_threshold > 0.0 &&
    input.policy.compact_threshold <= 1.0) {
    raise SnapshotInvalid(
      detail="compact_threshold must be greater than 0.0 and at most 1.0",
    )
  }
  match input.deadline {
    Some(d) => {
      if d < 0 {
        raise SnapshotInvalid(detail="deadline must be non-negative")
      }
      ()
    }
    None => ()
  }
  // Deep-copy catalog definitions.
  let copied_defs : Array[ToolDef] = []
  for entry in input.catalog.entries() {
    copied_defs.push(entry.definition)
  }
  let captured_policy : RunPolicy = {
    model_id: input.policy.model_id,
    call_options: snapshot_json(input.policy.call_options),
    budget: input.policy.budget,
    context_window: input.policy.context_window,
    compact_threshold: input.policy.compact_threshold,
  }
  // Compute fingerprint from the captured values, never caller-owned Json.
  let fp = compute_fingerprint(input, captured_policy)
  {
    run_id: input.run_id,
    turn_id: input.turn_id,
    session_id: input.session_id,
    catalog_version: input.catalog.version(),
    tool_definitions: copied_defs,
    policy: captured_policy,
    deadline: input.deadline,
    hook_provenance: input.hook_provenance.copy(),
    lifecycle_provenance: input.lifecycle_provenance.copy(),
    subscriber_provenance: input.subscriber_provenance.copy(),
    fingerprint: fp,
  }
}

///|
/// Recursively copy Json so mutable Array/Map backing storage cannot cross the
/// turn-capture seam in either direction.
fn snapshot_json(value : Json) -> Json {
  match value {
    Null => Json::null()
    True => Json::boolean(true)
    False => Json::boolean(false)
    Number(number, repr~) => Json::number(number, repr?)
    String(text) => Json::string(text)
    Array(values) => Json::array(values.map(snapshot_json))
    Object(values) => {
      let copied : Map[String, Json] = Map::from_array([])
      for key in values.keys() {
        copied[key] = snapshot_json(values[key])
      }
      Json::object(copied)
    }
  }
}

///|
fn check_budget(budget : Budget) -> Result[Unit, PuppetError] {
  match budget.max_model_steps {
    Some(n) => {
      if n < 0 {
        return Err(
          SnapshotInvalid(detail="max_model_steps must be non-negative"),
        )
      }
      ()
    }
    None => ()
  }
  match budget.max_tool_rounds {
    Some(n) => {
      if n < 0 {
        return Err(
          SnapshotInvalid(detail="max_tool_rounds must be non-negative"),
        )
      }
      ()
    }
    None => ()
  }
  match budget.max_tool_calls {
    Some(n) => {
      if n < 0 {
        return Err(
          SnapshotInvalid(detail="max_tool_calls must be non-negative"),
        )
      }
      ()
    }
    None => ()
  }
  match budget.max_total_tokens {
    Some(n) => {
      if n < 0 {
        return Err(
          SnapshotInvalid(detail="max_total_tokens must be non-negative"),
        )
      }
      ()
    }
    None => ()
  }
  Ok(())
}

// ──────────────────────────────────────────────────────────────────────────
// Fingerprint (deterministic)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Deterministic fingerprint. Inputs are concatenated in a fixed order;
/// Map iteration order does NOT contribute (we use only the catalog version
/// + sorted definition names).
fn compute_fingerprint(input : TurnSnapshotInput, policy : RunPolicy) -> String {
  let parts : Array[String] = []
  parts.push("v1")
  parts.push("run=" + input.run_id.to_string())
  parts.push("turn=" + input.turn_id.to_string())
  parts.push("session=" + input.session_id.to_string())
  parts.push("catalog=" + input.catalog.version().to_int().to_string())
  // Tool names sorted alphabetically.
  let names : Array[String] = []
  for entry in input.catalog.entries() {
    names.push(entry.definition.name.to_string())
  }
  names.sort_by(compare_strings)
  parts.push("tools=[" + names.join(",") + "]")
  parts.push("model=" + policy.model_id)
  // Fingerprint requires deterministic string form; `Json::stringify`
  // gives canonical JSON (no Debug-style formatting).
  parts.push("options=" + policy.call_options.stringify())
  // Budget dimensions in canonical order.
  parts.push("budget_steps=" + opt_to_str(policy.budget.max_model_steps))
  parts.push("budget_rounds=" + opt_to_str(policy.budget.max_tool_rounds))
  parts.push("budget_calls=" + opt_to_str(policy.budget.max_tool_calls))
  parts.push("budget_tokens=" + opt_to_str(policy.budget.max_total_tokens))
  parts.push("context_window=" + opt_to_str(policy.context_window))
  parts.push("compact_threshold=" + policy.compact_threshold.to_string())
  parts.push("deadline=" + opt_to_str(input.deadline))
  // Provenance lists sorted for determinism.
  let hp = input.hook_provenance.copy()
  hp.sort_by(compare_strings)
  parts.push("hooks=[" + hp.join(",") + "]")
  let lp = input.lifecycle_provenance.copy()
  lp.sort_by(compare_strings)
  parts.push("lifecycle=[" + lp.join(",") + "]")
  let sp = input.subscriber_provenance.copy()
  sp.sort_by(compare_strings)
  parts.push("subscribers=[" + sp.join(",") + "]")
  parts.join("|")
}

///|
fn compare_strings(a : String, b : String) -> Int {
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
fn opt_to_str(n : Int?) -> String {
  match n {
    Some(v) => v.to_string()
    None => "_"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Accessors
// ──────────────────────────────────────────────────────────────────────────

///|
pub fn TurnSnapshot::run_id(self : TurnSnapshot) -> RunId {
  self.run_id
}

///|
pub fn TurnSnapshot::turn_id(self : TurnSnapshot) -> TurnId {
  self.turn_id
}

///|
pub fn TurnSnapshot::session_id(self : TurnSnapshot) -> SessionId {
  self.session_id
}

///|
pub fn TurnSnapshot::catalog_version(self : TurnSnapshot) -> CatalogVersion {
  self.catalog_version
}

///|
/// Tool definitions owned by the snapshot. Mutating the returned array does
/// not change the snapshot (the array is a fresh copy on each call, matching
/// `RunState::pending_effects` convention).
pub fn TurnSnapshot::tool_definitions(self : TurnSnapshot) -> Array[ToolDef] {
  self.tool_definitions.copy()
}

///|
pub fn TurnSnapshot::model_id(self : TurnSnapshot) -> String {
  self.policy.model_id
}

///|
pub fn TurnSnapshot::call_options(self : TurnSnapshot) -> Json {
  snapshot_json(self.policy.call_options)
}

///|
pub fn TurnSnapshot::budget(self : TurnSnapshot) -> Budget {
  self.policy.budget
}

///|
pub fn TurnSnapshot::context_window(self : TurnSnapshot) -> Int? {
  self.policy.context_window
}

///|
pub fn TurnSnapshot::compact_threshold(self : TurnSnapshot) -> Double {
  self.policy.compact_threshold
}

///|
pub fn TurnSnapshot::deadline(self : TurnSnapshot) -> Int? {
  self.deadline
}

///|
pub fn TurnSnapshot::fingerprint(self : TurnSnapshot) -> String {
  self.fingerprint
}

///|
pub fn TurnSnapshot::hook_provenance(self : TurnSnapshot) -> Array[String] {
  self.hook_provenance.copy()
}

///|
pub fn TurnSnapshot::lifecycle_provenance(self : TurnSnapshot) -> Array[String] {
  self.lifecycle_provenance.copy()
}

///|
pub fn TurnSnapshot::subscriber_provenance(
  self : TurnSnapshot,
) -> Array[String] {
  self.subscriber_provenance.copy()
}

// ──────────────────────────────────────────────────────────────────────────
// Redacted debug view
// ──────────────────────────────────────────────────────────────────────────

///|
/// Redacted single-line view for logs and diagnostics. Excludes:
/// - tool arguments / call_options payload (may contain secrets)
/// - tool definition bodies (only name + owner shown)
/// - prompt content (the snapshot never stores prompt text, but we also
///   exclude `call_options` payload)
///
/// Includes:
/// - identity chain (run/turn/session/catalog version)
/// - tool names (not arguments)
/// - budget dimensions
/// - fingerprint
pub fn TurnSnapshot::to_redacted_string(self : TurnSnapshot) -> String {
  let names : Array[String] = []
  for def in self.tool_definitions {
    names.push(def.name.to_string())
  }
  let limits = self.policy.budget
  "TurnSnapshot(run=\{self.run_id.to_string()}, turn=\{self.turn_id.to_string()}, session=\{self.session_id.to_string()}, catalog=\{self.catalog_version.to_int()}, model=\{self.policy.model_id}, tools=[\{names.join(",")}], budget=(steps=\{opt_to_str(limits.max_model_steps)},rounds=\{opt_to_str(limits.max_tool_rounds)},calls=\{opt_to_str(limits.max_tool_calls)},tokens=\{opt_to_str(limits.max_total_tokens)}), deadline=\{opt_to_str(self.deadline)}, fp=\{fp_prefix(self.fingerprint)})"
}

///|
/// Take the first 8 chars of the fingerprint for compact display.
fn fp_prefix(s : String) -> String {
  let chars : Array[Char] = []
  let mut n = 0
  for c in s {
    if n >= 8 {
      break
    }
    chars.push(c)
    n = n + 1
  }
  String::from_array(chars)
}

///|
pub impl Show for TurnSnapshot with fn to_string(self : TurnSnapshot) -> String {
  self.to_redacted_string()
}
