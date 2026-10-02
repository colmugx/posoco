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
test "compact_diag_cause/generic_failure_forwards_category_and_label" {
  let cause = compact_failure_cause(
    @kernel.ModelFailure::Transport(reason="upstream dropped the connection"),
  )
  assert_eq(
    cause, "modelport compact failed: ModelFailure::Transport(upstream dropped the connection)",
  )
}

///|
/// Every `ModelFailure` variant reaches the same path — the category name
/// plus its bounded label — with no variant-specific text schema.
test "compact_diag_cause/all_categories_take_the_same_path" {
  let cases = [
    (
      @kernel.ModelFailure::RequestBuild(reason="build broke"),
      "ModelFailure::RequestBuild",
    ),
    (
      @kernel.ModelFailure::Transport(reason="transport broke"),
      "ModelFailure::Transport",
    ),
    (
      @kernel.ModelFailure::Runtime(reason="runtime broke"),
      "ModelFailure::Runtime",
    ),
    (@kernel.ModelFailure::Parse(reason="parse broke"), "ModelFailure::Parse"),
    (
      @kernel.ModelFailure::HostRejected(reason="host said no"),
      "ModelFailure::HostRejected",
    ),
    (
      @kernel.ModelFailure::RateLimited(
        reason="quota broke",
        reset_at_ms=None,
        provider_code=None,
      ),
      "ModelFailure::RateLimited",
    ),
  ]
  for entry in cases {
    let (failure, category) = entry
    let cause = compact_failure_cause(failure)
    assert_true(cause.contains("modelport compact failed: "))
    assert_true(cause.contains(category))
  }
}

///|
/// Quotes, parentheses, commas, `k=v` lookalikes and non-ASCII text are just
/// characters in the label: nothing is rejected, extracted, or reordered.
test "compact_diag_cause/quoting_and_key_lookalikes_are_not_interpreted" {
  let reason = "adapter verdict (\"引文 (含, 逗号)\" , stage=假, status=503)"
  let cause = compact_failure_cause(@kernel.ModelFailure::Parse(reason~))
  assert_eq(
    cause,
    "modelport compact failed: ModelFailure::Parse(" + reason + ")",
  )
}

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

///|
test "compact_diag_cause/newlines_are_flattened_in_the_label" {
  let cause = compact_failure_cause(
    @kernel.ModelFailure::Runtime(reason="line one\nline two\rline three"),
  )
  assert_false(cause.contains("\n"))
  assert_false(cause.contains("\r"))
  assert_true(cause.contains("line one line two line three"))
}

///|
/// Structured quota fields stay structured: the compact cause carries only
/// the category and the safe bounded reason.
test "compact_diag_cause/rate_limited_keeps_category_and_reason_only" {
  let cause = compact_failure_cause(
    @kernel.ModelFailure::RateLimited(
      reason="quota window exhausted",
      reset_at_ms=Some(1234L),
      provider_code=Some("stays_structured"),
    ),
  )
  assert_eq(
    cause, "modelport compact failed: ModelFailure::RateLimited(quota window exhausted)",
  )
}

///|
/// Fallback: a reason with no envelope shape at all renders identically —
/// there is no separate extraction path to fall back from, and within the
/// relay budget the relay rendering coincides with the kernel display.
test "compact_diag_cause/plain_reason_matches_display_rendering" {
  let failure = @kernel.ModelFailure::Parse(reason="no compact endpoint")
  assert_eq(
    compact_failure_cause(failure),
    "modelport compact failed: " + failure.to_string(),
  )
}

///|
/// Compact-phase failure display carries the cause under the user-approved
/// 512-character bound: 43 wrapper characters + 512 kept + 14 marker + 1
/// closing parenthesis.
test "compact_diag_show/compact_phase_display_bounded_at_512" {
  let long_cause = "modelport compact failed: ModelFailure::Transport(" +
    "z".repeat(600) +
    "ENDOFTAIL)"
  let rendered = EffectExecutionFailed(phase="compact", cause=long_cause).to_string()
  assert_true(rendered.contains("phase=compact"))
  assert_true(rendered.contains("cause=modelport compact failed: "))
  assert_true(rendered.contains("...(truncated)"))
  assert_eq(rendered.length(), 570)
  // The kept head retains the category; the tail beyond the bound is gone.
  assert_true(rendered.contains("z".repeat(462)))
  assert_false(rendered.contains("ENDOFTAIL"))
}

///|
test "compact_diag_show/noncompact_effect_failure_keeps_exact_old_rendering" {
  let long_cause = "host defect: " + "y".repeat(120)
  let old = EffectExecutionFailed(phase="ExecuteTool", cause=long_cause)
  let rendered = old.to_string()
  assert_false(rendered.contains("cause="))
  assert_true(rendered.contains("...(truncated)"))
  assert_true(rendered.length() < 150)
  // The compact phases keep the labeled, wider rendering instead.
  let compact = EffectExecutionFailed(phase="compact_session", cause=long_cause)
  let compact_rendered = compact.to_string()
  assert_true(compact_rendered.contains("cause=host defect: "))
  assert_false(compact_rendered.contains("...(truncated)"))
}

///|
/// Cancellation is a distinct outcome: it carries no cause label in any
/// phase, so a cancelled compact can never render as a failed one.
test "compact_diag_cancel/cancellation_is_distinct_from_failure" {
  let cancelled = EffectExecutionCancelled(phase="compact_session").to_string()
  assert_eq(cancelled, "EffectExecutionCancelled(phase=compact_session)")
  assert_false(cancelled.contains("cause="))
  assert_false(cancelled.contains("...(truncated)"))
  assert_eq(
    EffectExecutionCancelled(phase="ExecuteTool").to_string(),
    "EffectExecutionCancelled(phase=ExecuteTool)",
  )
  // Only failure display consults the compact-phase gate.
  assert_true(is_compact_effect_phase("compact"))
  assert_true(is_compact_effect_phase("compact_session"))
  assert_true(is_compact_effect_phase("auto_compact"))
  assert_false(is_compact_effect_phase("ExecuteTool"))
}
