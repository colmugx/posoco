///|
/// Boundary tests for provider usage and streaming-index validation.

///|
test "usage validator rejects every negative optional field" {
  let cases : Array[(String, @kernel.Usage)] = [
    (
      "input_tokens",
      {
        input_tokens: Some(-1),
        output_tokens: None,
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      },
    ),
    (
      "output_tokens",
      {
        input_tokens: None,
        output_tokens: Some(-1),
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      },
    ),
    (
      "total_tokens",
      {
        input_tokens: None,
        output_tokens: None,
        total_tokens: Some(-1),
        cached_input_tokens: None,
        uncached_input_tokens: None,
      },
    ),
    (
      "cached_input_tokens",
      {
        input_tokens: None,
        output_tokens: None,
        total_tokens: None,
        cached_input_tokens: Some(-1),
        uncached_input_tokens: None,
      },
    ),
    (
      "uncached_input_tokens",
      {
        input_tokens: None,
        output_tokens: None,
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: Some(-1),
      },
    ),
  ]
  for case in cases {
    let (field, usage) = case
    match usage.validate() {
      Err(reason) => assert_true(reason.contains(field))
      Ok(_) => fail("negative usage." + field + " was accepted")
    }
  }
  let valid : @kernel.Usage = {
    input_tokens: Some(0),
    output_tokens: Some(0),
    total_tokens: Some(0),
    cached_input_tokens: Some(0),
    uncached_input_tokens: Some(0),
  }
  assert_true(valid.validate() is Ok(_))
}

///|
test "stream chunk validator rejects negative token counts and indexes" {
  let negative_index = ToolCallDelta(
    index=-1,
    id=None,
    name=None,
    arguments_delta=None,
  )
  match negative_index.validate() {
    Err(reason) => assert_true(reason.contains("index"))
    Ok(_) => fail("negative stream tool-call index was accepted")
  }
  let negative_usage = Usage(
    input_tokens=-1,
    output_tokens=0,
    total_tokens=0,
    cached_input_tokens=None,
    uncached_input_tokens=None,
  )
  match negative_usage.validate() {
    Err(reason) => assert_true(reason.contains("input_tokens"))
    Ok(_) => fail("negative stream usage was accepted")
  }
  let acc = StreamAccumulator()
  let result : Result[Unit, @error.ModelError] = Ok(acc.push(negative_index)) catch {
    error => Err(error)
  }
  match result {
    Err(ResponseParse(reason)) => assert_true(reason.contains("index"))
    _ => fail("negative stream index did not raise ResponseParse")
  }
  assert_eq(acc.tool_calls.length(), 0)
}

///|
test "accumulator rejects sparse index without partial mutation" {
  let acc = StreamAccumulator()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("first"),
      name=Some("echo"),
      arguments_delta=Some("{}"),
    ),
  )
  let result : Result[Unit, @error.ModelError] = Ok(
    acc.push(
      ToolCallDelta(
        index=2,
        id=Some("sparse"),
        name=Some("bad"),
        arguments_delta=Some("{}"),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(ResponseParse(reason)) => assert_true(reason.contains("sparse"))
    _ => fail("sparse stream tool-call index did not raise ResponseParse")
  }
  assert_eq(acc.tool_calls.length(), 1)
  assert_eq(acc.tool_calls[0].id, "first")
  assert_eq(acc.tool_calls[0].name, "echo")
  assert_eq(acc.tool_calls[0].arguments_json(), "{}")
}

///|
test "accumulator rejects invalid usage before mutation" {
  let acc = StreamAccumulator()
  let result : Result[Unit, @error.ModelError] = Ok(
    acc.push(
      Usage(
        input_tokens=1,
        output_tokens=-2,
        total_tokens=3,
        cached_input_tokens=None,
        uncached_input_tokens=None,
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(ResponseParse(reason)) => assert_true(reason.contains("output_tokens"))
    _ => fail("negative stream usage did not raise ResponseParse")
  }
  assert_eq(acc.tool_calls.length(), 0)
  assert_eq(acc.text(), "")
  assert_eq(acc.reasoning(), "")
  assert_true(acc.usage_input is None)
  assert_true(acc.usage_output is None)
  assert_true(acc.usage_total is None)
}

///|
test "accumulator accepts only contiguous new tool indexes" {
  let acc = StreamAccumulator()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("first"),
      name=Some("echo"),
      arguments_delta=Some("{}"),
    ),
  )
  acc.push(
    ToolCallDelta(
      index=1,
      id=Some("second"),
      name=Some("echo"),
      arguments_delta=Some("{}"),
    ),
  )
  acc.push(
    ToolCallDelta(index=0, id=None, name=None, arguments_delta=Some(" ")),
  )
  assert_eq(acc.tool_calls.length(), 2)
  assert_eq(acc.tool_calls[0].arguments_json(), "{} ")
}

///|
test "to_completion revalidates internally polluted usage" {
  let acc = StreamAccumulator()
  // This simulates a package-local mutation or future builder bug. The
  // negative value must not be hidden merely because total_tokens is absent
  // and the projected completion would otherwise omit usage altogether.
  acc.usage_input = Some(-7)
  let result : Result[@kernel.Completion, @error.ModelError] = Ok(
    acc.to_completion(),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(ResponseParse(reason)) => assert_true(reason.contains("input_tokens"))
    _ => fail("to_completion accepted internally invalid usage")
  }
}

///|
test "tool_calls snapshots reflect accumulated state in index order" {
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
    ToolCallDelta(index=0, id=None, name=None, arguments_delta=Some("1}")),
  )
  acc.push(
    ToolCallDelta(
      index=1,
      id=Some("call_1"),
      name=Some("noop"),
      arguments_delta=None,
    ),
  )
  let snapshots = acc.tool_calls()
  assert_eq(snapshots.length(), 2)
  assert_eq(snapshots[0].id, "call_0")
  assert_eq(snapshots[0].name, "lookup")
  assert_eq(snapshots[0].arguments_json, "{\"a\":1}")
  assert_eq(snapshots[1].id, "call_1")
  assert_eq(snapshots[1].name, "noop")
  // Partial state stays visible through the snapshot: an arguments delta has
  // not arrived for index 1 yet, so its accumulated JSON is still empty.
  assert_eq(snapshots[1].arguments_json, "")
}

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
  // The earlier snapshot is frozen: a later push cannot rewrite it.
  assert_eq(snapshots[0].arguments_json, "{")
  // Tampering with a returned array must not touch the accumulator.
  snapshots.push({ id: "fake", name: "fake", arguments_json: "{}", })
  let fresh = acc.tool_calls()
  assert_eq(fresh.length(), 1)
  let completion = acc.to_completion()
  assert_eq(completion.tool_calls().length(), 1)
  assert_eq(completion.tool_calls()[0].arguments, @json.parse("{}"))
}
