///|
pub(all) enum ExposureLevel {
  Direct
  Deferred
  Disabled
}

///|
pub(all) struct UsageScalars {
  input_tokens : Int32?
  output_tokens : Int32?
  total_tokens : Int32?
  cached_input_tokens : Int32?
  uncached_input_tokens : Int32?
}

///|
pub fn exposure_narrow(
  left : ExposureLevel,
  right : ExposureLevel,
) -> ExposureLevel where {
  proof_ensure: result => exposure_narrow_post(left, right, result),
} {
  match (left, right) {
    (Disabled, _) | (_, Disabled) => Disabled
    (Deferred, _) | (_, Deferred) => Deferred
    (Direct, Direct) => Direct
  }
}

///|
pub fn next_monotonic_id(
  current : Int32,
) -> Int32 where {
  proof_require: current >= 0 && current < 2_147_483_647,
  proof_ensure: result => monotonic_next_post(current, result),
} {
  current + 1
}

///|
pub fn usage_scalars_valid(
  u : UsageScalars,
) -> Bool where {
  proof_ensure: result => result == usage_scalars_nonneg(u),
} {
  let ok_in = match u.input_tokens {
    Some(n) => n >= 0
    None => true
  }
  let ok_out = match u.output_tokens {
    Some(n) => n >= 0
    None => true
  }
  let ok_tot = match u.total_tokens {
    Some(n) => n >= 0
    None => true
  }
  let ok_cached = match u.cached_input_tokens {
    Some(n) => n >= 0
    None => true
  }
  let ok_uncached = match u.uncached_input_tokens {
    Some(n) => n >= 0
    None => true
  }
  ok_in && ok_out && ok_tot && ok_cached && ok_uncached
}
