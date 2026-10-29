///|
/// Whitebox tests for the private immutable core-version slice
/// (`src/agent_core_versions.mbt`). Covers full/append/rewrite/current,
/// historical materialization, source references (including a prefix that
/// falls inside a version and a source pinned before a parent rewrite),
/// derived sessions and their source retention, deep snapshot isolation in
/// both directions, loud failures for invalid references, per-sid version
/// identity, and long append chains.

///|
/// Test-only prefix derivation using the production resolve + content APIs.
fn record_derived_prefix(
  store : CoreVersionStore,
  sid : String,
  source : CoreSource,
) -> Int32 raise CoreVersionError {
  let window = store.resolve_source(source)
  store.record_derived_content(sid, source, window.messages, window.metadata)
}

///|
test "core_versions/full_then_append_and_current" {
  let store = CoreVersionStore::CoreVersionStore()
  let v0 = store.record_full(
    "s",
    [tk_user_msg("one"), tk_user_msg("two")],
    Map::from_array([("tag", Json::string("v0"))]),
  )
  assert_eq(v0, 0)
  let v1 = store.append(
    "s",
    [tk_user_msg("three")],
    Map::from_array([("tag", Json::string("v1"))]),
  )
  assert_eq(v1, 1)
  let now = store.current("s")
  assert_eq(now.version, 1)
  assert_eq(now.session.messages.length(), 3)
  assert_true(now.session.messages[0] == tk_user_msg("one"))
  assert_true(now.session.messages[1] == tk_user_msg("two"))
  assert_true(now.session.messages[2] == tk_user_msg("three"))
  assert_eq(now.session.metadata["tag"], Json::string("v1"))
}

///|
test "core_versions/rewrite_keeps_old_versions_materializable" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "s",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("v0"))]),
    ),
  )
  ignore(
    store.append(
      "s",
      [tk_user_msg("three")],
      Map::from_array([("tag", Json::string("v1"))]),
    ),
  )
  let v2 = store.rewrite(
    "s",
    [tk_user_msg("rewritten")],
    Map::from_array([("tag", Json::string("v2"))]),
  )
  assert_eq(v2, 2)
  let now = store.current("s")
  assert_eq(now.version, 2)
  assert_eq(now.session.messages.length(), 1)
  assert_true(now.session.messages[0] == tk_user_msg("rewritten"))
  assert_eq(now.session.metadata["tag"], Json::string("v2"))
  // The pre-rewrite versions stay addressable with their own content.
  let v1 = store.materialize("s", 1)
  assert_eq(v1.messages.length(), 3)
  assert_true(v1.messages[2] == tk_user_msg("three"))
  assert_eq(v1.metadata["tag"], Json::string("v1"))
  let v0 = store.materialize("s", 0)
  assert_eq(v0.messages.length(), 2)
  assert_eq(v0.metadata["tag"], Json::string("v0"))
}

///|
test "core_versions/source_prefix_in_middle_of_version" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "s",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("v0"))]),
    ),
  )
  ignore(
    store.append(
      "s",
      [tk_user_msg("three")],
      Map::from_array([("tag", Json::string("v1"))]),
    ),
  )
  // Prefix lands inside the appended version's materialized window.
  let mid = store.resolve_source({ sid: "s", version: 1, prefix: 2, })
  assert_eq(mid.messages.length(), 2)
  assert_true(mid.messages[0] == tk_user_msg("one"))
  assert_true(mid.messages[1] == tk_user_msg("two"))
  assert_eq(mid.metadata["tag"], Json::string("v1"))
  let empty = store.resolve_source({ sid: "s", version: 1, prefix: 0, })
  assert_eq(empty.messages.length(), 0)
  let whole = store.resolve_source({ sid: "s", version: 1, prefix: 3, })
  assert_eq(whole.messages.length(), 3)
  // A prefix pinned to the older version reads only that version's window.
  let older = store.resolve_source({ sid: "s", version: 0, prefix: 2, })
  assert_eq(older.messages.length(), 2)
  assert_eq(older.metadata["tag"], Json::string("v0"))
}

///|
test "core_versions/source_survives_parent_rewrite" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two"), tk_user_msg("three")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 3, }
  // The parent evolves and is finally rewritten wholesale.
  ignore(store.append("p", [tk_user_msg("four")], Map::from_array([])))
  ignore(store.rewrite("p", [tk_user_msg("replaced")], Map::from_array([])))
  // The pinned reference still resolves to the original content.
  let resolved = store.resolve_source(source)
  assert_eq(resolved.messages.length(), 3)
  assert_true(resolved.messages[0] == tk_user_msg("one"))
  assert_true(resolved.messages[1] == tk_user_msg("two"))
  assert_true(resolved.messages[2] == tk_user_msg("three"))
  assert_eq(resolved.metadata["tag"], Json::string("origin"))
}

