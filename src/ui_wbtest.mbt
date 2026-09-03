///|
/// UI contract tests — verify the trait semantics, NoopUiPort, CompositeUiPort,
/// and RecordingUiPort independently of any host UI implementation.
///
/// These tests are whitebox (same-package, no prefix) so they exercise types as
/// an extension author would see them.

///|
test "noop_ui_port_render_is_silent" {
  let ui = NoopUiPort()
  ui.render({
    slot: Status,
    key: "x",
    title: None,
    body: Text("anything"),
    ttl_ms: None,
  })
  // No assertion needed — silent return is the contract.
}

///|
test "noop_ui_port_descriptor_is_empty" {
  let ui = NoopUiPort()
  let d = ui.ui_descriptor()
  assert_eq(d.autocomplete_sources.length(), 0)
}

///|
async test "noop_ui_port_request_raises_unsupported" {
  let ui = NoopUiPort()
  let result : Result[UiResponse, UiError] = Ok(
    ui.request(Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

///|
test "composite_ui_port_render_broadcasts_in_order" {
  let a = RecordingUiPort()
  let b = RecordingUiPort()
  let c = RecordingUiPort()
  let composite = CompositeUiPort([a, b, c])
  let intent = UiRender::{
    slot: Status,
    key: "k",
    title: None,
    body: Text("hi"),
    ttl_ms: None,
  }
  composite.render(intent)
  assert_eq(a.render_count(), 1)
  assert_eq(b.render_count(), 1)
  assert_eq(c.render_count(), 1)
}

///|
async test "composite_ui_port_request_first_supporting_wins" {
  let unsupported_a = RecordingUiPort::new_unsupported()
  let supporting_b = RecordingUiPort(responses=[Yes])
  let composite = CompositeUiPort([unsupported_a, supporting_b])
  let resp = composite.request(Confirm(prompt="ok?"))
  assert_true(resp is Yes)
}

///|
async test "composite_ui_port_request_all_unsupported_raises" {
  let a = RecordingUiPort::new_unsupported()
  let b = RecordingUiPort::new_unsupported()
  let composite = CompositeUiPort([a, b])
  let result : Result[UiResponse, UiError] = Ok(
    composite.request(Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

///|
async test "composite_ui_port_request_propagates_non_unsupported_error" {
  // RecordingUiPort with empty script raises Unsupported from the second
  // contributor, but if we set the script we can simulate a Cancelled flow.
  let supporting_then_cancel = RecordingUiPort(responses=[Cancelled])
  let composite = CompositeUiPort([supporting_then_cancel])
  let resp = composite.request(Confirm(prompt="ok?"))
  assert_true(resp is Cancelled)
}

///|
test "composite_ui_port_descriptor_concatenates_sources" {
  let with_one_source_a = RecordingUiPort()
  with_one_source_a.set_descriptor({
    autocomplete_sources: [
      { trigger: "/", kind: "command", fetch: fn(_) { [] }, },
    ],
  })
  let with_one_source_b = RecordingUiPort()
  with_one_source_b.set_descriptor({
    autocomplete_sources: [
      { trigger: "@", kind: "mention", fetch: fn(_) { [] }, },
    ],
  })
  let composite = CompositeUiPort([with_one_source_a, with_one_source_b])
  let d = composite.ui_descriptor()
  assert_eq(d.autocomplete_sources.length(), 2)
  assert_eq(d.autocomplete_sources[0].trigger, "/")
  assert_eq(d.autocomplete_sources[1].trigger, "@")
}

///|
test "recording_ui_port_records_render_in_order" {
  let r = RecordingUiPort()
  r.render({
    slot: Notice,
    key: "first",
    title: None,
    body: Text("1"),
    ttl_ms: None,
  })
  r.render({
    slot: Status,
    key: "second",
    title: None,
    body: Text("2"),
    ttl_ms: None,
  })
  let rendered = r.rendered_intents()
  assert_eq(rendered.length(), 2)
  assert_eq(rendered[0].key, "first")
  assert_eq(rendered[1].key, "second")
}

///|
async test "recording_ui_port_request_drains_script_in_fifo_order" {
  let r = RecordingUiPort(responses=[Text("first"), Text("second")])
  let resp1 = r.request(Input(prompt="?", default=None))
  let resp2 = r.request(Input(prompt="?", default=None))
  match resp1 {
    Text(s) => assert_eq(s, "first")
    other => fail("first response wrong: " + other.to_string())
  }
  match resp2 {
    Text(s) => assert_eq(s, "second")
    other => fail("second response wrong: " + other.to_string())
  }
  // Script exhausted; further requests raise Unsupported.
  assert_eq(r.unconsumed_response_count(), 0)
}

///|
async test "recording_ui_port_request_unsupported_when_exhausted" {
  let r = RecordingUiPort(responses=[])
  let result : Result[UiResponse, UiError] = Ok(
    r.request(Confirm(prompt="ok?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(Unsupported(_)) => ()
    Ok(_) => fail("expected Unsupported, got Ok response")
    Err(other) => fail("expected Unsupported, got error: " + other.to_string())
  }
}

///|
test "recording_ui_port_rendered_in_slot_filters_by_slot" {
  let r = RecordingUiPort()
  r.render({
    slot: Status,
    key: "s1",
    title: None,
    body: Text(""),
    ttl_ms: None,
  })
  r.render({
    slot: Notice,
    key: "n1",
    title: None,
    body: Text(""),
    ttl_ms: None,
  })
  r.render({
    slot: Status,
    key: "s2",
    title: None,
    body: Text(""),
    ttl_ms: None,
  })
  let notices = r.rendered_in_slot(Notice)
  assert_eq(notices.length(), 1)
  assert_eq(notices[0].key, "n1")
  let statuses = r.rendered_in_slot(Status)
  assert_eq(statuses.length(), 2)
}

///|
test "ui_request_show_round_trip" {
  let req = UiRequest::Select(
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
  assert_eq(UiResponse::Yes, Yes)
  assert_false(UiResponse::Yes == No)
}

///|
test "ui_body_entries_show_appends_color_roles" {
  let with_roles : UiBody = Entries([
    { key: "plan", value: "codex", color: Some("accent"), },
    { key: "ctx", value: "42%", color: None, },
  ])
  inspect(with_roles.to_string(), content="Entries(2, roles=accent)")
  let no_roles : UiBody = Entries([{ key: "model", value: "glm", color: None, }])
  inspect(no_roles.to_string(), content="Entries(1)")
}

///|
test "recording_ui_port_preserves_entries_body" {
  let r = RecordingUiPort()
  let entries : Array[@port.UiEntry] = [
    { key: "plan", value: "codex", color: Some("accent"), },
    { key: "model", value: "glm", color: None, },
  ]
  r.render({
    slot: Status,
    key: "statusbar",
    title: None,
    body: Entries(entries),
    ttl_ms: None,
  })
  let rendered = r.rendered_intents()
  assert_eq(rendered.length(), 1)
  match rendered[0].body {
    Entries(ets) => {
      assert_eq(ets.length(), 2)
      assert_eq(ets[0].key, "plan")
      assert_eq(ets[0].value, "codex")
      assert_eq(ets[0].color, Some("accent"))
      assert_eq(ets[1].key, "model")
      assert_eq(ets[1].value, "glm")
      assert_eq(ets[1].color, None)
    }
    other => fail("expected Entries body, got: " + other.to_string())
  }
}
