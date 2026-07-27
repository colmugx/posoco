///|
/// Built-in UiPort implementations: a no-op default and a fan-out composite.
///
/// `NoopUiPort` is the safe default — `render` is dropped, `request` raises
/// `Unsupported` so callers see clearly that no UI is wired. `CompositeUiPort`
/// broadcasts `render` to every contributor and routes `request` to the first
/// contributor that does not raise `Unsupported`.

// ──────────────────────────────────────────────────────────────────────────
// NoopUiPort
// ──────────────────────────────────────────────────────────────────────────

///|
/// Default UiPort for hosts that have no UI (headless test, batch job, etc.).
/// `request` raises `UiError::Unsupported` so a `CompositeUiPort` can
/// fall through, and so callers cannot mistake "no UI" for "user said no".
pub(all) struct NoopUiPort {
  // stateless
}

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
  // Drop silently. Logs/telemetry are host concerns; the core must not
  // second-guess the host's rendering policy.
}

///|
pub impl UiPort for NoopUiPort with fn request(_self, _req) -> UiResponse {
  raise @error.UiError::Unsupported(detail="NoopUiPort has no UI backend")
}

///|
/// Expose UiPort methods on NoopUiPort for dot-syntax callers.
pub extend NoopUiPort with UiPort::{ui_descriptor, render, request}

// ──────────────────────────────────────────────────────────────────────────
// CompositeUiPort
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fan-out UiPort over multiple contributors. `render` is delivered to every
/// contributor in registration order. `request` is tried against each
/// contributor in order; the first one that returns a response wins, and the
/// first one that raises a non-`Unsupported` error short-circuits the chain.
///
/// If every contributor raises `Unsupported`, the composite raises
/// `Unsupported` itself so a nested composite can fall through.
///
/// De-duplication of same-key renders is explicitly *not* done here. Key
/// namespaces are owned by extensions; the host decides whether two
/// contributors rendering the same key collide, replace, or stack.
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
/// Aggregate descriptors by concatenating autocomplete sources in registration
/// order. Duplicate triggers across contributors are kept — the host decides
/// how to merge them.
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
/// Broadcast to every contributor in registration order. Best-effort: a
/// contributor raising from `render` is observable but cannot abort the
/// broadcast (render is one-way intent, not a request).
pub impl UiPort for CompositeUiPort with fn render(self, intent) -> Unit {
  for c in self.contributors {
    c.render(intent)
  }
}

///|
/// Try each contributor in order. First non-`Unsupported` result wins.
/// First non-`Unsupported` error short-circuits. All-`Unsupported` raises
/// `Unsupported`.
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
/// Expose UiPort methods on CompositeUiPort for dot-syntax callers.
pub extend CompositeUiPort with UiPort::{ui_descriptor, render, request}