///|
test "core_versions/input_mutation_does_not_leak_into_history" {
  let store = CoreVersionStore::CoreVersionStore()
  let content : Array[@kernel.Content] = [Text("hello")]
  let calls : Array[@kernel.ToolCall] = [
    {
      call_id: @kernel.CallId::unchecked("c1"),
      name: @kernel.ToolName::unchecked("leaf"),
      arguments: Json::object(Map::from_array([("k", Json::string("v"))])),
    },
  ]
  let assistant : @kernel.Message = AssistantMessage(
    content~,
    tool_calls=calls,
    reasoning=None,
    finish_reason=Stop,
  )
  let messages : Array[@kernel.Message] = [tk_user_msg("one"), assistant]
  let metadata : Map[String, Json] = Map::from_array([
    ("nested", Json::object(Map::from_array([("k", Json::string("v"))]))),
  ])
  ignore(store.record_full("iso", messages, metadata))
  // Mutate every level of the inputs after the write.
  content.push(Text("poison"))
  calls.push({
    call_id: @kernel.CallId::unchecked("poison"),
    name: @kernel.ToolName::unchecked("poison"),
    arguments: Json::null(),
  })
  messages.push(tk_user_msg("poison"))
  match metadata["nested"] {
    Object(fields) => fields["poison"] = Json::string("poison")
    _ => fail("expected nested metadata object")
  }
  let read = store.materialize("iso", 0)
  assert_eq(read.messages.length(), 2)
  guard read.messages[1] is AssistantMessage(content~, tool_calls~, ..) else {
    fail("expected the assistant message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected text content") }
  assert_eq(text, "hello")
  assert_eq(tool_calls.length(), 1)
  assert_eq(tool_calls[0].name.to_string(), "leaf")
  match tool_calls[0].arguments {
    Object(fields) => assert_false(fields.contains("poison"))
    _ => fail("expected object arguments")
  }
  match read.metadata["nested"] {
    Object(fields) => assert_false(fields.contains("poison"))
    _ => fail("expected nested metadata object")
  }
}

///|
test "core_versions/output_mutation_does_not_leak_into_history" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "iso",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("v0"))]),
    ),
  )
  let first = store.materialize("iso", 0)
  first.messages.push(tk_user_msg("poison"))
  match first.messages[0] {
    UserMessage(content~) => content.push(Text("poison"))
    _ => fail("expected a user message")
  }
  first.metadata["tag"] = Json::string("poison")
  let again = store.materialize("iso", 0)
  assert_eq(again.messages.length(), 2)
  guard again.messages[0] is UserMessage(content~) else {
    fail("expected a user message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected text content") }
  assert_eq(text, "one")
  assert_eq(again.metadata["tag"], Json::string("v0"))
  // `current` returns fresh snapshots too.
  let current = store.current("iso").session
  current.messages.push(tk_user_msg("poison"))
  assert_eq(store.current("iso").session.messages.length(), 2)
}

///|
/// Run a body that must raise a core-version error and return what it raised
/// (None when it did not raise). Keeps the failure assertions free of
/// catch/noraise type-inference noise.
fn core_version_error_of(
  body : () -> Unit raise CoreVersionError,
) -> CoreVersionError? {
  let raised : CoreVersionError? = None
  let captured = Ref(raised)
  body() catch {
    error => captured.val = Some(error)
  }
  captured.val
}

