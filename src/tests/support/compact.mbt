///|
using @agent {type RecordingSessionPort, tk_user_msg}

///|
pub fn policy_replace_result() -> @kernel.CompactResult {
  { compacted_messages: [tk_user_msg("summary")], mode: Replace, }
}

///|
pub fn compact_tools_seed(store : RecordingSessionPort, id : String) -> Unit {
  store.seed(id, {
    messages: [tk_user_msg("committed history")],
    metadata: Map::from_array([]),
  })
}
