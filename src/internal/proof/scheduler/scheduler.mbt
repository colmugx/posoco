///|
pub(all) enum Policy {
  Parallel
  Sequential
  Exclusive
}

///|
pub(all) struct WaveRange {
  start : Int32
  stop : Int32
}

///|
pub fn catalog_version_matches(
  expected : Int32,
  actual : Int32,
) -> Bool where {
  proof_ensure: result => result == (expected == actual),
} {
  expected == actual
}

///|
fn scan_parallel_end(
  policies : FixedArray[Policy],
  start : Int32,
  idx : Int32,
  remaining : Int32,
) -> Int32 where {
  proof_decrease: remaining,
  proof_require: 0 <= start &&
  start < idx &&
  idx <= policies.length() &&
  remaining == policies.length() - idx &&
  all_parallel(policies, start, idx),
  proof_ensure: stop => wave_range_ok(policies, start, stop),
} {
  if remaining <= 0 {
    policies.length()
  } else {
    match policies[idx] {
      Parallel => {
        proof_assert all_parallel(policies, start, idx + 1)
        scan_parallel_end(policies, start, idx + 1, remaining - 1)
      }
      Sequential | Exclusive => idx
    }
  }
}

///|
pub fn next_wave_end(
  policies : FixedArray[Policy],
  start : Int32,
) -> Int32 where {
  proof_require: 0 <= start && start < policies.length(),
  proof_ensure: stop => wave_range_ok(policies, start, stop),
} {
  match policies[start] {
    Sequential | Exclusive => start + 1
    Parallel => {
      proof_assert all_parallel(policies, start, start + 1)
      scan_parallel_end(
        policies,
        start,
        start + 1,
        policies.length() - (start + 1),
      )
    }
  }
}