///|
test "core_versions/invalid_references_fail_loudly" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(store.record_full("s", [tk_user_msg("one")], Map::from_array([])))
  ignore(store.record_full("other", [tk_user_msg("a")], Map::from_array([])))
  let cases : Array[(() -> Unit raise CoreVersionError, String)] = [
    (() => ignore(store.materialize("missing", 0)), "UnknownSession"),
    (() => ignore(store.current("missing")), "UnknownSession"),
    (
      () => {
        ignore(store.append("missing", [tk_user_msg("x")], Map::from_array([])))
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(
          store.rewrite("missing", [tk_user_msg("x")], Map::from_array([])),
        )
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(store.resolve_source({ sid: "missing", version: 0, prefix: 0, }))
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(store.record_full("s", [tk_user_msg("x")], Map::from_array([])))
      },
      "SessionExists",
    ),
    (() => ignore(store.materialize("s", 1)), "UnknownVersion"),
    (() => ignore(store.materialize("s", -1)), "UnknownVersion"),
    (
      () => ignore(store.resolve_source({ sid: "s", version: 1, prefix: 0, })),
      "UnknownVersion",
    ),
    (
      () => ignore(store.resolve_source({ sid: "s", version: 0, prefix: 2, })),
      "PrefixOutOfRange",
    ),
    (
      () => ignore(store.resolve_source({ sid: "s", version: 0, prefix: -1, })),
      "PrefixOutOfRange",
    ),
  ]
  for entry in cases {
    let (body, expected) = entry
    match core_version_error_of(body) {
      Some(UnknownSession(sid~)) => {
        assert_eq(expected, "UnknownSession")
        assert_true(sid == "missing")
      }
      Some(SessionExists(sid~)) => {
        assert_eq(expected, "SessionExists")
        assert_eq(sid, "s")
      }
      Some(UnknownVersion(sid~, version~)) => {
        assert_eq(expected, "UnknownVersion")
        assert_eq(sid, "s")
        assert_true(version == 1 || version == -1)
      }
      Some(PrefixOutOfRange(sid~, version~, prefix~, available~)) => {
        assert_eq(expected, "PrefixOutOfRange")
        assert_eq(sid, "s")
        assert_eq(version, 0)
        assert_eq(available, 1)
        assert_true(prefix == 2 || prefix == -1)
      }
      None => fail("expected \{expected}, but nothing was raised")
    }
  }
}

///|
test "core_versions/long_append_chain_materializes_iteratively" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(store.record_full("s", [tk_user_msg("seed")], Map::from_array([])))
  for i in 0..<300 {
    ignore(
      store.append(
        "s",
        [tk_user_msg("m\{i}")],
        Map::from_array([("i", Json::number(i.to_double()))]),
      ),
    )
  }
  let now = store.current("s")
  assert_eq(now.version, 300)
  assert_eq(now.session.messages.length(), 301)
  assert_true(now.session.messages[0] == tk_user_msg("seed"))
  assert_true(now.session.messages[300] == tk_user_msg("m299"))
  // Historical materialization reaches the base across the whole chain.
  let base = store.materialize("s", 0)
  assert_eq(base.messages.length(), 1)
  assert_true(base.messages[0] == tk_user_msg("seed"))
  let middle = store.materialize("s", 150)
  assert_eq(middle.messages.length(), 151)
  assert_eq(middle.metadata["i"], Json::number(149.0))
  // A rewrite starts a new chain that also materializes correctly.
  let rewritten = store.rewrite(
    "s",
    [tk_user_msg("fresh")],
    Map::from_array([("tag", Json::string("rewrite"))]),
  )
  assert_eq(rewritten, 301)
  for i in 0..<300 {
    ignore(store.append("s", [tk_user_msg("n\{i}")], Map::from_array([])))
  }
  let after = store.current("s")
  assert_eq(after.version, 601)
  assert_eq(after.session.messages.length(), 301)
  assert_true(after.session.messages[0] == tk_user_msg("fresh"))
  assert_true(after.session.messages[300] == tk_user_msg("n299"))
  // The pre-rewrite chain remains readable.
  let before = store.materialize("s", 300)
  assert_eq(before.messages.length(), 301)
  assert_true(before.messages[0] == tk_user_msg("seed"))
}

///|
fn assert_core_source(
  source : CoreSource?,
  sid : String,
  version : Int32,
  prefix : Int32,
) -> Unit raise {
  match source {
    Some(value) => {
      assert_eq(value.sid, sid)
      assert_eq(value.version, version)
      assert_eq(value.prefix, prefix)
    }
    None => fail("expected a derived version source")
  }
}

///|
fn assert_no_core_source(source : CoreSource?) -> Unit raise {
  match source {
    None => ()
    Some(_) => fail("expected a root version without a source")
  }
}

