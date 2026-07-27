///|
/// UiPort — extension seam for structured UI intents and interactive requests.
///
/// This trait is intentionally UI-toolkit-agnostic. It describes *what* an
/// extension wants to render or ask, never *how* a host paints it. Hosts
/// (cetas-js with pi-tui, cetas-native with a TTY, future web hosts) implement
/// UiPort and translate the structured intents into their own rendering
/// primitives.
///
/// Three responsibilities, one trait (decided 2026-07-23 over a two-port split):
/// - `ui_descriptor`: declare what this UI offers (autocomplete sources). Called
///   once at composition time so the host can collect descriptors without
///   per-turn work.
/// - `render`: one-way intent from extension → host (status, notice, widget).
///   Same-key replacement is host semantics, not UiPort's.
/// - `request`: interactive round-trip (Input / Confirm / Select). Async with a
///   typed UiError channel so callers can distinguish "unsupported" from
///   "cancelled" from "io failure".
///
/// `NoopUiPort` is the default; `CompositeUiPort` broadcasts render and picks
/// the first non-Unsupported responder for request. See `ui_builtin.mbt`.

// ──────────────────────────────────────────────────────────────────────────
// Semantic slots and bodies
// ──────────────────────────────────────────────────────────────────────────

///|
/// Where a render intent lands. Semantic, not visual: a host maps Widget to
/// whatever persistent region it owns (panel, footer, overlay), Notice to a
/// transient toast/log line, Status to a single-line state bar.
pub(all) enum UiSlot {
  Status
  Notice
  Widget
} derive(Eq, Debug)

///|
pub impl Show for UiSlot with fn to_string(self) -> String {
  match self {
    Status => "Status"
    Notice => "Notice"
    Widget => "Widget"
  }
}

///|
/// Structured payload a render intent carries. The host decides layout, color,
/// truncation. `Progress(p)` expects `0.0 <= p <= 1.0`; out-of-range is a host
/// rendering decision, not a contract violation.
pub(all) enum UiBody {
  Text(String)
  Lines(Array[String])
  KeyValue(Array[(String, String)])
  Progress(Double)
  Markdown(String)
} derive(Debug)

///|
pub impl Show for UiBody with fn to_string(self) -> String {
  match self {
    Text(s) => "Text(\{s.length()} chars)"
    Lines(lines) => "Lines(\{lines.length()})"
    KeyValue(pairs) => "KeyValue(\{pairs.length()})"
    Progress(p) => "Progress(\{p})"
    Markdown(s) => "Markdown(\{s.length()} chars)"
  }
}

///|
/// One render intent. `key` is the host's identity slot: rendering a second
/// intent with the same key replaces the first within the same `UiSlot`. Keys
/// are owned by the extension (e.g. "goal.status", "log.tail"); the host does
/// not enforce a global namespace.
pub(all) struct UiRender {
  slot : UiSlot
  key : String
  title : String?
  body : UiBody
  /// Hint in milliseconds for how long the host should keep the intent visible
  /// before clearing it. `None` = persistent (host never auto-clears). Hosts
  /// may ignore the hint for slots that ignore TTL (e.g. Status).
  ttl_ms : Int?
} derive(Debug)

///|
pub impl Show for UiRender with fn to_string(self) -> String {
  let title_repr = match self.title {
    Some(t) => "Some(\"" + t + "\")"
    None => "None"
  }
  "UiRender(slot=" +
  self.slot.to_string() +
  ", key=\"" +
  self.key +
  "\", title=" +
  title_repr +
  ", body=" +
  self.body.to_string() +
  ")"
}

// ──────────────────────────────────────────────────────────────────────────
// Autocomplete descriptor
// ──────────────────────────────────────────────────────────────────────────

///|
/// One autocomplete suggestion. `kind` is a host-rendered glyph/category hint
/// (e.g. "file", "command", "snippet"); the UiPort does not interpret it.
pub(all) struct AutocompleteItem {
  label : String
  /// What the host inserts when the user accepts the suggestion.
  insert_text : String
  /// Short description shown alongside the label, if the host supports it.
  detail : String?
  kind : String
} derive(Debug)

