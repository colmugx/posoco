///|
test "event_snapshot/tool_payload_and_custom_are_isolated" {
  let structured = Json::object(Map::from_array([("k", Json::string("v"))]))
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("c"),
    name: @kernel.ToolName::unchecked("tool"),
    arguments: Json::object(
      Map::from_array([("arg", Json::string("original"))]),
    ),
  }
  let success = snapshot_turn_event(
    ToolCallSucceeded(call~, content=[], structured=Some(structured), attachments=[]),
  )
  match structured {
    Object(fields) => fields["k"] = Json::string("poison")
    _ => fail("expected structured object")
  }
  match call.arguments {
    Object(fields) => fields["arg"] = Json::string("poison")
    _ => fail("expected arguments object")
  }
  guard success is ToolCallSucceeded(call~, structured=Some(value), ..) else {
    fail("expected success event")
  }
  match value {
    Object(fields) => assert_eq(fields["k"], Json::string("v"))
    _ => fail("expected structured snapshot")
  }
  match call.arguments {
    Object(fields) => assert_eq(fields["arg"], Json::string("original"))
    _ => fail("expected call snapshot")
  }
  let failure = snapshot_turn_event(
    ToolCallFailed(
      call~,
      failure=ReportedError(content=[], structured=Some(structured)),
    ),
  )
  guard failure
    is ToolCallFailed(call=_, failure=ReportedError(structured=Some(value), ..)) else {
    fail("expected reported failure")
  }
  match value {
    Object(fields) => assert_eq(fields["k"], Json::string("poison"))
    _ => fail("expected failure snapshot")
  }
  let custom_data = Json::object(
    Map::from_array([("c", Json::string("original"))]),
  )
  let custom = snapshot_turn_event(
    Custom(source="s", label="l", data=custom_data),
  )
  match custom_data {
    Object(fields) => fields["c"] = Json::string("poison")
    _ => fail("expected custom object")
  }
  guard custom is Custom(data~, ..) else { fail("expected custom") }
  match data {
    Object(fields) => assert_eq(fields["c"], Json::string("original"))
    _ => fail("expected custom snapshot")
  }
}

///|
test "event_snapshot/delivery_events_are_scalar_and_pass_through" {
  let applied = snapshot_turn_event(
    MessageApplied(command_id="cmd_1", delivery=Step),
  )
  assert_eq(applied, MessageApplied(command_id="cmd_1", delivery=Step))
  let undelivered = snapshot_turn_event(
    MessageUndelivered(
      command_id="cmd_2",
      delivery=Turn,
      reason="run ended first",
    ),
  )
  assert_eq(
    undelivered,
    MessageUndelivered(
      command_id="cmd_2",
      delivery=Turn,
      reason="run ended first",
    ),
  )
  assert_eq(
    Show::to_string(undelivered),
    "MessageUndelivered(command=cmd_2, delivery=turn, reason=run ended first)",
  )
}
