///|
/// Leave room for structural error wrappers under the 512-character display
/// bound. ModelFailure reasons must already be safe labels, not raw payloads.
let compact_cause_label_budget : Int = 352

///|
/// Cause label for a failed modelport compact: the structural `ModelFailure`
/// category plus the adapter's safe bounded reason, rendered in the same
/// shape as the kernel display but under the wider relay budget. The reason
/// text is never parsed, reordered, or restructured into fields.
fn compact_failure_cause(failure : @kernel.ModelFailure) -> String {
  let (category, reason) = match failure {
    RequestBuild(reason~) => ("RequestBuild", reason)
    Transport(reason~) => ("Transport", reason)
    Runtime(reason~) => ("Runtime", reason)
    Parse(reason~) => ("Parse", reason)
    HostRejected(reason~) => ("HostRejected", reason)
    RateLimited(reason~, ..) => ("RateLimited", reason)
  }
  let label = safe_label_bounded(reason, compact_cause_label_budget)
  "modelport compact failed: ModelFailure::\{category}(\{label})"
}

///|
/// Effect phases that belong to a compaction. Only their failure rendering
/// may widen the cause label to the 512-character outer display; every other
/// phase keeps the exact previous 64-character rendering. Mirrors the
/// Agent-level twin in `src/agent_turn.mbt` — extend both together.
fn is_compact_effect_phase(phase : String) -> Bool {
  phase == "compact" || phase == "compact_session" || phase == "auto_compact"
}
