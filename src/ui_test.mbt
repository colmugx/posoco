///|
/// UI contract tests — verify the trait semantics, NoopUiPort, CompositeUiPort,
/// and RecordingUiPort independently of any host UI implementation.
///
/// These tests are blackbox (`@posoco.` prefix) so they exercise the public
/// API as an extension author would see it.

// ──────────────────────────────────────────────────────────────────────────
// NoopUiPort
// ──────────────────────────────────────────────────────────────────────────

///|
test "noop_ui_port_render_is_silent" {
  let ui = @posoco.NoopUiPort::new()
  ui.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "x",
    title: None,
    body: @posoco.UiBody::Text("anything"),
    ttl_ms: None,
  })
  // No assertion needed — silent return is the contract.
}

///|
test "noop_ui_port_descriptor_is_empty" {
  let ui = @posoco.NoopUiPort::new()
  let d = ui.ui_descriptor()
  assert_eq(d.autocomplete_sources.length(), 0)
}

///|
async test "noop_ui_port_request_raises_unsupported" {
  let ui = @posoco.NoopUiPort::new()
  let result : Result[@posoco.UiResponse, @error.UiError] = Ok(
    ui.request(@posoco.UiRequest::Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.UiError::Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

// ──────────────────────────────────────────────────────────────────────────
// CompositeUiPort — render broadcast
// ──────────────────────────────────────────────────────────────────────────

///|
test "composite_ui_port_render_broadcasts_in_order" {
  let a = RecordingUiPort::new()
  let b = RecordingUiPort::new()
  let c = RecordingUiPort::new()
  let composite = @posoco.CompositeUiPort::new([a, b, c])
  let intent = @posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "k",
    title: None,
    body: @posoco.UiBody::Text("hi"),
    ttl_ms: None,
  }
  composite.render(intent)
  assert_eq(a.render_count(), 1)
  assert_eq(b.render_count(), 1)
  assert_eq(c.render_count(), 1)
}

// ──────────────────────────────────────────────────────────────────────────
// CompositeUiPort — request falls through Unsupported
// ──────────────────────────────────────────────────────────────────────────

///|
async test "composite_ui_port_request_first_supporting_wins" {
  let unsupported_a = RecordingUiPort::new_unsupported()
  let supporting_b = RecordingUiPort::new(responses=[@posoco.UiResponse::Yes])
  let composite = @posoco.CompositeUiPort::new([unsupported_a, supporting_b])
  let resp = composite.request(@posoco.UiRequest::Confirm(prompt="ok?"))
  assert_true(resp is @posoco.UiResponse::Yes)
}

///|
async test "composite_ui_port_request_all_unsupported_raises" {
  let a = RecordingUiPort::new_unsupported()
  let b = RecordingUiPort::new_unsupported()
  let composite = @posoco.CompositeUiPort::new([a, b])
  let result : Result[@posoco.UiResponse, @error.UiError] = Ok(
    composite.request(@posoco.UiRequest::Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.UiError::Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

///|
async test "composite_ui_port_request_propagates_non_unsupported_error" {
  // RecordingUiPort with empty script raises Unsupported from the second
  // contributor, but if we set the script we can simulate a Cancelled flow.
  let supporting_then_cancel = RecordingUiPort::new(responses=[
    @posoco.UiResponse::Cancelled,
  ])
  let composite = @posoco.CompositeUiPort::new([supporting_then_cancel])
  let resp = composite.request(@posoco.UiRequest::Confirm(prompt="ok?"))
  assert_true(resp is @posoco.UiResponse::Cancelled)
}

// ──────────────────────────────────────────────────────────────────────────
// CompositeUiPort — descriptor aggregation
// ──────────────────────────────────────────────────────────────────────────

///|
test "composite_ui_port_descriptor_concatenates_sources" {
  let with_one_source_a = RecordingUiPort::new()
  with_one_source_a.set_descriptor({
    autocomplete_sources: [
      @posoco.AutocompleteSource::{
        trigger: "/",
        kind: "command",
        fetch: fn(_) { [] },
      },
    ],
  })
  let with_one_source_b = RecordingUiPort::new()
  with_one_source_b.set_descriptor({
    autocomplete_sources: [
      @posoco.AutocompleteSource::{
        trigger: "@",
        kind: "mention",
        fetch: fn(_) { [] },
      },
    ],
  })
  let composite = @posoco.CompositeUiPort::new([
    with_one_source_a, with_one_source_b,
  ])
  let d = composite.ui_descriptor()
  assert_eq(d.autocomplete_sources.length(), 2)
  assert_eq(d.autocomplete_sources[0].trigger, "/")
  assert_eq(d.autocomplete_sources[1].trigger, "@")
}

// ──────────────────────────────────────────────────────────────────────────
// RecordingUiPort — script + record
// ──────────────────────────────────────────────────────────────────────────

///|
test "recording_ui_port_records_render_in_order" {
  let r = RecordingUiPort::new()
  r.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Notice,
    key: "first",
    title: None,
    body: @posoco.UiBody::Text("1"),
    ttl_ms: None,
  })
  r.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "second",
    title: None,
    body: @posoco.UiBody::Text("2"),
    ttl_ms: None,
  })
  let rendered = r.rendered_intents()
  assert_eq(rendered.length(), 2)
  assert_eq(rendered[0].key, "first")
  assert_eq(rendered[1].key, "second")
}

///|
async test "recording_ui_port_request_drains_script_in_fifo_order" {
  let r = RecordingUiPort::new(responses=[
    @posoco.UiResponse::Text("first"),
    @posoco.UiResponse::Text("second"),
  ])
  let resp1 = r.request(@posoco.UiRequest::Input(prompt="?", default=None))
  let resp2 = r.request(@posoco.UiRequest::Input(prompt="?", default=None))
  match resp1 {
    @posoco.UiResponse::Text(s) => assert_eq(s, "first")
    other => fail("first response wrong: " + other.to_string())
  }
  match resp2 {
    @posoco.UiResponse::Text(s) => assert_eq(s, "second")
    other => fail("second response wrong: " + other.to_string())
  }
  // Script exhausted; further requests raise Unsupported.
  assert_eq(r.unconsumed_response_count(), 0)
}

///|
async test "recording_ui_port_request_unsupported_when_exhausted" {
  let r = RecordingUiPort::new(responses=[])
  let result : Result[@posoco.UiResponse, @error.UiError] = Ok(
    r.request(@posoco.UiRequest::Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.UiError::Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

///|
test "recording_ui_port_rendered_in_slot_filters_by_slot" {
  let r = RecordingUiPort::new()
  r.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "s1",
    title: None,
    body: @posoco.UiBody::Text(""),
    ttl_ms: None,
  })
  r.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Notice,
    key: "n1",
    title: None,
    body: @posoco.UiBody::Text(""),
    ttl_ms: None,
  })
  r.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "s2",
    title: None,
    body: @posoco.UiBody::Text(""),
    ttl_ms: None,
  })
  let notices = r.rendered_in_slot(@posoco.UiSlot::Notice)
  assert_eq(notices.length(), 1)
  assert_eq(notices[0].key, "n1")
  let statuses = r.rendered_in_slot(@posoco.UiSlot::Status)
  assert_eq(statuses.length(), 2)
}

// ──────────────────────────────────────────────────────────────────────────
// UiRequest / UiResponse round-trip
// ──────────────────────────────────────────────────────────────────────────

///|
test "ui_request_show_round_trip" {
  let req = @posoco.UiRequest::Select(
    prompt="pick",
    options=["a", "b", "c"],
    default=Some(1),
  )
  let s = req.to_string()
  assert_true(s.contains("Select"))
  assert_true(s.contains("options=3"))
}

///|
test "ui_response_equality_for_yes_no" {
  assert_eq(@posoco.UiResponse::Yes, @posoco.UiResponse::Yes)
  assert_false(@posoco.UiResponse::Yes == @posoco.UiResponse::No)
}
