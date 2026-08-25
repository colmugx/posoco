///|
/// XML-escape text content so interpolated values cannot break out of the
/// envelope or inject attributes. Single pass; only the five significant
/// characters are rewritten.
fn escape_xml(s : String) -> String {
  let sb = StringBuilder::new()
  for ch in s {
    match ch {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      '\'' => sb.write_string("&apos;")
      _ => sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// Render one context envelope element:
/// `<{namespace}-context type="{kind}" trust="{trust}"[ source="{source}">…</{namespace}-context>`.
/// This is the shared renderer for hosts, extensions, and Posoco's built-in
/// hooks, so every context a model sees carries the same shape. The
/// namespace belongs to the composing host (default "posoco") and the
/// element name is rendered as `{namespace}-context`; `namespace` and `kind`
/// are trusted host configuration and are not escaped. `source` (rendered
/// only when passed) and `content` are escaped because they may carry
/// external text.
pub fn render_context(
  ns? : String = "posoco",
  kind~ : String,
  trust~ : Bool,
  source? : String,
  content~ : String,
) -> String {
  let trust_str = if trust { "true" } else { "false" }
  let sb : StringBuilder = StringBuilder::new()
  sb <+ "<\{ns}-context type=\"\{kind}\" trust=\"\{trust_str}\""
  if source is Some(s) {
    sb <+ " source=\"\{escape_xml(s)}\""
  }
  sb <+ ">\n\{escape_xml(content)}\n</\{ns}-context>"
  sb.to_string()
}
