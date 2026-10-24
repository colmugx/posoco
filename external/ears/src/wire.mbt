///|
/// The guest's line-framed channel contract, abstracted so tests can script
/// a double. `send` writes one frame; `receive` returns one frame and
/// `None` at end of stream.
pub(open) trait Wire {
  async fn send(Self, frame : String) -> Unit
  async fn receive(Self) -> String?
}

///|
/// The default stdio transport.
pub struct StdioWire {}

///|
pub fn StdioWire::StdioWire() -> StdioWire {
  StdioWire::{ }
}

///|
impl Wire for StdioWire with fn send(self : StdioWire, frame : String) -> Unit raise {
  ignore(self)
  @stdio.stdout.write(frame)
}

///|
impl Wire for StdioWire with fn receive(self : StdioWire) -> String? raise {
  ignore(self)
  @stdio.stdin.read_until("\n")
}

///|
/// The stdio transport as a `&Wire` for `serve`.
pub fn stdio() -> &Wire {
  let wire : &Wire = StdioWire::StdioWire()
  wire
}
