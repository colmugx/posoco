///|
test "Session::with_parent_thread_id: round-trips through metadata" {
  let base : Session = {
    messages: [],
    metadata: Map::from_array([("custom", Json::string("preserved"))]),
  }
  let derived = base.with_parent_thread_id("parent-123")
  // Lineage readable.
  assert_eq(derived.parent_thread_id(), Some("parent-123"))
  // Existing metadata preserved.
  assert_eq(derived.metadata.get("custom"), Some(Json::string("preserved")))
  // Base session unchanged.
  assert_true(base.parent_thread_id() is None)
}

///|
test "MessageDeliveryKind: Eq/Debug/Show follow the shared conventions" {
  let step : MessageDeliveryKind = Step
  let turn : MessageDeliveryKind = Turn
  assert_true(step == Step)
  assert_true(turn == Turn)
  assert_false(step == turn)
  assert_eq(Show::to_string(step), "step")
  assert_eq(Show::to_string(turn), "turn")
  assert_true("\{Debug::to_repr(step)}".contains("Step"))
  assert_true("\{Debug::to_repr(turn)}".contains("Turn"))
}

///|
test "TurnEvent delivery events: format and compare like every variant" {
  let applied : TurnEvent = MessageApplied(command_id="cmd_1", delivery=Step)
  let undelivered : TurnEvent = MessageUndelivered(
    command_id="cmd_2",
    delivery=Step,
    reason="run ended first",
  )
  assert_eq(
    Show::to_string(applied),
    "MessageApplied(command=cmd_1, delivery=step)",
  )
  assert_eq(
    Show::to_string(undelivered),
    "MessageUndelivered(command=cmd_2, delivery=step, reason=run ended first)",
  )
  assert_true(applied == MessageApplied(command_id="cmd_1", delivery=Step))
  // Delivery kind is part of the event identity.
  assert_true(
    undelivered !=
    MessageUndelivered(
      command_id="cmd_2",
      delivery=Turn,
      reason="run ended first",
    ),
  )
  assert_true("\{Debug::to_repr(applied)}".contains("cmd_1"))
  assert_true("\{Debug::to_repr(undelivered)}".contains("run ended first"))
}
