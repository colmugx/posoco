///|
/// White-box tests for the compact diagnostic extractor (W1): allowlisted
/// fields parsed from the raw `ModelFailure` reason before its display
/// truncation; quoted excerpt content never becomes metadata; non-compact
/// effect failures keep their exact previous rendering.

///|
const DIAG_ADAPTER_HTTP_ERROR : String = "OpenAI HTTP error (stage=http_status, status=400, body_bytes=9312, body_category=utf8, body_excerpt=\"This model's maximum context length is 8192 tokens. However, your messages resulted in 9001 tokens.\", code=context_length_exceeded, param=input, request_id=req_diag_0001)"

///|
const DIAG_ADAPTER_PARSE_FAILURE : String = "OpenAI compact parse failure (stage=output, category=missing_output)"

///|
const DIAG_ADAPTER_TRANSPORT : String = "OpenAI transport failure (stage=read_response)"

///|
const DIAG_HOSTILE_EXCERPT : String = "OpenAI HTTP error (stage=http_status, status=400, body_bytes=64, body_category=utf8, body_excerpt=\"rejected (see: status=500 code=fake_from_body req=fake_body_id, then encrypted_content=AAAA)\", code=real_code, param=real_param, request_id=real_req_1)"

///|
test "compact_diag_parse/adapter_http_error_extracts_allowlisted_fields" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(reason=DIAG_ADAPTER_HTTP_ERROR),
  )
  guard diag is Some(parsed) else {
    fail("expected allowlisted fields to parse from the adapter verdict")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("stage=http_status"))
  assert_true(rendered.contains("status=400"))
  assert_true(rendered.contains("failure=Transport"))
  assert_true(rendered.contains("code=context_length_exceeded"))
  assert_true(rendered.contains("param=input"))
  assert_true(rendered.contains("request_id=req_diag_0001"))
  // Envelope keys and the quoted excerpt stay out entirely.
  assert_false(rendered.contains("body_bytes"))
  assert_false(rendered.contains("utf8"))
  assert_false(rendered.contains("body_excerpt"))
  assert_false(rendered.contains("maximum context length"))
}

///|
test "compact_diag_parse/parse_failure_stage_and_provider_category" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Parse(reason=DIAG_ADAPTER_PARSE_FAILURE),
  )
  guard diag is Some(parsed) else {
    fail("expected the parse-failure verdict fields to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("stage=output"))
  assert_true(rendered.contains("category=missing_output"))
  assert_true(rendered.contains("failure=Parse"))
  assert_false(rendered.contains("OpenAI compact parse failure"))
}

///|
test "compact_diag_parse/transport_stage" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(reason=DIAG_ADAPTER_TRANSPORT),
  )
  guard diag is Some(parsed) else {
    fail("expected the transport stage to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("stage=read_response"))
  assert_true(rendered.contains("failure=Transport"))
  assert_false(rendered.contains("OpenAI transport failure"))
}

///|
test "compact_diag_parse/quoted_excerpt_is_never_metadata" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(reason=DIAG_HOSTILE_EXCERPT),
  )
  guard diag is Some(parsed) else {
    fail("expected the real trailing fields to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("code=real_code"))
  assert_true(rendered.contains("param=real_param"))
  assert_true(rendered.contains("request_id=real_req_1"))
  assert_false(rendered.contains("fake_from_body"))
  assert_false(rendered.contains("fake_body_id"))
  assert_false(rendered.contains("status=500"))
  assert_false(rendered.contains("encrypted_content"))
}

///|
test "compact_diag_parse/aliases_and_bounded_values" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(
      reason="code=ok_code,http_status=429,error_code=dup_code,req=short",
    ),
  )
  guard diag is Some(parsed) else { fail("expected aliased fields to parse") }
  let rendered = parsed.render()
  assert_true(rendered.contains("status=429"))
  assert_true(rendered.contains("code=ok_code"))
  assert_true(rendered.contains("request_id=short"))
  // First occurrence wins; aliases do not overwrite.
  assert_false(rendered.contains("dup_code"))
  // Values are bounded like every other error label.
  let long_req = "req=" + "x".repeat(100)
  let bounded = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(reason=long_req),
  )
  guard bounded is Some(parsed_long) else {
    fail("expected the long request id to parse")
  }
  let long_rendered = parsed_long.render()
  assert_true(long_rendered.contains("...(truncated)"))
}

///|
test "compact_diag_parse/no_fields_falls_back_to_none" {
  assert_true(
    compact_diagnostic_of(
      @kernel.ModelFailure::Parse(reason="no compact endpoint"),
    )
    is None,
  )
  assert_true(
    compact_diagnostic_of(@kernel.ModelFailure::Transport(reason="timeout"))
    is None,
  )
}

