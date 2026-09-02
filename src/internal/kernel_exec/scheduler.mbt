///|
/// Deterministic ToolScheduler for the M1 functional Kernel (ADR §2.8).
/// Given a catalog snapshot and source-order tool calls (pre-validated by the reducer),
/// produces ordered execution waves. Parallel neighbours share a wave; Exclusive
/// forms a barrier before and after; Sequential occupies a single-element wave.

///|
/// Why scheduling failed. Each variant is a kernel-invariant failure.
pub(all) suberror SchedulingError {
  /// Duplicate `call_id` in the same batch.
  DuplicateCallId(call_id~ : @kernel.CallId)
  /// Unknown tool reached the scheduler — upstream invariant broken.
  UnknownToolReachedScheduler(
    call_id~ : @kernel.CallId,
    name~ : @kernel.ToolName
  )
  /// `expected_version` mismatch with the snapshot.
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

///|
/// A single wave of tool calls that MAY execute in parallel. Wave membership
/// is determined by the execution policies of adjacent calls; executor is
/// free to run them in any order, but the reducer places outcomes back in
/// source order regardless of completion order (ADR §2.8).
pub(all) struct ExecutionWave {
  /// Calls in this wave, in source order.
  calls : Array[@kernel.ToolCall]
  /// Policies for diagnostics; not used for ordering at execution time.
  policies : Array[@kernel.ExecutionPolicy]
} derive(Eq, Debug)

///|
pub impl Show for ExecutionWave with fn to_string(self : ExecutionWave) -> String {
  "Wave([\{self.calls.map(fn(c) { c.call_id.to_string() }).join(", ")}])"
}

///|
/// Calls in this wave, in stable source order. Returns a defensive copy.
pub fn ExecutionWave::calls(self : ExecutionWave) -> Array[@kernel.ToolCall] {
  self.calls.copy()
}

///|
/// Result of scheduling. Waves are in execution order; each MAY run in parallel.
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
  "ExecutionPlan(\{self.waves.map(fn(w) { w.to_string() }).join(", ")})"
}

///|
/// Schedule validated calls into execution waves per `ExecutionPolicy`.
/// Raises `SchedulingError` on duplicate call_id, unknown tool, or
/// stale snapshot version.
pub fn schedule(
  snapshot : ToolCatalogSnapshot,
  expected_version : CatalogVersion,
  calls : Array[@kernel.ToolCall],
) -> ExecutionPlan raise SchedulingError {
  if snapshot.version() != expected_version {
    raise StaleSnapshotVersion(
      expected=expected_version,
      actual=snapshot.version(),
    )
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for c in calls {
    let id = c.call_id.to_string()
    if seen.contains(id) {
      raise DuplicateCallId(call_id=c.call_id)
    }
    seen[id] = ()
    if !snapshot.contains(c.name) {
      raise UnknownToolReachedScheduler(call_id=c.call_id, name=c.name)
    }
  }
  let waves : Array[ExecutionWave] = []
  let current_calls : Array[@kernel.ToolCall] = []
  let current_policies : Array[@kernel.ExecutionPolicy] = []
  fn flush(
    waves : Array[ExecutionWave],
    current_calls : Array[@kernel.ToolCall],
    current_policies : Array[@kernel.ExecutionPolicy],
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
      None => raise UnknownToolReachedScheduler(call_id=c.call_id, name=c.name)
    }
    let policy = entry.definition.policy
    match policy {
      Exclusive => {
        flush(waves, current_calls, current_policies)
        waves.push({ calls: [c], policies: [policy], })
      }
      Sequential => {
        flush(waves, current_calls, current_policies)
        current_calls.push(c)
        current_policies.push(policy)
        flush(waves, current_calls, current_policies)
      }
      Parallel => {
        current_calls.push(c)
        current_policies.push(policy)
      }
    }
  }
  flush(waves, current_calls, current_policies)
  { waves, }
}

///|
/// Single-line plan trace for logs. Includes call ids, names and policies;
/// NEVER includes arguments or schema payloads (ADR §2.7).
pub fn ExecutionPlan::trace(self : ExecutionPlan) -> String {
  self.waves
  .mapi(fn(wave_index, wave) {
    let details = wave.calls.mapi(fn(i, c) {
      "\{c.call_id.to_string()}:\{c.name.to_string()}:\{wave.policies[i].to_string()}"
    })
    "wave\{wave_index}={\{details.join(", ")}}"
  })
  .join(" ")
}