///|
test "core_versions/derived_version_pins_historical_source_across_parent_rewrite" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two"), tk_user_msg("three")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 2, }
  let v0 = record_derived_prefix(store, "c", source)
  assert_eq(v0, 0)
  assert_core_source(store.sessions["c"].versions[0].source, "p", 0, 2)
  let child = store.current("c")
  assert_eq(child.version, 0)
  assert_eq(child.session.messages.length(), 2)
  assert_true(child.session.messages[0] == tk_user_msg("one"))
  assert_true(child.session.messages[1] == tk_user_msg("two"))
  assert_eq(child.session.metadata["tag"], Json::string("origin"))
  // The parent keeps evolving and is finally rewritten wholesale.
  ignore(
    store.append(
      "p",
      [tk_user_msg("four")],
      Map::from_array([("tag", Json::string("p1"))]),
    ),
  )
  ignore(
    store.rewrite(
      "p",
      [tk_user_msg("replaced")],
      Map::from_array([("tag", Json::string("p2"))]),
    ),
  )
  assert_eq(store.current("p").version, 2)
  // The child still owns the pinned historical window and metadata.
  let after = store.current("c")
  assert_eq(after.version, 0)
  assert_eq(after.session.messages.length(), 2)
  assert_true(after.session.messages[0] == tk_user_msg("one"))
  assert_true(after.session.messages[1] == tk_user_msg("two"))
  assert_eq(after.session.metadata["tag"], Json::string("origin"))
  // Its stored source still resolves the parent's pre-rewrite version.
  let pinned = store.resolve_source(source)
  assert_eq(pinned.messages.length(), 2)
  assert_true(pinned.messages[0] == tk_user_msg("one"))
  assert_true(pinned.messages[1] == tk_user_msg("two"))
  assert_eq(pinned.metadata["tag"], Json::string("origin"))
}

///|
test "core_versions/derived_lineage_keeps_source_across_append_and_rewrite" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 1, }
  ignore(record_derived_prefix(store, "c", source))
  assert_core_source(store.sessions["c"].versions[0].source, "p", 0, 1)
  assert_no_core_source(store.sessions["p"].versions[0].source)
  let v1 = store.append(
    "c",
    [tk_user_msg("tail")],
    Map::from_array([("tag", Json::string("child1"))]),
  )
  assert_eq(v1, 1)
  assert_core_source(store.sessions["c"].versions[1].source, "p", 0, 1)
  let v2 = store.rewrite(
    "c",
    [tk_user_msg("fresh")],
    Map::from_array([("tag", Json::string("child2"))]),
  )
  assert_eq(v2, 2)
  assert_core_source(store.sessions["c"].versions[2].source, "p", 0, 1)
  let now = store.current("c")
  assert_eq(now.version, 2)
  assert_eq(now.session.messages.length(), 1)
  assert_true(now.session.messages[0] == tk_user_msg("fresh"))
  assert_eq(now.session.metadata["tag"], Json::string("child2"))
  // The pinned source still resolves to the original parent window.
  let pinned = store.resolve_source(source)
  assert_eq(pinned.messages.length(), 1)
  assert_true(pinned.messages[0] == tk_user_msg("one"))
}

///|
test "core_versions/derived_creation_failure_is_atomic" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let cases : Array[(() -> Unit raise CoreVersionError, String)] = [
    (
      () => {
        ignore(
          record_derived_prefix(store, "child", {
            sid: "p",
            version: 1,
            prefix: 0,
          }),
        )
      },
      "UnknownVersion",
    ),
    (
      () => {
        ignore(
          record_derived_prefix(store, "child", {
            sid: "p",
            version: 0,
            prefix: 2,
          }),
        )
      },
      "PrefixOutOfRange",
    ),
    (
      () => {
        ignore(
          record_derived_prefix(store, "child", {
            sid: "missing",
            version: 0,
            prefix: 0,
          }),
        )
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(
          record_derived_prefix(store, "self", {
            sid: "self",
            version: 0,
            prefix: 0,
          }),
        )
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(
          record_derived_prefix(store, "p", { sid: "p", version: 0, prefix: 0, }),
        )
      },
      "SessionExists",
    ),
  ]
  for entry in cases {
    let (body, expected) = entry
    match core_version_error_of(body) {
      Some(UnknownSession(..)) => assert_eq(expected, "UnknownSession")
      Some(SessionExists(..)) => assert_eq(expected, "SessionExists")
      Some(UnknownVersion(..)) => assert_eq(expected, "UnknownVersion")
      Some(PrefixOutOfRange(..)) => assert_eq(expected, "PrefixOutOfRange")
      None => fail("expected \{expected}, but nothing was raised")
    }
    assert_false(store.sessions.contains("child"))
    assert_false(store.sessions.contains("self"))
    assert_eq(store.current("p").version, 0)
    assert_eq(store.current("p").session.messages.length(), 1)
  }
  // An already-existing child also fails without moving it.
  ignore(
    record_derived_prefix(store, "child", { sid: "p", version: 0, prefix: 1, }),
  )
  ignore(store.record_full("other", [tk_user_msg("x")], Map::from_array([])))
  match
    core_version_error_of(() => {
      ignore(
        record_derived_prefix(store, "child", {
          sid: "other",
          version: 0,
          prefix: 0,
        }),
      )
    }) {
    Some(SessionExists(sid~)) => assert_eq(sid, "child")
    _ => fail("expected SessionExists for the existing child")
  }
  let child = store.current("child")
  assert_eq(child.version, 0)
  assert_eq(child.session.messages.length(), 1)
  assert_true(child.session.messages[0] == tk_user_msg("one"))
}