///|
test "compact_diag_parse/rate_limited_uses_structured_provider_code" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::RateLimited(
      reason="quota exhausted",
      reset_at_ms=Some(1234L),
      provider_code=Some("usage_limit_reached"),
    ),
  )
  guard diag is Some(parsed) else {
    fail("expected the structured provider code to surface")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("failure=RateLimited"))
  assert_true(rendered.contains("code=usage_limit_reached"))
}

///|
test "compact_diag_parse/escaped_chars_inside_quotes_never_scanned" {
  // An escaped quote keeps the scanner inside the value; a backslashed
  // metadata lookalike is dropped with the rest of the quoted content.
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(
      reason="OpenAI HTTP error (stage=http_status, status=400, body_excerpt=\"a\\\" \\status=600 \\code=fake\", code=real_code)",
    ),
  )
  guard diag is Some(parsed) else {
    fail("expected the balanced escaped-quote structure to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("code=real_code"))
  assert_false(rendered.contains("status=600"))
  assert_false(rendered.contains("fake"))
}

///|
test "compact_diag_parse/malformed_quote_structures_rejected" {
  // Unterminated quoted value.
  assert_true(
    compact_diagnostic_of(
      @kernel.ModelFailure::Transport(
        reason="OpenAI HTTP error (stage=http_status, body_excerpt=\"unterminated",
      ),
    )
    is None,
  )
  // Quote inside a key position.
  assert_true(
    compact_diagnostic_of(
      @kernel.ModelFailure::Transport(
        reason="OpenAI HTTP error (\"stage\"=x, code=ok)",
      ),
    )
    is None,
  )
  // Quote opening after a non-empty value (mixed/early-closed structure).
  assert_true(
    compact_diagnostic_of(
      @kernel.ModelFailure::Transport(
        reason="OpenAI HTTP error (body_excerpt=oops\" , code=fake_from_body)",
      ),
    )
    is None,
  )
  // Two quoted values in one segment.
  assert_true(
    compact_diagnostic_of(
      @kernel.ModelFailure::Transport(
        reason="OpenAI HTTP error (body_excerpt=\"a\"\", code=fake)",
      ),
    )
    is None,
  )
}

///|
test "compact_diag_parse/envelope_suffix_ignored" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(
      reason="OpenAI transport failure (stage=read_response): IO timeout (status=600 code=fake request_id=fake_id)",
    ),
  )
  guard diag is Some(parsed) else {
    fail("expected the envelope stage to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.contains("stage=read_response"))
  assert_false(rendered.contains("status=600"))
  assert_false(rendered.contains("fake"))
}

///|
test "compact_diag_render/bounded_aggregate_prioritises_identifiers" {
  let diag = compact_diagnostic_of(
    @kernel.ModelFailure::Transport(
      reason="OpenAI HTTP error (stage=" +
        "s".repeat(64) +
        ", status=" +
        "4".repeat(64) +
        ", body_bytes=1, body_category=utf8, code=" +
        "c".repeat(64) +
        ", param=" +
        "p".repeat(64) +
        ", request_id=" +
        "r".repeat(64) +
        ")",
    ),
  )
  guard diag is Some(parsed) else {
    fail("expected the max-length fields to parse")
  }
  let rendered = parsed.render()
  assert_true(rendered.length() <= 352)
  assert_true(rendered.contains("request_id=" + "r".repeat(64)))
  assert_true(rendered.contains("code=" + "c".repeat(64)))
  assert_true(rendered.contains("status=" + "4".repeat(64)))
  // The lowest-priority fields yield first under the aggregate budget.
  assert_false(rendered.contains("param="))
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
test "compact_diag_cause/fields_replace_excerpt_fallback_keeps_display" {
  let with_fields = compact_failure_cause(
    @kernel.ModelFailure::Transport(reason=DIAG_ADAPTER_HTTP_ERROR),
  )
  assert_true(with_fields.contains("modelport compact failed: "))
  assert_true(with_fields.contains("code=context_length_exceeded"))
  assert_false(with_fields.contains("maximum context length"))
  let without_fields = compact_failure_cause(
    @kernel.ModelFailure::Parse(reason="no compact endpoint"),
  )
  let expected = "modelport compact failed: ModelFailure::Parse(no compact endpoint)"
  assert_true(without_fields == expected)
}

///|
test "compact_diag_parse/junk_after_closed_quote_rejects_all" {
  assert_true(compact_parse_fields("x (code=\"v\"junk)") is None)
  assert_true(compact_parse_fields("x (code=\"v\"=1)") is None)
  // Well-formed quoted value: the quoted content itself never reaches the
  // scanner (the key stores no value), while later plain fields still parse.
  let ok = compact_parse_fields("x (code=\"v\", status=400)")
  guard ok is Some(fields) else {
    fail("well-formed quoted value must still parse")
  }
  assert_true(fields.code is None)
  assert_eq(fields.status, Some("400"))
}
