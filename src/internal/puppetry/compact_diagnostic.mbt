// ──────────────────────────────────────────────────────────────────────────
// Compact diagnostic extraction (openai-compact-repair W1).
//
// A failed `ModelPort::compact` reaches the Puppet as a `ModelFailure`. Its
// raw reason carries the adapter's verdict (`stage=http_status,status=…,…`
// today; provider `code`/`param`/`request_id` from W3 onward) but only its
// first 64 characters survive `ModelFailure::to_string`. These helpers parse
// the allowlisted safe fields out of the RAW string before that truncation.
// The result is best-effort, not a proof: fields from a well-formed envelope
// are trusted, quoted content never reaches the scanner, and malformed quote
// structures reject ALL metadata — falling back to the pre-existing bounded
// rendering.
// ──────────────────────────────────────────────────────────────────────────

///|
priv struct CompactDiagnostic {
  stage : String?
  status : String?
  code : String?
  param : String?
  request_id : String?
  /// Provider-supplied subcategory from the adapter verdict (`category=…`).
  category : String?
  /// Structural ModelFailure variant name; rendered as `failure=…` so it can
  /// never collide with the provider's `category=…`.
  variant : String
}

///|
priv struct CompactParsedFields {
  mut stage : String?
  mut status : String?
  mut code : String?
  mut param : String?
  mut request_id : String?
  mut category : String?
}

///|
fn compact_trim(value : String) -> String {
  let chars : Array[Char] = []
  for ch in value {
    chars.push(ch)
  }
  let mut start = 0
  let mut stop = chars.length()
  while start < stop && (chars[start] == ' ' || chars[start] == '\t') {
    start = start + 1
  }
  while stop > start && (chars[stop - 1] == ' ' || chars[stop - 1] == '\t') {
    stop = stop - 1
  }
  let buf = StringBuilder()
  for i in start..<stop {
    buf.write_char(chars[i])
  }
  buf.to_string()
}

///|
/// Reduce `<prefix> (k=v, k=v)` verdicts to their FIRST balanced parenthesised
/// body; plain `k=v` messages pass through unchanged. Both delimiters are
/// found outside quotes, so excerpt contents cannot move them, and any free
/// text after the closing parenthesis (host error suffixes) is ignored.
fn compact_verdict_body(reason : String) -> String {
  let mut open = -1
  let mut close = -1
  let mut in_quotes = false
  let mut escaped = false
  let mut i = 0
  for ch in reason {
    if escaped {
      escaped = false
    } else {
      match ch {
        '\\' => escaped = true
        '"' => in_quotes = !in_quotes
        '(' if !in_quotes && open < 0 => open = i
        ')' if !in_quotes && open >= 0 && close < 0 => close = i
        _ => ()
      }
    }
    i = i + 1
  }
  if open >= 0 && close > open {
    let chars : Array[Char] = []
    for ch in reason {
      chars.push(ch)
    }
    let buf = StringBuilder()
    for j in (open + 1)..<close {
      buf.write_char(chars[j])
    }
    return buf.to_string()
  }
  reason
}

///|
fn CompactParsedFields::empty() -> CompactParsedFields {
  {
    stage: None,
    status: None,
    code: None,
    param: None,
    request_id: None,
    category: None,
  }
}

///|
/// Store one allowlisted (or aliased) key; unknown keys and empty values are
/// ignored. First occurrence wins.
fn CompactParsedFields::store(
  self : CompactParsedFields,
  key : String,
  value : String,
) -> Unit {
  let bounded = safe_label(value)
  if bounded.length() == 0 {
    return
  }
  match key {
    "stage" => if self.stage is None { self.stage = Some(bounded) }
    "status" | "http_status" =>
      if self.status is None {
        self.status = Some(bounded)
      }
    "code" | "error_code" | "provider_code" =>
      if self.code is None {
        self.code = Some(bounded)
      }
    "param" | "parameter" =>
      if self.param is None {
        self.param = Some(bounded)
      }
    "request_id" | "req" | "requestid" =>
      if self.request_id is None {
        self.request_id = Some(bounded)
      }
    "category" | "error_category" =>
      if self.category is None {
        self.category = Some(bounded)
      }
    _ => ()
  }
}

///|
/// Store one top-level `key=value` segment.
fn CompactParsedFields::store_segment(
  self : CompactParsedFields,
  segment : String,
) -> Unit {
  let pair = compact_trim(segment)
  let key = StringBuilder()
  let value = StringBuilder()
  let mut in_key = true
  for ch in pair {
    if in_key {
      if ch == '=' {
        in_key = false
      } else {
        key.write_char(ch)
      }
    } else {
      value.write_char(ch)
    }
  }
  if in_key {
    return
  }
  self.store(compact_trim(key.to_string()), value.to_string())
}

