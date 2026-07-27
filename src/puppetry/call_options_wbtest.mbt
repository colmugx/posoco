///|
/// The composition root owns provider options; the pump forwards the same
/// opaque value into every model effect without a per-turn default rewrite.

///|
async test "puppet/call_options_reach_model_effect" {
  let host = FixtureHost([Ok(fixture_stop("done"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let options = Json::object(
    Map::from_array([
      ("temperature", Json::number(0.25)),
      ("max_output_tokens", Json::number(128.0)),
    ]),
  )
  let catalog = fixture_empty_catalog()
  let config = canonical_puppet_config(
    host.bind_catalog(catalog),
    catalog,
    journal,
    [],
    [],
    None,
    options,
  )
  let puppet = Puppet(config)

  assert_true(fixture_prompt(puppet, "call_options") is Accepted(_))
  assert_eq(host.observed_call_options(), [options])
}
