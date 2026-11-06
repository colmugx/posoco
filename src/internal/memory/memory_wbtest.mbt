///|
/// Whitebox tests for the built-in memory tool provider's failure reporting.

///|
struct FailingMemorySource {
  /// `Some(body)` for a source that answers, `None` to raise `Search`.
  body : String?
  failure : String
}

///|
pub impl @port.MemoryPort for FailingMemorySource with fn inbound(
  _self : FailingMemorySource,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  ignore((session_id, request))
  None
}

///|
pub impl @port.MemoryPort for FailingMemorySource with fn store(
  _self : FailingMemorySource,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  ignore((content, metadata))
  "id"
}

///|
pub impl @port.MemoryPort for FailingMemorySource with fn search(
  self : FailingMemorySource,
  query~ : String,
  top_k? : Int32,
) -> String? raise @error.MemoryError {
  ignore((query, top_k))
  match self.body {
    Some(body) => Some(body)
    None => raise @error.MemoryError::Search(self.failure)
  }
}

///|
pub impl @port.MemoryPort for FailingMemorySource with fn delete(
  _self : FailingMemorySource,
  id : String,
) -> Unit raise @error.MemoryError {
  ignore(id)
}

///|
pub extend FailingMemorySource with @port.MemoryPort::{
  inbound,
  store,
  search,
  delete,
}

///|
fn memory_search_args() -> Map[String, Json] {
  Map::from_array([("query", Json::string("what did we decide"))])
}

///|
async fn memory_search_outcome(
  provider : MemoryToolProvider,
) -> @kernel.ToolOutcome {
  @port.ToolProvider::execute(
    provider as &@port.ToolProvider,
    @port.ToolCallContext(
      effect_id=@kernel.EffectId::first(),
      call_id=@kernel.CallId::unchecked("call_1"),
      name=@kernel.ToolName::unchecked("memory_search"),
      arguments=Json::object(memory_search_args()),
      register_cancel=fn(_ : &@port.ToolCancellable) { () },
    ),
  )
}

///|
async test "memory_search/all_sources_failing_reports_error_not_clean_miss" {
  let failures : Array[String] = []
  let losing = (
    { body: None, failure: "index unavailable", } : FailingMemorySource)
  let provider = MemoryToolProvider(
    sources=[
      ("lost_a", losing as &@port.MemoryPort),
      ("lost_b", losing as &@port.MemoryPort),
    ],
    on_failure=fn(reason) { failures.push(reason) },
  )
  let outcome = memory_search_outcome(provider)
  match outcome {
    ToolReportedError(content~, ..) => {
      assert_true(content.contains("lost_a: failed"))
      assert_true(content.contains("lost_b: failed"))
      assert_true(content.contains("index unavailable"))
      assert_false(content.contains("No matching memory."))
    }
    Success(content~, ..) =>
      fail("all-source failure must not read as a clean miss: " + content)
    other => fail("unexpected outcome: " + other.to_string())
  }
  assert_eq(failures.length(), 2)
}

///|
async test "memory_search/wave_failure_is_error_not_clean_miss" {
  // A whole-wave failure has no per-source text; the report carries the wave
  // reason instead of the "No matching memory." success.
  let outcome = memory_search_wave_failure("wave deadlock")
  match outcome {
    ToolReportedError(content~, ..) => {
      assert_true(content.contains("no source completed"))
      assert_true(content.contains("wave deadlock"))
      assert_false(content.contains("No matching memory."))
    }
    other => fail("expected ToolReportedError, got " + other.to_string())
  }
}

///|
async test "memory_search/hit_outranks_sibling_failure" {
  let failures : Array[String] = []
  let answering = (
    { body: Some("durable answer"), failure: "", } : FailingMemorySource)
  let losing = (
    { body: None, failure: "index unavailable", } : FailingMemorySource)
  let provider = MemoryToolProvider(
    sources=[
      ("live", answering as &@port.MemoryPort),
      ("lost", losing as &@port.MemoryPort),
    ],
    on_failure=fn(reason) { failures.push(reason) },
  )
  match memory_search_outcome(provider) {
    Success(content~, ..) => assert_eq(content, "durable answer")
    other => fail("expected usable hits, got " + other.to_string())
  }
  assert_true(failures[0].contains("memory_search lost: "))
  assert_true(failures[0].contains("index unavailable"))
}

///|
async test "memory_lead/exact_literal" {
  assert_eq(
    MEMORY_INBOUND_LEAD,
    "Recalled memory for this session may be stale or incomplete; verify against the current conversation before relying on it.",
  )
}

///|
fn schema_property(schema : Json, key : String) -> Map[String, Json]? {
  match schema {
    Object(fields) =>
      match fields.get("properties") {
        Some(Object(props)) =>
          match props.get(key) {
            Some(Object(prop)) => Some(prop)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
async test "memory_tools/descriptions_match_port_contract" {
  let a = ({ body: Some("hit"), failure: "", } : FailingMemorySource)
  let provider = MemoryToolProvider(
    sources=[("a", a as &@port.MemoryPort), ("b", a as &@port.MemoryPort)],
    on_failure=fn(_reason) { () },
  )
  let defs = provider.list_tools()
  assert_eq(defs.length(), 2)
  let search = defs[0]
  let add = defs[1]
  assert_eq(search.name.to_string(), "memory_search")
  assert_eq(add.name.to_string(), "memory_add")
  assert_eq(
    search.description,
    "Search accumulated memory (past work, settled decisions, SOPs) before answering questions it may have settled, and before saving anything new.",
  )
  assert_false(add.description.contains("durable"))
  assert_eq(
    add.description,
    "Save a memory for future sessions. Omit source to save to every connected memory provider; valid sources: a, b",
  )
  match schema_property(add.input_schema, "source") {
    Some(fields) =>
      match fields.get("type") {
        Some(String(ty)) => assert_eq(ty, "string")
        _ => fail("expected source type string")
      }
    _ => fail("expected a source property in memory_add schema")
  }
  match schema_property(add.input_schema, "source") {
    Some(fields) =>
      match fields.get("description") {
        Some(String(desc)) => assert_eq(desc, "Target memory provider ID.")
        _ => fail("expected source description")
      }
    _ => fail("expected a source property in memory_add schema")
  }
  match schema_property(search.input_schema, "top_k") {
    Some(fields) => {
      match fields.get("type") {
        Some(String(ty)) => assert_eq(ty, "integer")
        _ => fail("expected top_k type integer")
      }
      match fields.get("description") {
        Some(String(desc)) =>
          assert_eq(
            desc, "Max results; omit to leave the count to the provider.",
          )
        _ => fail("expected top_k description")
      }
    }
    _ => fail("expected a top_k property in memory_search schema")
  }
  match search.input_schema {
    Object(fields) =>
      match fields.get("required") {
        Some(Array([String("query")])) => ()
        _ => fail("expected required [query]")
      }
    _ => fail("expected an object schema")
  }
  match add.input_schema {
    Object(fields) =>
      match fields.get("required") {
        Some(Array([String("content")])) => ()
        _ => fail("expected required [content]")
      }
    _ => fail("expected an object schema")
  }
}
