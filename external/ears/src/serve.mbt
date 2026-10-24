///|
/// Guest entry point: greet the host, take the invoke frame, run the guest
/// program once, and emit the result frame. A raised `Failure::Failure`
/// becomes a failure result; other errors propagate to the runtime.
pub async fn serve(wire~ : &Wire, run~ : async (Ears, Json) -> Json) -> Unit {
  wire.send("{\"type\":\"hello\",\"protocol\":1}\n")
  guard wire.receive() is Some(line) else {
    fail("ears: host disconnected before the invoke frame")
  }
  let frame = @json.parse(line) catch {
    _ => fail("ears: invoke frame is not valid JSON")
  }
  guard frame
    is { "type": "invoke", "input": input, "tools": Array(raw_tools), .. } else {
    fail("ears: invalid host invoke frame")
  }
  let allowed = []
  for tool in raw_tools {
    if tool is String(name) {
      allowed.push(name)
    }
  }
  let ears = Ears::Ears(wire~, allowed~)
  let outcome : Outcome = try {
    let value = run(ears, input)
    Outcome::Success(content=value.stringify(), structured=Some(value))
  } catch {
    Failure::Failure(message) =>
      Outcome::Failure(code="GuestFailed", content=message, structured=None)
    error => raise error
  }
  ears.close()
  let result : Json = { "type": "result", "outcome": outcome.to_json() }
  wire.send(result.stringify() + "\n")
}
