///|

///|
/// Why scheduling failed. Each variant is a kernel-invariant failure.
pub(all) suberror SchedulingError {
  /// Duplicate `call_id` in the same batch.
  DuplicateCallId(call_id~ : @kernel.CallId)
  /// Unknown tool reached the scheduler — upstream invariant broken.
  UnknownToolReachedScheduler(
    call_id~ : @kernel.CallId,
    name~ : @kernel.ToolName,
  )
  /// `expected_version` mismatch with the snapshot.
  StaleSnapshotVersion(expected~ : CatalogVersion, actual~ : CatalogVersion)
}

///|
pub extend SchedulingError with Show::{to_string, output}

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
#derive(Eq, Debug)
pub(all) struct ExecutionWave {
  /// Calls in this wave, in source order.
  calls : Array[@kernel.ToolCall]
  /// Policies for diagnostics; not used for ordering at execution time.
  policies : Array[@kernel.ExecutionPolicy]
}

///|
pub extend ExecutionWave with Eq::{not_equal, equal}

///|
pub extend ExecutionWave with Debug::{to_repr}

///|
pub extend ExecutionWave with Show::{output}

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
#derive(Eq, Debug)
pub(all) struct ExecutionPlan {
  waves : Array[ExecutionWave]
}

///|
pub extend ExecutionPlan with Eq::{not_equal, equal}

///|
pub extend ExecutionPlan with Debug::{to_repr}

///|
pub fn ExecutionPlan::waves(self : ExecutionPlan) -> Array[ExecutionWave] {
  self.waves.copy()
}

///|
pub fn ExecutionPlan::wave_count(self : ExecutionPlan) -> Int32 {
  self.waves.length()
}

///|
/// Total number of calls across all waves.
pub fn ExecutionPlan::total_calls(self : ExecutionPlan) -> Int32 {
  let mut n = 0
  for w in self.waves {
    n = n + w.calls.length()
  }
  n
}

///|
pub extend ExecutionPlan with Show::{to_string, output}

///|
pub impl Show for ExecutionPlan with fn to_string(self : ExecutionPlan) -> String {
  "ExecutionPlan(\{self.waves.map(fn(w) { w.to_string() }).join(", ")})"
}

///|
fn to_scheduler_policy(
  policy : @kernel.ExecutionPolicy,
) -> @proof_scheduler.Policy {
  match policy {
    Parallel => Parallel
    Sequential => Sequential
    Exclusive => Exclusive
  }
}

///|
pub fn schedule(
  snapshot : ToolCatalogSnapshot,
  expected_version : CatalogVersion,
  calls : Array[@kernel.ToolCall],
) -> ExecutionPlan raise SchedulingError {
  if !@proof_scheduler.catalog_version_matches(
      expected_version.to_int(),
      snapshot.version().to_int(),
    ) {
    raise StaleSnapshotVersion(
      expected=expected_version,
      actual=snapshot.version(),
    )
  }
  let seen : Map[String, Unit] = Map::from_array([])
  let resolved_policies : Array[@kernel.ExecutionPolicy] = []
  let proof_policies_arr : Array[@proof_scheduler.Policy] = []
  for c in calls {
    let id = c.call_id.to_string()
    if seen.contains(id) {
      raise DuplicateCallId(call_id=c.call_id)
    }
    seen[id] = ()
    let entry = match snapshot.find(c.name) {
      Some(e) => e
      None => raise UnknownToolReachedScheduler(call_id=c.call_id, name=c.name)
    }
    resolved_policies.push(entry.definition.policy)
    proof_policies_arr.push(to_scheduler_policy(entry.definition.policy))
  }
  let proof_policies = FixedArray::from_array(proof_policies_arr)
  let waves : Array[ExecutionWave] = []
  let mut start = 0
  while start < calls.length() {
    let stop = @proof_scheduler.next_wave_end(proof_policies, start)
    let wave_calls : Array[@kernel.ToolCall] = []
    let wave_policies : Array[@kernel.ExecutionPolicy] = []
    for i in start..<stop {
      wave_calls.push(calls[i])
      wave_policies.push(resolved_policies[i])
    }
    waves.push({ calls: wave_calls, policies: wave_policies, })
    start = stop
  }
  { waves, }
}

///|
/// Single-line plan trace for logs. Includes call ids, names and policies;
/// NEVER includes arguments or schema payloads.
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
