///|
pub(all) enum IndexDecision {
  AcceptExisting(Int32)
  AcceptAppend(Int32)
  RejectSparse
}

///|
pub(all) enum LatchDecision {
  KeepExisting
  WriteIncoming
}

///|
pub fn check_tool_index(
  count : Int32,
  index : Int32,
) -> IndexDecision where {
  proof_require: count >= 0 && count < 2_147_483_647,
  proof_ensure: result => index_decision_post(count, index, result),
} {
  if index < 0 || index > count {
    RejectSparse
  } else if index == count {
    AcceptAppend(count + 1)
  } else {
    AcceptExisting(count)
  }
}

///|
pub fn merge_first_nonempty(
  current_empty : Bool,
  incoming_present : Bool,
  incoming_empty : Bool,
) -> LatchDecision where {
  proof_ensure: result => {
    merge_latch_post(current_empty, incoming_present, incoming_empty, result)
  },
} {
  if current_empty && incoming_present && !incoming_empty {
    WriteIncoming
  } else {
    KeepExisting
  }
}
