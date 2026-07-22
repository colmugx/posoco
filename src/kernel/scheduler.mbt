///|
/// Deterministic ToolScheduler for the M1 functional Kernel (ADR §2.8).
///
/// The scheduler is pure: given a `ToolCatalogSnapshot` and a source-order
/// list of tool calls (already validated for unknown-name and schema-mismatch
/// by the reducer before reaching here), it produces ordered execution
/// waves. Waves describe what MAY run in parallel; the executor still
/// executes them one effect at a time.
///
/// Rules (ADR §2.8):
/// - `Parallel` neighbours share a wave.
/// - `Exclusive` forms a barrier before AND after.
/// - `Sequential` always occupies a single-element wave.
/// - Adjacent waves never merge across an `Exclusive`.
///
/// Kernel-invariant failures detected here:
/// - duplicate `call_id` within a single batch
/// - missing tool name in the catalog (the reducer should already have
///   converted these to NotExecuted outcomes, but if one slips through the
///   scheduler must not silently produce a wave for it — instead it raises
///   `SchedulingError::UnknownToolReachedScheduler`).
/// - stale catalog version (the caller passes both the snapshot and the
///   expected version; mismatch is a hard failure).

// ──────────────────────────────────────────────────────────────────────────
// Errors
// ──────────────────────────────────────────────────────────────────────────

///|
/// Why scheduling failed. Each variant is a kernel-invariant failure — the
/// scheduler MUST NOT silently downgrade these to ordinary tool errors
/// (ADR §2.4, §2.8).
pub(all) suberror SchedulingError {
  /// Two calls in the same batch carried the same `call_id`.
  DuplicateCallId(call_id~ : CallId)
  /// The reducer should have converted unknown-tool requests to
  /// `NotExecuted(UnknownTool)` before reaching the scheduler. If one slips
  /// through, the upstream invariant is broken.
  UnknownToolReachedScheduler(call_id~ : CallId, name~ : ToolName)
  /// Caller passed a `expected_version` that does not match the snapshot.
  StaleSnapshotVersion(expected~ : CatalogVersion, actual~ : CatalogVersion)
}

