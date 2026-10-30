///|
using @port {type ParamType}

///|
/// Tokenize a slash argument string, honoring double-quoted spans.
fn tokenize_args(text : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut current = StringBuilder()
  let mut in_quote = false
  for ch in text {
    if ch == '"' {
      in_quote = !in_quote
    } else if ch == ' ' && !in_quote {
      if current.to_string() != "" {
        tokens.push(current.to_string())
        current = StringBuilder()
      }
    } else {
      current.write_char(ch)
    }
  }
  let last = current.to_string()
  if last != "" {
    tokens.push(last)
  }
  tokens
}

///|
/// Coerce a string token to Json matching the param's ptype.
fn coerce_param(p : @port.CommandParam, raw : String) -> Result[Json, String] {
  match p.ptype {
    Str => Ok(Json::string(raw))
    Int => {
      let n = @string.parse_int(raw) catch {
        _ => return Err("parameter " + p.name + " expects Int, got: " + raw)
      }
      Ok(Json::number(n.to_double()))
    }
    Bool =>
      match raw {
        "true" | "on" | "yes" => Ok(Json::boolean(true))
        "false" | "off" | "no" => Ok(Json::boolean(false))
        _ => Err("parameter " + p.name + " expects Bool, got: " + raw)
      }
    Strs =>
      Ok(
        Json::array(
          raw.split(",").map(fn(s) { Json::string(s.to_owned()) }).collect(),
        ),
      )
  }
}

///|
/// Split a `key=value` token into (key, value). Returns None if no `=`.
fn split_kv(token : String) -> (String, String)? {
  let bytes = token.to_array()
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == '=' {
      let key = token[0:i].to_owned()
      let val = token[i + 1:].to_owned()
      return Some((key, val))
    }
    i += 1
  }
  None
}

///|
/// Find a CommandParam by name in an array. Returns None if not found.
fn find_param(
  params : Array[@port.CommandParam],
  name : String,
) -> @port.CommandParam? {
  for p in params {
    if p.name == name {
      return Some(p)
    }
  }
  None
}

///|
/// Parse a slash argument string into a JSON object according to CommandParam
/// definitions. Positional params fill in declaration order; non-positional
/// params expect `key=value` form. Applies defaults for missing optional params.
/// Returns Err with a reason string on type conversion failure or missing
/// required params. Pure function (no IO).
pub fn parse_slash_args(
  text : String,
  params : Array[@port.CommandParam],
) -> Result[Json, String] {
  let tokens = tokenize_args(text)
  let positional_params = params.filter(fn(p) { p.positional })
  let map : Map[String, Json] = Map::from_array([])
  let mut positional_idx = 0
  // First pass: positional params consume tokens in order, key=value fills others
  for token in tokens {
    match split_kv(token) {
      Some((key, val)) =>
        match find_param(params, key) {
          Some(p) =>
            match coerce_param(p, val) {
              Ok(v) => map[key] = v
              Err(e) => return Err(e)
            }
          None => return Err("unknown parameter: " + key)
        }
      None =>
        if positional_idx < positional_params.length() {
          let p = positional_params[positional_idx]
          match coerce_param(p, token) {
            Ok(v) => map[p.name] = v
            Err(e) => return Err(e)
          }
          positional_idx = positional_idx + 1
        }
    }
  }
  // Second pass: apply defaults + check required
  for p in params {
    if !map.contains(p.name) {
      match p.default {
        Some(d) => map[p.name] = d
        None =>
          if p.required {
            return Err("missing required parameter: " + p.name)
          }
      }
    }
  }
  Ok(Json::object(map))
}

///|
/// Validate a JSON object of args against a CommandDef's params.
/// Checks required presence; optional params with no value and no default
/// are omitted (not an error). Returns the (possibly defaulted) args on Ok.
/// Pure function (no IO).
pub fn validate_args(
  def : @port.CommandDef,
  args : Json,
) -> Result[Json, String] {
  let incoming : Map[String, Json] = match args {
    Object(m) => m
    _ => Map::from_array([])
  }
  let out : Map[String, Json] = Map::from_array([])
  for p in def.params {
    if incoming.contains(p.name) {
      out[p.name] = incoming[p.name]
    } else {
      match p.default {
        Some(d) => out[p.name] = d
        None =>
          if p.required {
            return Err("missing required parameter: " + p.name)
          }
      }
    }
  }
  Ok(Json::object(out))
}
