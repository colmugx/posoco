///|
/// `RecordingUiPort` — testkit UiPort that records every `render` and replies
/// to `request` from a scripted queue.
///
/// Use this in tests to:
/// - assert extensions emitted the expected render sequence;
/// - script request responses (Input/Confirm/Select) without a real UI;
/// - verify that downstream code reacts correctly to `Unsupported`/`Cancelled`.
///
/// The struct is intentionally not `pub(all)`-field-exposing: tests inspect
/// state through methods (`rendered_intents`, `next_request_response`, etc.)
/// so the recording layout can evolve without breaking tests.

// ──────────────────────────────────────────────────────────────────────────
// RecordingUiPort
// ──────────────────────────────────────────────────────────────────────────

///|
pub(all) struct RecordingUiPort {
  mut rendered : Array[@port.UiRender]
  /// Scripted responses, drained in FIFO order. Once empty, the next
  /// `request` raises `Unsupported` so tests fail loudly on unexpected
  /// interaction rather than hanging.
  mut scripted_responses : Array[@port.UiResponse]
  /// Whether `request` should raise `Unsupported` regardless of the script.
  /// Used to test the "no UI available" path. Defaults to false.
  mut unsupported_mode : Bool
  /// Descriptor returned by `ui_descriptor`. Defaults to empty; tests that
  /// need to verify descriptor aggregation set this explicitly.
  mut descriptor : @port.UiDescriptor
}

///|
/// Construct with a list of scripted responses. They will be returned in
/// order, one per `request` call.
pub fn RecordingUiPort::RecordingUiPort(
  responses? : Array[@port.UiResponse] = [],
) -> RecordingUiPort {
  {
    rendered: [],
    scripted_responses: responses.copy(),
    unsupported_mode: false,
    descriptor: @port.UiDescriptor::empty(),
  }
}

///|
/// Construct a UiPort that always raises `Unsupported` from `request`.
pub fn RecordingUiPort::new_unsupported() -> RecordingUiPort {
  let r = RecordingUiPort()
  r.unsupported_mode = true
  r
}

///|
/// All render intents received, in arrival order. The returned array is a
/// copy; mutating it does not affect the recording.
pub fn RecordingUiPort::rendered_intents(
  self : RecordingUiPort,
) -> Array[@port.UiRender] {
  self.rendered.copy()
}

///|
/// Number of render calls received.
pub fn RecordingUiPort::render_count(self : RecordingUiPort) -> Int {
  self.rendered.length()
}

///|
/// Filter rendered intents by slot. Useful for asserting "exactly one Notice
/// was emitted" without caring about other slots.
pub fn RecordingUiPort::rendered_in_slot(
  self : RecordingUiPort,
  slot : @port.UiSlot,
) -> Array[@port.UiRender] {
  let out : Array[@port.UiRender] = []
  for r in self.rendered {
    match (r.slot, slot) {
      (@port.Status, @port.Status)
      | (@port.Notice, @port.Notice)
      | (@port.Widget, @port.Widget) => out.push(r)
      _ => ()
    }
  }
  out
}

///|
/// Number of `request` calls that have NOT yet been answered (i.e. consumed
/// a scripted response). Useful to assert that no extra requests happened.
pub fn RecordingUiPort::unconsumed_response_count(
  self : RecordingUiPort,
) -> Int {
  self.scripted_responses.length()
}

///|
/// Set the descriptor returned by `ui_descriptor`.
pub fn RecordingUiPort::set_descriptor(
  self : RecordingUiPort,
  descriptor : @port.UiDescriptor,
) -> Unit {
  self.descriptor = descriptor
}

///|
pub impl @port.UiPort for RecordingUiPort with fn ui_descriptor(self) -> @port.UiDescriptor {
  self.descriptor
}

///|
pub impl @port.UiPort for RecordingUiPort with fn render(
  self,
  intent : @port.UiRender,
) -> Unit {
  self.rendered.push(intent)
}

///|
pub impl @port.UiPort for RecordingUiPort with fn request(
  self,
  _req : @port.UiRequest,
) -> @port.UiResponse {
  if self.unsupported_mode {
    raise @error.UiError::Unsupported(
      detail="RecordingUiPort is in unsupported_mode",
    )
  }
  // FIFO: drain from the front. Array::remove panics on out-of-bounds, so we
  // guard with an explicit length check and raise Unsupported (not a panic)
  // when the script is empty — that way CompositeUiPort can fall through and
  // tests see a typed error instead of a runtime crash.
  if self.scripted_responses.length() == 0 {
    raise @error.UiError::Unsupported(
      detail="RecordingUiPort script exhausted; no response for request",
    )
  }
  self.scripted_responses.remove(0)
}

///|
/// Expose UiPort methods on RecordingUiPort for dot-syntax callers.
pub extend RecordingUiPort with @port.UiPort::{ui_descriptor, render, request}
