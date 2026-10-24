///|
/// Wire mirror of the host outcome (protocol 1). Failures are values a
/// guest branches on; only transport loss raises.
pub(all) enum Outcome {
  Success(content~ : String, structured~ : Json?)
  Failure(code~ : String, content~ : String, structured~ : Json?)
} derive(Eq, Debug)

///|
pub extend Outcome with Debug::{to_repr}

///|
pub extend Outcome with Eq::{equal, not_equal}

///|
pub fn Outcome::is_error(self : Outcome) -> Bool {
  self is Failure(..)
}

///|
pub fn Outcome::to_json(self : Outcome) -> Json {
  let (fields, structured) : (Map[String, Json], Json?) = match self {
    Success(content~, structured~) =>
      (
        { "kind": Json::string("success"), "content": Json::string(content) },
        structured,
      )
    Failure(code~, content~, structured~) =>
      (
        {
          "kind": Json::string("failure"),
          "code": Json::string(code),
          "content": Json::string(content),
        },
        structured,
      )
  }
  match structured {
    Some(value) => fields["structured"] = value
    None => ()
  }
  Json::object(fields)
}

///|
/// Lenient inverse of `to_json`: `content` defaults to empty and
/// `structured` to absent, so hosts may omit optional fields.
pub fn Outcome::from_json(value : Json) -> Outcome raise {
  guard value is Object(fields) else { fail("ears: outcome must be an object") }
  let content = match fields.get("content") {
    Some(String(text)) => text
    _ => ""
  }
  let structured = fields.get("structured")
  match fields.get("kind") {
    Some(String("success")) => Success(content~, structured~)
    Some(String("failure")) =>
      match fields.get("code") {
        Some(String(code)) => Failure(code~, content~, structured~)
        _ => fail("ears: failure outcome is missing its code")
      }
    _ => fail("ears: unknown outcome kind")
  }
}
