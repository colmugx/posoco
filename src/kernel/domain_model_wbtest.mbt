///|
/// Adapter-boundary contract for `ModelFailure`: every variant reason is a
/// safe bounded label — never a raw provider payload. The display keeps the
/// first 64 characters, flattens line breaks, and marks truncation, so
/// downstream layers can forward the rendering without interpreting it.

///|
test "modelfailure_display/long_labels_bounded_at_64_with_marker" {
  let rendered = Transport(reason="x".repeat(100)).to_string()
  assert_eq(
    rendered,
    "ModelFailure::Transport(" + "x".repeat(64) + "...(truncated))",
  )
}

///|
test "modelfailure_display/quoting_and_key_lookalikes_stay_inert_text" {
  let reason = "adapter verdict (\"引文 (含, 逗号)\" , stage=假, status=503)"
  assert_eq(
    Transport(reason~).to_string(),
    "ModelFailure::Transport(" + reason + ")",
  )
}

///|
test "modelfailure_display/newlines_flattened_in_label" {
  let rendered = ModelFailure::Runtime(reason="line one\nline two\rline three").to_string()
  assert_false(rendered.contains("\n"))
  assert_false(rendered.contains("\r"))
  assert_true(rendered.contains("line one line two line three"))
}

///|
test "modelfailure_display/payload_tail_never_survives_the_bound" {
  let failure = Parse(reason="head of the label " + "m".repeat(80) + "TAILMARK")
  let rendered = failure.to_string()
  assert_true(rendered.contains("...(truncated)"))
  assert_false(rendered.contains("TAILMARK"))
}

///|
test "modelfailure_display/rate_limited_renders_reason_label_only" {
  let rendered = RateLimited(
    reason="quota window exhausted",
    reset_at_ms=Some(1234L),
    provider_code=Some("stays_structured"),
  ).to_string()
  assert_eq(rendered, "ModelFailure::RateLimited(quota window exhausted)")
}
