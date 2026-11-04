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
