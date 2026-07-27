///|
/// End-to-end scheduler-wave execution contract for the Puppet pump.
///
/// The host deliberately completes the second parallel call first. The pump
/// must still reduce and journal the wave in model source order, and it must
/// not start an Exclusive or later Parallel wave before the preceding wave
/// reaches its side-effect boundary.

///|
struct WaveFixtureHost {
  model_results : Array[Result[AssistantCompletion, ModelFailure]]
  mut definitions : Array[CanonicalToolDef]
  mut model_index : Int
  started : Array[String]
  finished : Array[String]
  mut in_flight : Int
  mut max_in_flight : Int
}

///|
fn WaveFixtureHost::new(
  model_results : Array[Result[AssistantCompletion, ModelFailure]],
) -> WaveFixtureHost {
  {
    model_results: model_results.copy(),
    definitions: [],
    model_index: 0,
    started: [],
    finished: [],
    in_flight: 0,
    max_in_flight: 0,
  }
}

///|
fn WaveFixtureHost::max_in_flight(self : WaveFixtureHost) -> Int {
  self.max_in_flight
}

///|
fn WaveFixtureHost::started(self : WaveFixtureHost) -> Array[String] {
  self.started.copy()
}

///|
fn WaveFixtureHost::finished(self : WaveFixtureHost) -> Array[String] {
  self.finished.copy()
}

///|
pub impl ModelBinding for WaveFixtureHost with fn model_id(
  _self : WaveFixtureHost,
) -> ModelId {
  ModelId::unchecked("wave-fixture")
}

///|
pub impl ModelBinding for WaveFixtureHost with fn complete(
  self,
  _messages : Array[CanonicalMessage],
  _tool_definitions : Array[CanonicalToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[AssistantCompletion, ModelFailure] {
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="wave fixture host exhausted model results"))
  } else {
    self.model_results[index]
  }
}

///|
pub impl ToolBinding for WaveFixtureHost with fn owner_id(
  _self : WaveFixtureHost,
) -> OwnerId {
  OwnerId::unchecked("wave_fixture")
}

///|
pub impl ToolBinding for WaveFixtureHost with fn definitions(
  self : WaveFixtureHost,
) -> Array[CanonicalToolDef] {
  self.definitions.copy()
}

///|
pub impl ToolBinding for WaveFixtureHost with fn execute(
  self,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> ToolOutcome {
  let id = call_id.to_string()
  self.started.push(id)
  let now_in_flight = self.in_flight + 1
  self.in_flight = now_in_flight
  if now_in_flight > self.max_in_flight {
    self.max_in_flight = now_in_flight
  }
  let delay = match call_id.to_string() {
    "p1" => 120
    "p2" => 20
    _ => 10
  }
  @async.sleep(delay)
  self.in_flight = self.in_flight - 1
  self.finished.push(call_id.to_string())
  Success(content=call_id.to_string(), structured=None)
}

///|
fn WaveFixtureHost::bind_catalog(
  self : WaveFixtureHost,
  catalog : ToolCatalogSnapshot,
) -> CanonicalHost raise CanonicalHostCompositionError {
  self.definitions = catalog.definitions()
  CanonicalHost::from_catalog(self, catalog, [self])
}

///|
fn wave_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(Map::from_array([]))),
    ]),
  )
  let builder = ToolCatalogBuilder()
  for
    definition in [
      ("parallel_one", @kernel.Parallel),
      ("parallel_two", @kernel.Parallel),
      ("exclusive", @kernel.Exclusive),
      ("parallel_three", @kernel.Parallel),
    ] {
    let (name, policy) = definition
    ignore(
      builder.add(
        CanonicalToolDef(
          name=ToolName::unchecked(name),
          description="wave fixture tool",
          input_schema=schema,
          owner=OwnerId::unchecked("wave_fixture"),
          policy~,
          provenance=Some("wave_fixture"),
        ),
      ),
    )
  }
  builder.finish(version=CatalogVersion(1))
}

///|
async test "puppet/pump_executes_scheduler_waves_with_source_ordered_reduction" {
  let host = WaveFixtureHost::new([
    Ok(
      fixture_tool_calls([
        fixture_call("parallel_one", "p1"),
        fixture_call("parallel_two", "p2"),
        fixture_call("exclusive", "exclusive"),
        fixture_call("parallel_three", "p3"),
      ]),
    ),
    Ok(fixture_stop("done")),
  ])
  let journal = InMemoryJournal()
  let catalog = wave_catalog()
  let puppet = Puppet(
    canonical_puppet_config(
      host.bind_catalog(catalog),
      catalog,
      journal,
      [],
      [],
      None,
      Json::null(),
    ),
  )

  assert_true(fixture_prompt(puppet, "scheduler_waves") is Accepted(_))
  assert_eq(host.max_in_flight(), 2)
  assert_eq(host.started(), ["p1", "p2", "exclusive", "p3"])
  assert_eq(host.finished(), ["p2", "p1", "exclusive", "p3"])

  let transcript = match puppet.last_completed_transcript() {
    Some(value) => value
    None => fail("expected completed transcript")
  }
  let tool_call_ids : Array[String] = []
  for message in transcript.messages_snapshot() {
    match message {
      ToolMessage(call_id~, ..) => tool_call_ids.push(call_id.to_string())
      _ => ()
    }
  }
  assert_eq(tool_call_ids, ["p1", "p2", "exclusive", "p3"])
}