///|
test "core_versions/derived_content_v0_is_summary_and_source_stays_pinned" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two"), tk_user_msg("three")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 2, }
  let summary_metadata = Map::from_array([
    ("tag", Json::string("summary")),
    ("kind", Json::string("newthread")),
  ])
  let v0 = store.record_derived_content(
    "c",
    source,
    [tk_user_msg("summary")],
    summary_metadata,
  )
  assert_eq(v0, 0)
  assert_core_source(store.sessions["c"].versions[0].source, "p", 0, 2)
  let child = store.current("c")
  assert_eq(child.version, 0)
  assert_eq(child.session.messages.length(), 1)
  assert_true(child.session.messages[0] == tk_user_msg("summary"))
  assert_eq(child.session.metadata["tag"], Json::string("summary"))
  assert_eq(child.session.metadata["kind"], Json::string("newthread"))
  // The source still resolves the parent's original prefix, not the summary.
  let pinned = store.resolve_source(source)
  assert_eq(pinned.messages.length(), 2)
  assert_true(pinned.messages[0] == tk_user_msg("one"))
  assert_true(pinned.messages[1] == tk_user_msg("two"))
  assert_eq(pinned.metadata["tag"], Json::string("origin"))
  // Later parent changes cannot retarget either the child or its source.
  ignore(
    store.append(
      "p",
      [tk_user_msg("four")],
      Map::from_array([("tag", Json::string("p1"))]),
    ),
  )
  ignore(
    store.rewrite(
      "p",
      [tk_user_msg("replaced")],
      Map::from_array([("tag", Json::string("p2"))]),
    ),
  )
  let after = store.current("c")
  assert_eq(after.version, 0)
  assert_eq(after.session.messages.length(), 1)
  assert_true(after.session.messages[0] == tk_user_msg("summary"))
  assert_eq(after.session.metadata["tag"], Json::string("summary"))
  let still_pinned = store.resolve_source(source)
  assert_eq(still_pinned.messages.length(), 2)
  assert_true(still_pinned.messages[0] == tk_user_msg("one"))
  assert_true(still_pinned.messages[1] == tk_user_msg("two"))
  assert_eq(still_pinned.metadata["tag"], Json::string("origin"))
}

///|
test "core_versions/derived_content_lineage_keeps_creation_source" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 1, }
  ignore(
    store.record_derived_content(
      "c",
      source,
      [tk_user_msg("summary")],
      Map::from_array([("tag", Json::string("summary"))]),
    ),
  )
  let v1 = store.append(
    "c",
    [tk_user_msg("tail")],
    Map::from_array([("tag", Json::string("child1"))]),
  )
  assert_eq(v1, 1)
  let v2 = store.rewrite(
    "c",
    [tk_user_msg("fresh")],
    Map::from_array([("tag", Json::string("child2"))]),
  )
  assert_eq(v2, 2)
  // Every version keeps the source captured at creation, not a rewrite source.
  assert_core_source(store.sessions["c"].versions[0].source, "p", 0, 1)
  assert_core_source(store.sessions["c"].versions[1].source, "p", 0, 1)
  assert_core_source(store.sessions["c"].versions[2].source, "p", 0, 1)
  let now = store.current("c")
  assert_eq(now.version, 2)
  assert_eq(now.session.messages.length(), 1)
  assert_true(now.session.messages[0] == tk_user_msg("fresh"))
  assert_eq(now.session.metadata["tag"], Json::string("child2"))
  let pinned = store.resolve_source(source)
  assert_eq(pinned.messages.length(), 1)
  assert_true(pinned.messages[0] == tk_user_msg("one"))
}

