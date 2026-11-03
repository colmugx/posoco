///|
/// White-box tests for the compact failure cause relay. Core does not parse
/// the `ModelFailure` reason: it forwards the adapter's opaque safe label —
/// bounded at the 352-character relay budget, newlines flattened — next to
/// the structural `ModelFailure` category, and the whole cause stays under
/// the user-approved 512-character outer error display. These tests pin the
/// generic contract: arbitrary failure formats (Unicode, quoting, `k=v`
/// lookalikes) are never interpreted into fields, labels stay bounded,
/// cancellation stays a distinct outcome, and non-compact phases keep the
/// old 64-character rendering.

///|
/// A label at the adapter's aggregate bound is relayed intact: the kernel's
/// 64-character display truncation does not apply on the compact cause path.
test "compact_diag_cause/labels_within_the_relay_budget_are_forwarded_intact" {
  let label = "p" + "q".repeat(351)
  let cause = compact_failure_cause(
    @kernel.ModelFailure::Transport(reason=label),
  )
  assert_true(cause.contains("ModelFailure::Transport(" + label + ")"))
  assert_false(cause.contains("...(truncated)"))
  // The relayed cause fits the user-approved 512-character outer display.
  assert_true(cause.length() <= 512)
}

///|
/// Content beyond the relay budget is capped: the far tail cannot resurface
/// and the truncation is marked.
test "compact_diag_cause/labels_beyond_the_relay_budget_are_capped" {
  let cause = compact_failure_cause(
    @kernel.ModelFailure::Transport(reason="p" + "q".repeat(400) + "FAR_TAIL"),
  )
  assert_true(cause.contains("...(truncated)"))
  assert_false(cause.contains("FAR_TAIL"))
  assert_true(cause.length() <= 512)
}
