///|
pub(all) enum AdmitDecision {
  AdmitNew(Int32)
  Coalesced(Int32)
  RejectScopeInactive
  RejectInvalidSession
  RejectPendingFull
}

///|
pub(all) enum RequeueDecision {
  RequeueAtFront
  DropStaleOrClosed
  DropSuperseded
}

///|
pub fn admit_wakeup(
  closed : Bool,
  scope_active : Bool,
  active_session_matches : Bool,
  existing_slot : Int32?,
  pending_len : Int32,
  max_pending : Int32,
  current_gen : Int32,
) -> AdmitDecision where {
  proof_require: max_pending >= 1 &&
  pending_len >= 0 &&
  pending_len <= max_pending &&
  current_gen >= 0 &&
  current_gen < 2_147_483_647,
  proof_ensure: result => {
    admit_post(
      closed, scope_active, active_session_matches, existing_slot, pending_len, max_pending,
      current_gen, result,
    )
  },
} {
  if closed || !scope_active {
    RejectScopeInactive
  } else if !active_session_matches {
    RejectInvalidSession
  } else {
    match existing_slot {
      Some(_) => Coalesced(current_gen + 1)
      None =>
        if pending_len >= max_pending {
          RejectPendingFull
        } else {
          AdmitNew(current_gen + 1)
        }
    }
  }
}

///|
pub fn cutoff_covers_entry(
  entry_session : Int32,
  entry_latest_req : Int32,
  cutoff_session : Int32,
  cutoff_gen : Int32,
) -> Bool where {
  proof_ensure: result => {
    result ==
    (entry_session == cutoff_session && entry_latest_req <= cutoff_gen)
  },
} {
  entry_session == cutoff_session && entry_latest_req <= cutoff_gen
}

///|
pub fn decide_requeue(
  closed : Bool,
  entry_stale : Bool,
  key_present : Bool,
) -> RequeueDecision where {
  proof_ensure: result => requeue_post(closed, entry_stale, key_present, result),
} {
  if closed || entry_stale {
    DropStaleOrClosed
  } else if key_present {
    DropSuperseded
  } else {
    RequeueAtFront
  }
}
