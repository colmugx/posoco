///|
/// Built-in UiPort implementations: no-op default and fan-out composite.

// NoopUiPort

///|
/// Default UiPort for headless hosts. `request` raises `Unsupported`.
pub(all) struct NoopUiPort {}

///|
pub fn NoopUiPort::NoopUiPort() -> NoopUiPort {
  NoopUiPort::{  }
}

///|
pub impl UiPort for NoopUiPort with fn ui_descriptor(_self) -> UiDescriptor {
  UiDescriptor::empty()
}

///|
pub impl UiPort for NoopUiPort with fn render(_self, _intent) -> Unit {

}

///|
pub impl UiPort for NoopUiPort with fn request(_self, _req) -> UiResponse {
  raise @error.UiError::Unsupported(detail="NoopUiPort has no UI backend")
}

///|
pub extend NoopUiPort with UiPort::{ui_descriptor, render, request}

// CompositeUiPort

///|
/// Fan-out UiPort: `render` delivers to every contributor; `request` tries
/// each in order, first non-`Unsupported` wins.
pub(all) struct CompositeUiPort {
  contributors : Array[&UiPort]
}

///|
pub fn CompositeUiPort::CompositeUiPort(
  contributors : Array[&UiPort],
) -> CompositeUiPort {
  { contributors, }
}

///|
pub fn CompositeUiPort::contributors(self : CompositeUiPort) -> Array[&UiPort] {
  self.contributors.copy()
}

///|
/// Concatenate autocomplete sources in registration order.
pub impl UiPort for CompositeUiPort with fn ui_descriptor(self) -> UiDescriptor {
  let sources : Array[AutocompleteSource] = []
  for c in self.contributors {
    let d = c.ui_descriptor()
    for s in d.autocomplete_sources {
      sources.push(s)
    }
  }
  { autocomplete_sources: sources }
}

///|
/// Broadcast to every contributor in registration order. Best-effort.
pub impl UiPort for CompositeUiPort with fn render(self, intent) -> Unit {
  for c in self.contributors {
    c.render(intent)
  }
}

///|
/// Try each contributor in order. First non-`Unsupported` result wins;
/// all-`Unsupported` raises `Unsupported`.
pub impl UiPort for CompositeUiPort with fn request(self, req) -> UiResponse {
  let mut last_unsupported_detail = "no contributors"
  for c in self.contributors {
    let result : Result[UiResponse, @error.UiError] = Ok(c.request(req)) catch {
      e => Err(e)
    }
    match result {
      Ok(resp) => return resp
      Err(@error.UiError::Unsupported(detail~)) =>
        last_unsupported_detail = detail
      Err(other) => raise other
    }
  }
  raise @error.UiError::Unsupported(
    detail="no contributor supported the request; last detail=" +
      last_unsupported_detail,
  )
}

///|
pub extend CompositeUiPort with UiPort::{ui_descriptor, render, request}