///|
/// A source of autocomplete suggestions tied to a trigger character.
///
/// `fetch` is intentionally synchronous: JS hosts debounce and pre-fetch in
/// the host layer, and MoonBit closures cannot cross the JS FFI boundary
/// cleanly. MVP scope is MoonBit-side fetch only; pure-TS autocomplete is
/// supplied directly by the host.
pub(all) struct AutocompleteSource {
  /// The character that triggers this source (e.g. "/", "@", ".").
  trigger : String
  /// Category label for diagnostics and host-side grouping.
  kind : String
  /// Synchronous fetch. Given the text typed so far (excluding the trigger),
  /// return matching items.
  fetch : (String) -> Array[AutocompleteItem]
} derive(Debug)

///|
/// Descriptor collected once at composition time. The host aggregates
/// descriptors from every UiPort contributor so its input layer knows which
/// triggers to honor.
pub(all) struct UiDescriptor {
  autocomplete_sources : Array[AutocompleteSource]
} derive(Debug)

///|
/// Empty descriptor used by UIs that contribute no autocomplete sources.
pub fn UiDescriptor::empty() -> UiDescriptor {
  { autocomplete_sources: [] }
}

// ──────────────────────────────────────────────────────────────────────────
// Interactive request / response
// ──────────────────────────────────────────────────────────────────────────

///|
/// A request the extension sends to the user via the host UI. Each variant
/// maps to a standard interaction primitive; hosts that lack a primitive
/// raise `UiError::Unsupported`.
pub(all) enum UiRequest {
  /// Free-form text input. `default` pre-fills the field where the host supports it.
  Input(prompt~ : String, default~ : String?)
  /// Yes/no confirmation.
  Confirm(prompt~ : String)
  /// Choose one option from a list. `default` is the index to pre-select.
  Select(prompt~ : String, options~ : Array[String], default~ : Int?)
} derive(Debug)

///|
pub impl Show for UiRequest with fn to_string(self) -> String {
  match self {
    Input(prompt~, default~) =>
      "UiRequest::Input(prompt=\"" +
      prompt +
      "\", default=" +
      str_default_label(default) +
      ")"
    Confirm(prompt~) => "UiRequest::Confirm(prompt=\"" + prompt + "\")"
    Select(prompt~, options~, default~) =>
      "UiRequest::Select(prompt=\"" +
      prompt +
      "\", options=" +
      options.length().to_string() +
      ", default=" +
      int_default_label(default) +
      ")"
  }
}

///|
fn str_default_label(d : String?) -> String {
  match d {
    Some(s) => "Some(\"" + s + "\")"
    None => "None"
  }
}

///|
fn int_default_label(d : Int?) -> String {
  match d {
    Some(i) => "Some(" + i.to_string() + ")"
    None => "None"
  }
}

///|
/// Response to a UiRequest. `Cancelled` means the user explicitly dismissed
/// the request; "no UI available" surfaces as `UiError::Unsupported` instead,
/// so callers can distinguish the two.
pub(all) enum UiResponse {
  Text(String)
  Yes
  No
  Selected(Int)
  Cancelled
} derive(Eq, Debug)

///|
pub impl Show for UiResponse with fn to_string(self) -> String {
  match self {
    Text(s) => "UiResponse::Text(\"" + s + "\")"
    Yes => "UiResponse::Yes"
    No => "UiResponse::No"
    Selected(i) => "UiResponse::Selected(" + i.to_string() + ")"
    Cancelled => "UiResponse::Cancelled"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// UiPort trait
// ──────────────────────────────────────────────────────────────────────────

///|
/// The UI extension contract. Implementations live in host packages
/// (cetas-js/cetas-native) or testkit (`RecordingUiPort`).
///
/// Method visibility for dot-syntax callers is exposed via the explicit
/// `extend` declarations in `ui_builtin.mbt` and any other implementer. The
/// trait itself does not auto-attach.
pub(open) trait UiPort {
  /// Declare what this UI offers. Called once at composition time.
  fn ui_descriptor(Self) -> UiDescriptor

  /// Push a render intent to the host. Returns immediately; the host decides
  /// when/how to paint. Same `key` replaces a prior intent in the same slot.
  fn render(Self, intent : UiRender) -> Unit

  /// Send an interactive request and wait for the user's response. MUST raise
  /// `UiError::Unsupported` if this UI cannot service requests at all, so
  /// `CompositeUiPort` can fall through to the next contributor. MUST raise
  /// `UiError::Cancelled` only when the user explicitly dismissed a request
  /// that was actually presented.
  async fn request(Self, req : UiRequest) -> UiResponse raise @error.UiError
}