///|
pub impl Show for SchedulingError with fn to_string(self : SchedulingError) -> String {
  match self {
    DuplicateCallId(call_id~) =>
      "SchedulingError::DuplicateCallId(\{call_id.to_string()})"
    UnknownToolReachedScheduler(call_id~, name~) =>
      "SchedulingError::UnknownToolReachedScheduler(call=\{call_id.to_string()}, name=\{name.to_string()})"
    StaleSnapshotVersion(expected~, actual~) =>
      "SchedulingError::StaleSnapshotVersion(expected=\{expected.to_int()}, actual=\{actual.to_int()})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Execution wave
// ──────────────────────────────────────────────────────────────────────────

///|
/// A single wave of tool calls that MAY execute in parallel. Wave membership
/// is determined by the execution policies of adjacent calls; the executor
/// is free to execute the wave's calls in any order or in parallel, but the
/// reducer (T03) places the outcomes back into the transcript in source
/// order regardless of completion order (ADR §2.8).
pub(all) struct ExecutionWave {
  /// Calls in this wave, in source order. The order inside a wave does not
  /// affect canonical transcript order — that is fixed by source position.
  calls : Array[CanonicalToolCall]
  /// Policies of the calls in this wave. Useful for the executor's
  /// diagnostics; not used for ordering decisions at execution time.
  policies : Array[ExecutionPolicy]
} derive(Eq, Debug)

///|
pub impl Show for ExecutionWave with fn to_string(self : ExecutionWave) -> String {
  let ids = self.calls.map(fn(c) { c.call_id.to_string() }).join(", ")
  "Wave([\{ids}])"
}

// ──────────────────────────────────────────────────────────────────────────
// Execution plan
// ──────────────────────────────────────────────────────────────────────────

///|
/// Result of scheduling. The waves are in execution order: wave 0 runs
/// first, then wave 1, etc. Each wave MAY run its calls in parallel.
pub(all) struct ExecutionPlan {
  waves : Array[ExecutionWave]
} derive(Eq, Debug)

///|
pub fn ExecutionPlan::waves(self : ExecutionPlan) -> Array[ExecutionWave] {
  self.waves.copy()
}

///|
pub fn ExecutionPlan::wave_count(self : ExecutionPlan) -> Int {
  self.waves.length()
}

///|
/// Total number of calls across all waves.
pub fn ExecutionPlan::total_calls(self : ExecutionPlan) -> Int {
  let mut n = 0
  for w in self.waves {
    n = n + w.calls.length()
  }
  n
}

///|
pub impl Show for ExecutionPlan with fn to_string(self : ExecutionPlan) -> String {
  let parts = self.waves.map(fn(w) { w.to_string() })
  "ExecutionPlan(" + parts.join(", ") + ")"
}

// ──────────────────────────────────────────────────────────────────────────
// Scheduler
// ──────────────────────────────────────────────────────────────────────────

///|
/// Schedule `calls` (already validated for unknown name and schema) into
/// execution waves according to each tool's `ExecutionPolicy`.
///
/// The caller passes the catalog snapshot AND the `expected_version` it
/// built the model prompt against; a mismatch is `StaleSnapshotVersion`.
///
/// Raises `SchedulingError` on:
/// - duplicate `call_id` within the batch
/// - unknown tool reaching the scheduler (upstream invariant broken)
/// - stale snapshot version
pub fn schedule(
  snapshot : ToolCatalogSnapshot,
  expected_version : CatalogVersion,
  calls : Array[CanonicalToolCall],
) -> ExecutionPlan raise SchedulingError {
  if snapshot.version() != expected_version {
    raise StaleSnapshotVersion(
      expected=expected_version,
      actual=snapshot.version(),
    )
  }
  // Detect duplicate call ids BEFORE any wave-building: a duplicate is an
  // invariant failure that must not produce a partial plan.
  let seen : Map[String, Unit] = Map::from_array([])
  for c in calls {
    let id = c.call_id.to_string()
    if seen.contains(id) {
      raise DuplicateCallId(call_id=c.call_id)
    }
    seen[id] = ()
    // Also assert the tool name is in the snapshot. The reducer should have
    // already converted unknown names to NotExecuted, so reaching here means
    // upstream is broken.
    if !snapshot.contains(c.name) {
      raise UnknownToolReachedScheduler(call_id=c.call_id, name=c.name)
    }
  }
  // Build waves.
  let waves : Array[ExecutionWave] = []
  let current_calls : Array[CanonicalToolCall] = []
  let current_policies : Array[ExecutionPolicy] = []
  // Helper to flush the current wave.
  fn flush(
    waves : Array[ExecutionWave],
    current_calls : Array[CanonicalToolCall],
    current_policies : Array[ExecutionPolicy],
  ) -> Unit {
    if !current_calls.is_empty() {
      waves.push({
        calls: current_calls.copy(),
        policies: current_policies.copy(),
      })
      current_calls.clear()
      current_policies.clear()
    }
  }
  for c in calls {
    let entry = match snapshot.find(c.name) {
      Some(e) => e
      None =>
        // Should be unreachable because of the pre-check above.
        raise UnknownToolReachedScheduler(call_id=c.call_id, name=c.name)
    }
    let policy = entry.definition.policy
    match policy {
      Exclusive => {
        // Exclusive forms a barrier before and after.
        flush(waves, current_calls, current_policies)
        waves.push({ calls: [c], policies: [policy] })
      }
      Sequential => {
        // Sequential occupies its own single-element wave.
        flush(waves, current_calls, current_policies)
        current_calls.push(c)
        current_policies.push(policy)
        flush(waves, current_calls, current_policies)
      }
      Parallel => {
        // Parallel joins the current wave if the current wave is all
        // Parallel (which is true because we flush on Exclusive/Sequential).
        current_calls.push(c)
        current_policies.push(policy)
      }
    }
  }
  flush(waves, current_calls, current_policies)
  ExecutionPlan::{ waves, }
}

// ──────────────────────────────────────────────────────────────────────────
// Plan trace (debug)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Single-line trace of the plan, suitable for logs and conformance golden
/// output. Includes call ids, names and policies; NEVER includes arguments
/// or schema payloads (ADR §2.7 — safe diagnostics).
pub fn ExecutionPlan::trace(self : ExecutionPlan) -> String {
  let parts : Array[String] = []
  for wave_index, wave in self.waves {
    let call_parts : Array[String] = []
    for i = 0; i < wave.calls.length(); i = i + 1 {
      let c = wave.calls[i]
      let p = wave.policies[i]
      call_parts.push(
        "\{c.call_id.to_string()}:\{c.name.to_string()}:\{p.to_string()}",
      )
    }
    parts.push("wave\{wave_index}={" + call_parts.join(", ") + "}")
  }
  parts.join(" ")
}