///|
test "core_versions/derived_content_input_mutation_is_isolated" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 1, }
  let content : Array[@kernel.Content] = [Text("summary")]
  let summary_message : @kernel.Message = UserMessage(content~)
  let summary_messages : Array[@kernel.Message] = [summary_message]
  let nested : Map[String, Json] = Map::from_array([
    ("value", Json::string("clean")),
  ])
  let metadata : Map[String, Json] = Map::from_array([
    ("nested", Json::object(nested)),
  ])
  ignore(store.record_derived_content("c", source, summary_messages, metadata))
  // Mutate the caller-owned body and metadata after creation.
  content.push(Text("poison"))
  summary_messages.push(tk_user_msg("poison"))
  nested["poison"] = Json::string("poison")
  let read = store.current("c").session
  assert_eq(read.messages.length(), 1)
  guard read.messages[0] is UserMessage(content~) else {
    fail("expected the summary user message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected summary text") }
  assert_eq(text, "summary")
  match read.metadata["nested"] {
    Object(fields) => assert_false(fields.contains("poison"))
    _ => fail("expected nested metadata object")
  }
  let parent = store.current("p").session
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == tk_user_msg("one"))
}

///|
test "core_versions/derived_content_output_mutation_is_isolated" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source : CoreSource = { sid: "p", version: 0, prefix: 1, }
  ignore(
    store.record_derived_content(
      "c",
      source,
      [tk_user_msg("summary")],
      Map::from_array([
        (
          "nested",
          Json::object(Map::from_array([("value", Json::string("clean"))])),
        ),
      ]),
    ),
  )
  let first = store.current("c").session
  first.messages.push(tk_user_msg("poison"))
  guard first.messages[0] is UserMessage(content~) else {
    fail("expected the summary user message")
  }
  content.push(Text("poison"))
  match first.metadata["nested"] {
    Object(fields) => fields["poison"] = Json::string("poison")
    _ => fail("expected nested metadata object")
  }
  let again = store.current("c").session
  assert_eq(again.messages.length(), 1)
  guard again.messages[0] is UserMessage(content~) else {
    fail("expected the summary user message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected summary text") }
  assert_eq(text, "summary")
  match again.metadata["nested"] {
    Object(fields) => assert_false(fields.contains("poison"))
    _ => fail("expected nested metadata object")
  }
  // Mutating the derived output must not reach the source or parent body.
  let parent = store.current("p").session
  assert_eq(parent.messages.length(), 1)
  assert_true(parent.messages[0] == tk_user_msg("one"))
}

///|
test "core_versions/derived_content_creation_failure_is_atomic" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let body = [tk_user_msg("summary")]
  let metadata = Map::from_array([("tag", Json::string("summary"))])
  let cases : Array[(() -> Unit raise CoreVersionError, String)] = [
    (
      () => {
        ignore(
          store.record_derived_content(
            "child",
            { sid: "p", version: 1, prefix: 0, },
            body,
            metadata,
          ),
        )
      },
      "UnknownVersion",
    ),
    (
      () => {
        ignore(
          store.record_derived_content(
            "child",
            { sid: "p", version: 0, prefix: 2, },
            body,
            metadata,
          ),
        )
      },
      "PrefixOutOfRange",
    ),
    (
      () => {
        ignore(
          store.record_derived_content(
            "child",
            { sid: "missing", version: 0, prefix: 0, },
            body,
            metadata,
          ),
        )
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(
          store.record_derived_content(
            "self",
            { sid: "self", version: 0, prefix: 0, },
            body,
            metadata,
          ),
        )
      },
      "UnknownSession",
    ),
    (
      () => {
        ignore(
          store.record_derived_content(
            "p",
            { sid: "p", version: 0, prefix: 0, },
            body,
            metadata,
          ),
        )
      },
      "SessionExists",
    ),
  ]
  for entry in cases {
    let (attempt, expected) = entry
    match core_version_error_of(attempt) {
      Some(UnknownSession(..)) => assert_eq(expected, "UnknownSession")
      Some(SessionExists(..)) => assert_eq(expected, "SessionExists")
      Some(UnknownVersion(..)) => assert_eq(expected, "UnknownVersion")
      Some(PrefixOutOfRange(..)) => assert_eq(expected, "PrefixOutOfRange")
      None => fail("expected \{expected}, but nothing was raised")
    }
    assert_false(store.sessions.contains("child"))
    assert_false(store.sessions.contains("self"))
    assert_eq(store.current("p").version, 0)
    assert_eq(store.current("p").session.messages.length(), 1)
  }
  // A successful creation followed by a duplicate target stays untouched.
  ignore(
    store.record_derived_content(
      "child",
      { sid: "p", version: 0, prefix: 1, },
      body,
      metadata,
    ),
  )
  match
    core_version_error_of(() => {
      ignore(
        store.record_derived_content(
          "child",
          { sid: "p", version: 0, prefix: 0, },
          [tk_user_msg("replacement")],
          Map::from_array([]),
        ),
      )
    }) {
    Some(SessionExists(sid~)) => assert_eq(sid, "child")
    _ => fail("expected SessionExists for the existing child")
  }
  let child = store.current("child")
  assert_eq(child.version, 0)
  assert_eq(child.session.messages.length(), 1)
  assert_true(child.session.messages[0] == tk_user_msg("summary"))
  assert_eq(child.session.metadata["tag"], Json::string("summary"))
}

