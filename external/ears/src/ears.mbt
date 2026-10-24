///|
/// Guest handle for calling host capabilities. Constructed by `serve` with
/// the host-declared capability list; policy denials come back as `Failure`
/// values, transport loss raises.
pub struct Ears {
  priv wire : &Wire
  priv lock : @async.Mutex
  priv mut next_id : Int32
  priv allowed : Array[String]
  priv mut closed : Bool
}

///|
pub fn Ears::Ears(wire~ : &Wire, allowed~ : Array[String]) -> Ears {
  {
    wire,
    lock: @async.Mutex(),
    next_id: 0,
    allowed: allowed.copy(),
    closed: false,
  }
}

///|
/// Call a host capability by name. `CapabilityDenied` and `ScopeClosed` are
/// local `Failure` values; a disconnected or malformed reply raises.
pub async fn Ears::call(
  self : Ears,
  name : String,
  arguments : Json,
) -> Outcome {
  if self.closed {
    return Failure(
      code="ScopeClosed",
      content="ears scope is closed",
      structured=None,
    )
  }
  if !self.allowed.contains(name) {
    return Failure(
      code="CapabilityDenied",
      content="capability is outside this invocation: " + name,
      structured=None,
    )
  }
  // One request on the wire at a time: concurrent branches may compute in
  // parallel, but reply correlation needs the request/reply round trip
  // serialized until a governed scheduler bridge exists.
  self.lock.acquire()
  defer self.lock.release()
  self.next_id += 1
  let id = self.next_id
  let request : Json = {
    "type": "request",
    "id": id,
    "name": name,
    "arguments": arguments,
  }
  self.wire.send(request.stringify() + "\n")
  guard self.wire.receive() is Some(line) else {
    fail("ears: host disconnected while waiting for a reply")
  }
  let frame = @json.parse(line) catch {
    _ => fail("ears: reply frame is not valid JSON")
  }
  guard frame is Object(fields) else {
    fail("ears: reply frame must be an object")
  }
  guard fields.get("type") is Some(String("reply")) else {
    fail("ears: reply frame has the wrong type")
  }
  guard fields.get("outcome") is Some(outcome_value) else {
    fail("ears: reply frame is missing its outcome")
  }
  guard fields.get("id") is Some(Number(value, ..)) && value == id.to_double() else {
    fail("ears: reply frame does not answer request \{id}")
  }
  Outcome::from_json(outcome_value)
}

///|
/// Emit a diagnostic to the host. The host decides visibility; this is not
/// output returned to the model. Ignored after `close`.
pub async fn Ears::log(
  self : Ears,
  level~ : String = "info",
  content : String,
) -> Unit {
  if self.closed {
    return
  }
  let frame : Json = { "type": "log", "level": level, "content": content }
  self.wire.send(frame.stringify() + "\n")
}

///|
pub fn Ears::close(self : Ears) -> Unit {
  self.closed = true
}
