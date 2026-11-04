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