///|
test "core_versions/second_order_derivation_uses_immediate_source" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "p",
      [tk_user_msg("one"), tk_user_msg("two")],
      Map::from_array([("tag", Json::string("origin"))]),
    ),
  )
  let source1 : CoreSource = { sid: "p", version: 0, prefix: 2, }
  ignore(
    store.record_derived_content(
      "child1",
      source1,
      [tk_user_msg("summary1")],
      Map::from_array([("tag", Json::string("c1"))]),
    ),
  )
  let source2 : CoreSource = { sid: "child1", version: 0, prefix: 1, }
  let v0 = store.record_derived_content(
    "child2",
    source2,
    [tk_user_msg("summary2")],
    Map::from_array([("tag", Json::string("c2"))]),
  )
  assert_eq(v0, 0)
  assert_core_source(
    store.sessions["child2"].versions[0].source,
    "child1",
    0,
    1,
  )
  let pinned2 = store.resolve_source(source2)
  assert_eq(pinned2.messages.length(), 1)
  assert_true(pinned2.messages[0] == tk_user_msg("summary1"))
  assert_eq(pinned2.metadata["tag"], Json::string("c1"))
  // Rewriting either ancestor leaves child2 and its immediate source stable.
  ignore(
    store.rewrite(
      "p",
      [tk_user_msg("p-rewritten")],
      Map::from_array([("tag", Json::string("p2"))]),
    ),
  )
  ignore(
    store.rewrite(
      "child1",
      [tk_user_msg("c1-rewritten")],
      Map::from_array([("tag", Json::string("c1b"))]),
    ),
  )
  let after = store.current("child2")
  assert_eq(after.version, 0)
  assert_eq(after.session.messages.length(), 1)
  assert_true(after.session.messages[0] == tk_user_msg("summary2"))
  assert_eq(after.session.metadata["tag"], Json::string("c2"))
  let still_pinned = store.resolve_source(source2)
  assert_eq(still_pinned.messages.length(), 1)
  assert_true(still_pinned.messages[0] == tk_user_msg("summary1"))
  assert_eq(still_pinned.metadata["tag"], Json::string("c1"))
}

///|
test "core_versions/same_version_index_is_independent_per_sid" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(store.record_full("a", [tk_user_msg("a0")], Map::from_array([])))
  ignore(store.record_full("b", [tk_user_msg("b0")], Map::from_array([])))
  ignore(store.append("a", [tk_user_msg("a1")], Map::from_array([])))
  ignore(store.append("b", [tk_user_msg("b1")], Map::from_array([])))
  // The same index names different content under different sids.
  let a1 = store.materialize("a", 1)
  let b1 = store.materialize("b", 1)
  assert_true(a1.messages[0] == tk_user_msg("a0"))
  assert_true(a1.messages[1] == tk_user_msg("a1"))
  assert_true(b1.messages[0] == tk_user_msg("b0"))
  assert_true(b1.messages[1] == tk_user_msg("b1"))
  // Rewriting one sid does not advance or alter the other.
  ignore(store.rewrite("a", [tk_user_msg("ax")], Map::from_array([])))
  assert_eq(store.current("a").version, 2)
  let b = store.current("b")
  assert_eq(b.version, 1)
  assert_eq(b.session.messages.length(), 2)
  assert_true(b.session.messages[0] == tk_user_msg("b0"))
  assert_true(b.session.messages[1] == tk_user_msg("b1"))
}

///|
test "core_versions/failed_operations_keep_current" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "s",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("v0"))]),
    ),
  )
  ignore(
    store.append(
      "s",
      [tk_user_msg("two")],
      Map::from_array([("tag", Json::string("v1"))]),
    ),
  )
  let before = store.current("s")
  let failures : Array[() -> Unit raise CoreVersionError] = [
    () => {
      ignore(store.record_full("s", [tk_user_msg("x")], Map::from_array([])))
    },
    () => {
      ignore(store.append("missing", [tk_user_msg("x")], Map::from_array([])))
    },
    () => {
      ignore(store.rewrite("missing", [tk_user_msg("x")], Map::from_array([])))
    },
    () => ignore(store.materialize("s", 9)),
    () => ignore(store.resolve_source({ sid: "s", version: 9, prefix: 0, })),
    () => {
      ignore(
        record_derived_prefix(store, "child", {
          sid: "s",
          version: 9,
          prefix: 0,
        }),
      )
    },
  ]
  for body in failures {
    match core_version_error_of(body) {
      Some(_) => ()
      None => fail("expected a failed operation")
    }
  }
  assert_false(store.sessions.contains("child"))
  let after = store.current("s")
  assert_eq(after.version, before.version)
  assert_eq(after.session.messages.length(), before.session.messages.length())
  assert_true(after.session.messages[0] == before.session.messages[0])
  assert_true(after.session.messages[1] == before.session.messages[1])
  assert_eq(after.session.metadata["tag"], before.session.metadata["tag"])
}

