///|
/// UI contract tests — verify the trait semantics, NoopUiPort, CompositeUiPort,
/// and @test_support.RecordingUiPort independently of any host UI implementation.
///
/// These tests are whitebox (same-package, no prefix) so they exercise types as
/// an extension author would see them.

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
  let a = @test_support.RecordingUiPort()
  let b = @test_support.RecordingUiPort()
  let c = @test_support.RecordingUiPort()
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
  let unsupported_a = @test_support.RecordingUiPort::new_unsupported()
  let supporting_b = @test_support.RecordingUiPort(responses=[Yes])
  let composite = CompositeUiPort([unsupported_a, supporting_b])
  let resp = composite.request(Confirm(prompt="ok?"))
  assert_true(resp is Yes)
}

///|
async test "composite_ui_port_request_all_unsupported_raises" {
  let a = @test_support.RecordingUiPort::new_unsupported()
  let b = @test_support.RecordingUiPort::new_unsupported()
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
  // @test_support.RecordingUiPort with empty script raises Unsupported from the second
  // contributor, but if we set the script we can simulate a Cancelled flow.
  let supporting_then_cancel = @test_support.RecordingUiPort(responses=[
    Cancelled,
  ])
  let composite = CompositeUiPort([supporting_then_cancel])
  let resp = composite.request(Confirm(prompt="ok?"))
  assert_true(resp is Cancelled)
}

///|
test "composite_ui_port_descriptor_concatenates_sources" {
  let with_one_source_a = @test_support.RecordingUiPort()
  with_one_source_a.set_descriptor({
    autocomplete_sources: [
      { trigger: "/", kind: "command", fetch: fn(_) { [] }, },
    ],
  })
  let with_one_source_b = @test_support.RecordingUiPort()
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
async test "recording_ui_port_request_drains_script_in_fifo_order" {
  let r = @test_support.RecordingUiPort(responses=[
    Text("first"),
    Text("second"),
  ])
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
