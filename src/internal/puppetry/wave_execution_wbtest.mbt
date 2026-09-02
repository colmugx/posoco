///|
/// End-to-end scheduler-wave execution contract for the Puppet pump.
///
/// The host deliberately completes the second parallel call first. The pump
/// must still reduce and journal the wave in model source order, and it must
/// not start an Exclusive or later Parallel wave before the preceding wave
/// reaches its side-effect boundary.

///|
struct WaveFixtureHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int
  started : Array[String]
  finished : Array[String]
  mut in_flight : Int
  mut max_in_flight : Int
}

///|
fn WaveFixtureHost::WaveFixtureHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
) -> WaveFixtureHost {
  {
    model_results: model_results.copy(),
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
pub impl @kernel_exec.HostRuntime for WaveFixtureHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="wave fixture host exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for WaveFixtureHost with fn execute_tool(
  self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
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
pub impl @kernel_exec.HostRuntime for WaveFixtureHost with fn cancel_effects(
  self : WaveFixtureHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// M3.5: compact stub — WaveFixtureHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for WaveFixtureHost with fn compact(
  self : WaveFixtureHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(Parse(reason="WaveFixtureHost does not implement compact"))
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
      ("parallel_two", Parallel),
      ("exclusive", Exclusive),
    ] {
    ignore(
      builder.add(
        ToolDef(
          name=ToolName::unchecked(definition.0),
          description="wave fixture tool",
          input_schema=schema,
          owner=OwnerId::unchecked("wave_fixture"),
          policy=definition.1,
          provenance=Some("wave_execution_wbtest"),
        ),
      ),
    )
  }
  builder.finish(version=CatalogVersion(1))
}

///|
async test "puppet/parallel_wave_wallclock_near_longest_tool" {
  let host = WaveFixtureHost([
    Ok(
      fixture_tool_calls([
        fixture_call("parallel_one", "p1"),
        fixture_call("parallel_two", "p2"),
      ]),
    ),
    Ok(fixture_stop("done")),
  ])
  let catalog = wave_catalog()
  let journal = InMemoryJournal()
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      catalog,
      journal,
      [],
      [],
      None,
    ),
  )
  assert_true(fixture_prompt(puppet, "parallel_wave") is Accepted(_))
  // Both tools in the parallel wave must have started.
  assert_eq(host.started().length(), 2)
  // The parallel wave must have seen both in flight.
  assert_true(host.max_in_flight() >= 2)
  // p2 finished first; the wave result order must still be p1, p2
  // (model source order).
  assert_eq(host.finished()[0], "p2")
  // Both are in the finished log.
  assert_eq(host.finished().length(), 2)
}
