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
pub impl ModelBinding for ChunkDemandHost with fn model_id(
  _self : ChunkDemandHost,
) -> ModelId {
  ModelId::unchecked("chunk-demand-model")
}

///|
pub impl ModelBinding for ChunkDemandHost with fn complete(
  self,
  _messages : Array[CanonicalMessage],
  _tool_definitions : Array[CanonicalToolDef],
  _call_options : Json,
  on_chunk : HostChunkCallback?,
) -> Result[AssistantCompletion, ModelFailure] {
  match on_chunk {
    None => self.saw_no_sink = true
    Some(callback) => {
      callback(Json::string("delta"))
      self.delivered_chunks = self.delivered_chunks + 1
    }
  }
  Ok(fixture_stop("done"))
}

///|
fn chunk_demand_config(
  host : ChunkDemandHost,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  stream_chunks : HostChunkCallback?,
) -> PuppetConfig raise CanonicalHostCompositionError {
  let canonical_host = CanonicalHost::from_catalog(host, catalog, [])
  canonical_puppet_config(
    canonical_host,
    catalog,
    journal,
    [],
    [],
    stream_chunks,
    Json::null(),
  )
}

///|
async test "puppet/chunks_are_not_requested_without_a_consumer" {
  let host = ChunkDemandHost::new()
  let journal = InMemoryJournal::new()
  let puppet = Puppet::new(
    chunk_demand_config(host, fixture_empty_catalog(), journal, None),
  )

  assert_true(fixture_prompt(puppet, "chunk_none") is Accepted(_))
  assert_true(host.saw_no_sink())
  assert_eq(host.delivered_chunks(), 0)
  assert_eq(journal.append_count(), 2)
}

///|
async test "puppet/chunks_are_requested_for_a_live_consumer" {
  let host = ChunkDemandHost::new()
  let journal = InMemoryJournal::new()
  let puppet = Puppet::new(
    chunk_demand_config(
      host,
      fixture_empty_catalog(),
      journal,
      Some(fn(_chunk : Json) { () }),
    ),
  )

  assert_true(fixture_prompt(puppet, "chunk_live") is Accepted(_))
  assert_true(!host.saw_no_sink())
  assert_eq(host.delivered_chunks(), 1)
  assert_eq(journal.append_count(), 2)
}