///|
/// Parse allowlisted `key=value` fields from one provider verdict line.
/// Segments split on commas outside double quotes; quoted values and every
/// escaped character inside them never reach the scanner. The quote structure
/// must be well formed — quotes only directly after `=`, one quoted value per
/// segment, balanced at the end — otherwise ALL metadata is rejected instead
/// of partially trusted.
fn compact_parse_fields(reason : String) -> CompactParsedFields? {
  let fields = CompactParsedFields::empty()
  let buf = StringBuilder()
  let mut in_quotes = false
  let mut escaped = false
  let mut in_key = true
  let mut value_chars = 0
  let mut quoted_here = false
  for ch in compact_verdict_body(reason) {
    if escaped {
      escaped = false
      if !in_quotes {
        if ch == '=' {
          in_key = false
        } else if !in_key {
          value_chars = value_chars + 1
        }
        buf.write_char(ch)
      }
      continue
    }
    match ch {
      '\\' => escaped = true
      '"' =>
        if in_quotes {
          in_quotes = false
        } else {
          if in_key || value_chars > 0 || quoted_here {
            return None
          }
          quoted_here = true
          in_quotes = true
        }
      ',' if !in_quotes => {
        fields.store_segment(buf.to_string())
        buf.reset()
        in_key = true
        value_chars = 0
        quoted_here = false
      }
      _ =>
        if !in_quotes {
          if quoted_here {
            // Any character after a closed quoted value is junk; the segment
            // grammar allows a quoted value only as the entire value.
            return None
          }
          if ch == '=' {
            in_key = false
          } else if !in_key {
            value_chars = value_chars + 1
          }
          buf.write_char(ch)
        }
    }
  }
  if in_quotes {
    return None
  }
  fields.store_segment(buf.to_string())
  Some(fields)
}

///|
/// Extract the allowlisted diagnostic from a failed model call. Returns
/// `None` when the raw reason carries no allowlisted field and the variant
/// has no structured provider code; the caller then keeps its previous
/// bounded rendering (category fallback).
fn compact_diagnostic_of(failure : @kernel.ModelFailure) -> CompactDiagnostic? {
  let (variant, raw, structured_code) = match failure {
    RequestBuild(reason~) => ("RequestBuild", reason, None)
    Transport(reason~) => ("Transport", reason, None)
    Runtime(reason~) => ("Runtime", reason, None)
    Parse(reason~) => ("Parse", reason, None)
    HostRejected(reason~) => ("HostRejected", reason, None)
    RateLimited(reason~, provider_code~, ..) =>
      ("RateLimited", reason, provider_code)
  }
  let parsed = match compact_parse_fields(raw) {
    Some(fields) => fields
    None => return None
  }
  let code = match parsed.code {
    Some(c) => Some(c)
    None =>
      match structured_code {
        Some(c) => Some(safe_label(c))
        None => None
      }
  }
  let diag : CompactDiagnostic = {
    stage: parsed.stage,
    status: parsed.status,
    code,
    param: parsed.param,
    request_id: parsed.request_id,
    category: parsed.category,
    variant,
  }
  if diag.has_field() {
    Some(diag)
  } else {
    None
  }
}

///|
fn CompactDiagnostic::has_field(self : CompactDiagnostic) -> Bool {
  self.stage is Some(_) ||
  self.status is Some(_) ||
  self.code is Some(_) ||
  self.param is Some(_) ||
  self.request_id is Some(_) ||
  self.category is Some(_)
}

///|
/// Aggregate budget so the full rendering survives every downstream
/// 512-character bound (command outcome, OperationFinalized.detail).
let compact_diagnostic_render_budget : Int = 352

///|
/// Render the allowlisted fields in priority order (structural variant, then
/// request id and code) under the aggregate budget; absent fields are
/// omitted and the lowest-priority fields yield first when every value is at
/// its maximum length.
fn CompactDiagnostic::render(self : CompactDiagnostic) -> String {
  let candidates : Array[(String, String?)] = [
    ("failure", Some(self.variant)),
    ("request_id", self.request_id),
    ("code", self.code),
    ("status", self.status),
    ("stage", self.stage),
    ("category", self.category),
    ("param", self.param),
  ]
  let parts : Array[String] = []
  let mut budget = compact_diagnostic_render_budget
  for entry in candidates {
    let (key, value) = entry
    match value {
      Some(v) => {
        let part = "\{key}=\{v}"
        let cost = part.length() + (if parts.length() > 0 { 1 } else { 0 })
        if cost <= budget {
          parts.push(part)
          budget = budget - cost
        }
      }
      None => ()
    }
  }
  parts.join(" ")
}

///|
/// Cause label for a failed modelport compact: parse the safe diagnostic out
/// of the raw failure before its display truncation; with no allowlisted
/// field present, keep the old bounded display rendering verbatim.
fn compact_failure_cause(failure : @kernel.ModelFailure) -> String {
  match compact_diagnostic_of(failure) {
    Some(diag) => "modelport compact failed: " + diag.render()
    None => "modelport compact failed: " + failure.to_string()
  }
}

///|
/// Effect phases that belong to a compaction. Only their failure rendering
/// may widen the cause label; every other phase keeps the exact previous
/// rendering. Mirrors the Agent-level twin in `src/agent_turn.mbt` — extend
/// both together.
fn is_compact_effect_phase(phase : String) -> Bool {
  phase == "compact" || phase == "compact_session" || phase == "auto_compact"
}