///|
test "core_versions/empty_append_changes_metadata_only" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "s",
      [tk_user_msg("one")],
      Map::from_array([("tag", Json::string("v0"))]),
    ),
  )
  let v1 = store.append("s", [], Map::from_array([("tag", Json::string("v1"))]))
  assert_eq(v1, 1)
  let now = store.current("s")
  assert_eq(now.version, 1)
  assert_eq(now.session.messages.length(), 1)
  assert_true(now.session.messages[0] == tk_user_msg("one"))
  assert_eq(now.session.metadata["tag"], Json::string("v1"))
  // The previous version keeps its own metadata.
  let v0 = store.materialize("s", 0)
  assert_eq(v0.messages.length(), 1)
  assert_eq(v0.metadata["tag"], Json::string("v0"))
}

///|
test "core_versions/detached_source_snapshot_is_isolated_and_validated" {
  let store = CoreVersionStore::CoreVersionStore()
  ignore(
    store.record_full(
      "snapshot-parent",
      [tk_user_msg("seed")],
      Map::from_array([]),
    ),
  )
  let content : Array[@kernel.Content] = [Text("source")]
  let source_messages : Array[@kernel.Message] = [UserMessage(content~)]
  let metadata : Map[String, Json] = Map::from_array([
    (
      "nested",
      Json::object(Map::from_array([("value", Json::string("clean"))])),
    ),
  ])
  let version = store.record_source_snapshot(
    "snapshot-parent", source_messages, metadata,
  )
  assert_true(version < 0)
  let source : CoreSource = { sid: "snapshot-parent", version, prefix: 1, }
  let resolved = store.resolve_source(source)
  assert_eq(resolved.messages.length(), 1)
  guard resolved.messages[0] is UserMessage(content~) else {
    fail("expected the detached source user message")
  }
  assert_eq(content.length(), 1)
  guard content[0] is Text(text) else { fail("expected source text") }
  assert_eq(text, "source")
  // Input and output mutation must not alias the detached snapshot.
  match source_messages[0] {
    UserMessage(content=value) => value.push(Text("input-poison"))
    _ => ()
  }
  match metadata["nested"] {
    Object(fields) => fields["poison"] = Json::string("poison")
    _ => fail("expected nested metadata")
  }
  let first = store.resolve_source(source)
  guard first.messages[0] is UserMessage(content~) else {
    fail("expected source user message")
  }
  assert_eq(content.length(), 1)
  content.push(Text("output-poison"))
  match first.metadata["nested"] {
    Object(fields) => fields["poison"] = Json::string("output-poison")
    _ => fail("expected nested metadata")
  }
  let again = store.resolve_source(source)
  guard again.messages[0] is UserMessage(content~) else {
    fail("expected source user message")
  }
  assert_eq(content.length(), 1)
  match again.metadata["nested"] {
    Object(fields) => assert_false(fields.contains("poison"))
    _ => fail("expected nested metadata")
  }
  // Wrong sid, wrong prefix, and too-large prefix stay loud.
  match
    core_version_error_of(() => {
      ignore(store.resolve_source({ sid: "other", version, prefix: 0, }))
    }) {
    Some(UnknownVersion(..)) => ()
    _ => fail("expected UnknownVersion for a wrong snapshot sid")
  }
  match
    core_version_error_of(() => {
      ignore(
        store.resolve_source({ sid: "snapshot-parent", version, prefix: -1, }),
      )
    }) {
    Some(PrefixOutOfRange(..)) => ()
    _ => fail("expected PrefixOutOfRange for a negative prefix")
  }
  match
    core_version_error_of(() => {
      ignore(
        store.resolve_source({ sid: "snapshot-parent", version, prefix: 2, }),
      )
    }) {
    Some(PrefixOutOfRange(..)) => ()
    _ => fail("expected PrefixOutOfRange for an oversized prefix")
  }
}
