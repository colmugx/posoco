///|
let compact_cause_label_budget : Int32 = 352

///|
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
fn is_compact_effect_phase(phase : String) -> Bool {
  phase == "compact" || phase == "compact_session" || phase == "auto_compact"
}
