///|
/// UiPort: structured UI intents and interactive requests. UI-toolkit-
/// agnostic — hosts implement this trait and translate intents into
/// their rendering primitives. Three responsibilities: `ui_descriptor`,
/// `render`, `request`.

// Semantic slots and bodies

///|
/// Where a render intent lands: Status (single-line bar), Notice (transient toast), Widget (persistent region).
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
/// Structured payload a render intent carries. Host decides layout and color.
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
/// One render intent. Same `key` replaces a prior intent in the same `UiSlot`.
pub(all) struct UiRender {
  slot : UiSlot
  key : String
  title : String?
  body : UiBody
  /// Visibility hint in milliseconds. `None` = persistent; hosts may ignore.
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

// Autocomplete descriptor

///|
pub(all) struct AutocompleteItem {
  label : String
  insert_text : String
  detail : String?
  kind : String
} derive(Debug)

///|
/// A source of autocomplete suggestions tied to a trigger character.
pub(all) struct AutocompleteSource {
  trigger : String
  kind : String
  /// Given text typed so far (excluding trigger), return matching items.
  fetch : (String) -> Array[AutocompleteItem]
} derive(Debug)

///|
/// Collected at composition time: the host aggregates every UiPort's
/// descriptors to know which autocomplete triggers to honor.
pub(all) struct UiDescriptor {
  autocomplete_sources : Array[AutocompleteSource]
} derive(Debug)

///|
/// Empty descriptor used by UIs that contribute no autocomplete sources.
pub fn UiDescriptor::empty() -> UiDescriptor {
  { autocomplete_sources: [] }
}

// Interactive request / response

///|
/// User interaction primitives. Hosts that lack a variant raise
/// `UiError::Unsupported`.
pub(all) enum UiRequest {
  /// Free-form text input, with optional pre-fill.
  Input(prompt~ : String, default~ : String?)
  /// Yes/no confirmation.
  Confirm(prompt~ : String)
  /// Choose one option. `default` is the pre-select index.
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
/// Response to a UiRequest. `Cancelled` = user dismissed; no UI = `UiError::Unsupported`.
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

// UiPort trait

///|
/// The UI extension contract. Implemented by host packages (cetas-js,
/// cetas-native) or testkit.
pub(open) trait UiPort {
  /// Declare what this UI offers (autocomplete sources). Called once.
  fn ui_descriptor(Self) -> UiDescriptor

  /// Push a render intent to the host. Same `key` replaces a prior intent.
  fn render(Self, intent : UiRender) -> Unit

  /// Send an interactive request and wait for a response. Raise
  /// `UiError::Unsupported` if this UI cannot service requests.
  async fn request(Self, req : UiRequest) -> UiResponse raise @error.UiError
}
