///|
/// Test double for `@ears.Wire`: records every sent frame and hands back
/// queued replies in order (empty queue means end of stream).
struct ScriptedWire {
  outgoing : Array[String]
  pending : Array[String]
}

///|
fn ScriptedWire::scripted(replies : Array[String]) -> ScriptedWire {
  let pending = []
  for reply in replies {
    pending.insert(0, reply)
  }
  { outgoing: [], pending, }
}

///|
impl @ears.Wire for ScriptedWire with fn send(
  self : ScriptedWire,
  frame : String,
) -> Unit raise {
  self.outgoing.push(frame)
}

///|
impl @ears.Wire for ScriptedWire with fn receive(self : ScriptedWire) -> String? raise {
  self.pending.pop()
}

///|
fn reply_frame(id : Int32, outcome : Json) -> String {
  let frame : Json = { "type": "reply", "id": id, "outcome": outcome }
  frame.stringify()
}

///|
async test "call returns a success outcome and correlates the reply id" {
  let wire = ScriptedWire::scripted([
    reply_frame(1, {
      "kind": "success",
      "content": "ok",
      "structured": { "n": 1 },
    }),
  ])
  let ears = @ears.Ears::Ears(wire~, allowed=["read"])
  let outcome = ears.call("read", { "path": "README.md" })
  guard outcome is @ears.Success(content="ok", structured=Some({ "n": 1, .. })) else {
    fail("success outcome did not survive the round trip")
  }
  assert_true(wire.outgoing[0].contains("\"type\":\"request\""))
  assert_true(wire.outgoing[0].contains("\"name\":\"read\""))
}

///|
async test "failure outcomes are values a guest branches on" {
  let wire = ScriptedWire::scripted([
    reply_frame(1, { "kind": "failure", "code": "NotFound", "content": "gone" }),
  ])
  let ears = @ears.Ears::Ears(wire~, allowed=["read"])
  guard ears.call("read", {})
    is @ears.Failure(code="NotFound", content="gone", ..) else {
    fail("failure outcome did not survive the round trip")
  }
}

///|
async test "capability denial is a local value and never touches the wire" {
  let wire = ScriptedWire::scripted([])
  let ears = @ears.Ears::Ears(wire~, allowed=[])
  guard ears.call("exec", {}) is @ears.Failure(code="CapabilityDenied", ..) else {
    fail("denied call was not rejected locally")
  }
  assert_eq(wire.outgoing.length(), 0)
}

///|
async test "a closed scope denies further calls" {
  let wire = ScriptedWire::scripted([])
  let ears = @ears.Ears::Ears(wire~, allowed=["read"])
  ears.close()
  guard ears.call("read", {}) is @ears.Failure(code="ScopeClosed", ..) else {
    fail("closed scope accepted a call")
  }
}

///|
async test "transport loss raises instead of fabricating an outcome" {
  let wire = ScriptedWire::scripted([])
  let ears = @ears.Ears::Ears(wire~, allowed=["read"])
  try ears.call("read", {}) catch {
    Failure::Failure(message) => assert_true(message.contains("disconnected"))
    error => fail("unexpected error: \{error}")
  } noraise {
    _ => fail("disconnected call returned an outcome")
  }
}

///|
async test "malformed reply raises with the offending request id" {
  let wire = ScriptedWire::scripted([reply_frame(7, { "kind": "success" })])
  let ears = @ears.Ears::Ears(wire~, allowed=["read"])
  try ears.call("read", {}) catch {
    Failure::Failure(message) => assert_true(message.contains("request 1"))
    error => fail("unexpected error: \{error}")
  } noraise {
    _ => fail("mismatched reply was accepted")
  }
}

///|
test "outcome json round trip is lenient about optional fields" {
  let success : @ears.Outcome = @ears.Success(content="ok", structured=None)
  assert_eq(@ears.Outcome::from_json(success.to_json()), success)
  let minimal : Json = { "kind": "failure", "code": "Denied" }
  guard @ears.Outcome::from_json(minimal) is @ears.Failure(content="", ..) else {
    fail("lenient parse failed")
  }
}

///|
async test "serve greets, consumes the invoke frame and emits the result" {
  let invoke : Json = {
    "type": "invoke",
    "input": { "n": 2 },
    "tools": ["double"],
  }
  let wire = ScriptedWire::scripted([invoke.stringify()])
  @ears.serve(wire~, run=(_ears, input) => {
    guard input is { "n": Number(n, ..), .. } else { fail("bad input") }
    { "doubled": n * 2.0 }
  })
  assert_true(wire.outgoing[0].contains("\"type\":\"hello\""))
  assert_true(wire.outgoing[0].contains("\"protocol\":1"))
  assert_true(wire.outgoing[1].contains("\"type\":\"result\""))
  assert_true(wire.outgoing[1].contains("\"kind\":\"success\""))
  assert_true(wire.outgoing[1].contains("\"doubled\":4"))
}

///|
async test "serve turns a guest fail into a failure result" {
  let invoke : Json = { "type": "invoke", "input": Json::null(), "tools": [] }
  let wire = ScriptedWire::scripted([invoke.stringify()])
  @ears.serve(wire~, run=(_ears, _input) => {
    fail("ears guest refused the input")
    Json::null()
  })
  assert_true(wire.outgoing[1].contains("\"type\":\"result\""))
  assert_true(wire.outgoing[1].contains("\"code\":\"GuestFailed\""))
  assert_true(wire.outgoing[1].contains("refused the input"))
}
