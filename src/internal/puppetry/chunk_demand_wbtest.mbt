///|
/// Verifies that the assembled pump forwards chunk demand only to model
/// effects. Tool waves never receive a chunk sink.

///|
struct ChunkDemandHost {
  mut saw_no_sink : Bool
  mut delivered_chunks : Int
}

///|
fn ChunkDemandHost::new() -> ChunkDemandHost {
  { saw_no_sink: false, delivered_chunks: 0 }
}

///|
fn ChunkDemandHost::saw_no_sink(self : ChunkDemandHost) -> Bool {
  self.saw_no_sink
}

///|
fn ChunkDemandHost::delivered_chunks(self : ChunkDemandHost) -> Int {
  self.delivered_chunks
}

///|
pub impl @kernel_exec.HostRuntime for ChunkDemandHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : Array[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  match on_chunk {
    None => self.saw_no_sink = true
    Some(callback) => {
      callback(Json::string("delta"))
      self.delivered_chunks = self.delivered_chunks + 1
    }
  }
  Ok(ModelCallResult::{
    completion: fixture_stop("done"),
    processed_messages: messages,
  })
}

///|
pub impl @kernel_exec.HostRuntime for ChunkDemandHost with fn execute_tool(
  _self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
  Success(content=call_id.to_string(), structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for ChunkDemandHost with fn cancel_effects(
  self : ChunkDemandHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// M3.5: compact stub — ChunkDemandHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for ChunkDemandHost with fn compact(
  self : ChunkDemandHost,
  _scope : InvocationScope,
  _messages : Array[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(ModelFailure::Parse(reason="ChunkDemandHost does not implement compact"))
}

///|
fn chunk_demand_config(
  host : ChunkDemandHost,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  stream_chunks : HostChunkCallback?,
) -> PuppetConfig {
  canonical_puppet_config(
    host as &@kernel_exec.HostRuntime,
    catalog,
    journal,
    [],
    [],
    stream_chunks,
  )
}

///|
async test "puppet/chunks_are_not_requested_without_a_consumer" {
  let host = ChunkDemandHost::new()
  let journal = InMemoryJournal()
  let puppet = Puppet(
    chunk_demand_config(host, fixture_empty_catalog(), journal, None),
  )

  assert_true(fixture_prompt(puppet, "chunk_none") is Accepted(_))
  assert_true(host.saw_no_sink())
  assert_eq(host.delivered_chunks(), 0)
}

///|
async test "puppet/chunks_are_delivered_when_consumer_is_set" {
  let trace : Array[String] = []
  let on_chunk : HostChunkCallback = fn(chunk : Json) {
    trace.push(chunk.stringify())
  }
  let host = ChunkDemandHost::new()
  let journal = InMemoryJournal()
  let puppet = Puppet(
    chunk_demand_config(host, fixture_empty_catalog(), journal, Some(on_chunk)),
  )

  assert_true(fixture_prompt(puppet, "chunk_some") is Accepted(_))
  assert_false(host.saw_no_sink())
  assert_eq(host.delivered_chunks(), 1)
  assert_true(trace.length() > 0)
  assert_eq(trace[0], "\"delta\"")
}
