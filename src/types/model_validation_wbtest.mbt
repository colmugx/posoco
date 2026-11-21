///|
test "tool_calls snapshots are isolated from later pushes and caller mutation" {
  let acc = StreamAccumulator()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("call_0"),
      name=Some("lookup"),
      arguments_delta=Some("{"),
    ),
  )
  let snapshots = acc.tool_calls()
  acc.push(
    ToolCallDelta(index=0, id=None, name=None, arguments_delta=Some("}")),
  )
  assert_eq(snapshots[0].arguments_json, "{")
  snapshots.push({ id: "fake", name: "fake", arguments_json: "{}", })
  let fresh = acc.tool_calls()
  assert_eq(fresh.length(), 1)
  let completion = acc.to_completion()
  assert_eq(completion.tool_calls().length(), 1)
  assert_eq(completion.tool_calls()[0].arguments, @json.parse("{}"))
}

///|
test "empty follow-up id/name deltas preserve first non-empty tool identity" {
  let acc = StreamAccumulator()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("call_0"),
      name=Some("lookup"),
      arguments_delta=Some("{\"a\":"),
    ),
  )
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some(""),
      name=Some(""),
      arguments_delta=Some("1}"),
    ),
  )
  let completion = acc.to_completion()
  assert_eq(completion.tool_calls().length(), 1)
  assert_eq(completion.tool_calls()[0].call_id.to_string(), "call_0")
  assert_eq(completion.tool_calls()[0].name.to_string(), "lookup")
  assert_eq(completion.tool_calls()[0].arguments, @json.parse("{\"a\":1}"))
}
