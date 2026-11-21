///|
pub(all) enum BodyKind {
  Full(Int32)
  Append(Int32)
}

///|
pub(all) struct VersionMeta {
  kind : BodyKind
  total_len : Int32
  source_session : Int32?
  source_version : Int32?
}

///|
pub(all) enum FactsLifecycle {
  Empty
  Tracking(Int32)
  Complete
  Stopped(Int32)
  MissingProvenance
}

///|
pub fn validate_prefix(
  prefix_len : Int32,
  available : Int32,
) -> Bool where {
  proof_require: available >= 0,
  proof_ensure: result => result == (0 <= prefix_len && prefix_len <= available),
} {
  prefix_len >= 0 && prefix_len <= available
}

///|
pub fn next_source_snapshot_ver(
  source_seq : Int32,
) -> Int32 where {
  proof_require: source_seq >= 0 && source_seq < 2_147_483_647,
  proof_ensure: result => result < 0 && result == -1 - source_seq,
} {
  -1 - source_seq
}

///|
pub fn append_meta(
  prev : VersionMeta,
  tail_len : Int32,
) -> VersionMeta where {
  proof_require: version_meta_inv(prev) &&
  tail_len >= 0 &&
  prev.total_len <= 2_147_483_647 - tail_len,
  proof_ensure: result => version_meta_inv(result),
  proof_ensure: result => result.total_len == prev.total_len + tail_len,
  proof_ensure: result => provenance_eq(prev, result),
} {
  let res : VersionMeta = {
    kind: Append(tail_len),
    total_len: prev.total_len + tail_len,
    source_session: prev.source_session,
    source_version: prev.source_version,
  }
  proof_assert opt_int_eq(prev.source_session, res.source_session)
  proof_assert opt_int_eq(prev.source_version, res.source_version)
  res
}

///|
pub fn rewrite_meta(
  prev : VersionMeta,
  full_len : Int32,
) -> VersionMeta where {
  proof_require: version_meta_inv(prev) && full_len >= 0,
  proof_ensure: result => version_meta_inv(result),
  proof_ensure: result => result.total_len == full_len && is_full(result.kind),
  proof_ensure: result => provenance_eq(prev, result),
} {
  let res : VersionMeta = {
    kind: Full(full_len),
    total_len: full_len,
    source_session: prev.source_session,
    source_version: prev.source_version,
  }
  proof_assert opt_int_eq(prev.source_session, res.source_session)
  proof_assert opt_int_eq(prev.source_version, res.source_version)
  res
}

///|
pub fn find_full_anchor(
  kinds : FixedArray[BodyKind],
  start : Int32,
) -> Int32 where {
  proof_decrease: start,
  proof_require: kinds.length() >= 1 &&
  is_full(kinds[0]) &&
  0 <= start &&
  start < kinds.length(),
  proof_ensure: anchor => {
    0 <= anchor && anchor <= start && is_full(kinds[anchor])
  },
} {
  if start == 0 {
    0
  } else {
    match kinds[start] {
      Full(_) => start
      Append(_) => find_full_anchor(kinds, start - 1)
    }
  }
}

///|
pub fn facts_stop(
  state : FactsLifecycle,
  run_id : Int32,
) -> FactsLifecycle where {
  proof_ensure: result => facts_stop_post(state, run_id, result),
} {
  match state {
    Tracking(active_run) =>
      if active_run == run_id {
        Stopped(run_id)
      } else {
        Tracking(active_run)
      }
    Empty => Stopped(run_id)
    Stopped(active_run) => Stopped(active_run)
    Complete => Complete
    MissingProvenance => MissingProvenance
  }
}

///|
pub fn facts_finish_run(
  state : FactsLifecycle,
  run_id : Int32,
) -> FactsLifecycle where {
  proof_ensure: result => facts_finish_post(state, run_id, result),
} {
  match state {
    Tracking(active_run) =>
      if active_run == run_id {
        Stopped(run_id)
      } else {
        Tracking(active_run)
      }
    other => other
  }
}
