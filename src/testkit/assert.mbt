// ---------------------------------------------------------------------------
// Trace assertions — structured helpers that report the first differing index.
// ---------------------------------------------------------------------------

///|
/// Return the first structural trace mismatch. Kept pure so conformance tests
/// can prove missing, duplicate, and out-of-order detection without catching
/// an assertion panic.
pub fn event_trace_mismatch(
  expected : Array[@types.TurnEvent],
  actual : Array[@types.TurnEvent],
) -> String? {
  let n = if expected.length() < actual.length() {
    expected.length()
  } else {
    actual.length()
  }
  for i = 0; i < n; i = i + 1 {
    if expected[i] != actual[i] {
      return Some(
        "event_trace_mismatch at index \{i}: expected \{expected[i].to_string()}, got \{actual[i].to_string()}",
      )
    }
  }
  if expected.length() != actual.length() {
    let index = n
    if expected.length() > actual.length() {
      return Some(
        "event_trace_mismatch at index \{index}: expected \{expected[index].to_string()}, got <end> (expected \{expected.length()} events, actual \{actual.length()})",
      )
    } else {
      return Some(
        "event_trace_mismatch at index \{index}: expected <end>, got \{actual[index].to_string()} (expected \{expected.length()} events, actual \{actual.length()})",
      )
    }
  }
  None
}

///|
/// Assert two event traces are equal, reporting the first differing index,
/// the expected and actual event, when they diverge.
pub fn assert_events_eq(
  expected : Array[@types.TurnEvent],
  actual : Array[@types.TurnEvent],
) -> Unit {
  match event_trace_mismatch(expected, actual) {
    Some(message) => abort(message)
    None => ()
  }
}

///|
/// Assert the recorded events contain a sub-sequence matching `needle`, in
/// order. Reports the first needle event that could not be matched.
pub fn assert_events_contain(
  haystack : Array[@types.TurnEvent],
  needle : Array[@types.TurnEvent],
) -> Unit {
  if needle.is_empty() {
    return
  }
  let mut hi = 0
  for ni = 0; ni < needle.length(); ni = ni + 1 {
    let mut found = false
    while hi < haystack.length() {
      if haystack[hi] == needle[ni] {
        found = true
        hi = hi + 1
        break
      }
      hi = hi + 1
    }
    if !found {
      abort(
        "event_not_found_in_order: needle[\{ni}] = \{needle[ni].to_string()} not matched after haystack index \{hi}",
      )
    }
  }
}
