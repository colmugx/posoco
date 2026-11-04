///|
/// Bind a mailbox to fixed ids and return it.
fn bind_test_mailbox() -> @puppetry.ControlMailbox {
  let mb = @puppetry.ControlMailbox()
  mb.bind_run(
    @kernel_exec.RunId::unchecked("run_b"),
    @kernel.TurnId::unchecked("turn_b"),
  )
  mb
}

///|
async test "m35_builtin/fork_here_default_index_zero" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  let outcome = port.invoke("fork-here", Json::null())
  assert_true(outcome is Success(_))
  let cmd = mb.consume_one_fork()
  match cmd {
    Some(c) => assert_true(c.fork_index() == 0)
    None => assert_true(false)
  }
}

///|
async test "m35_builtin/idle_compact_starts_compact_session_directly" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Compact(result={
      compacted_messages: [@test_support.tk_user_msg("summary")],
      mode: Replace,
    }),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("idle-session", {
    messages: [
      @test_support.tk_user_msg("hello"),
      @test_support.tk_user_msg("more"),
    ],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let mut builtin : &@port.CommandPort? = None
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == "compact" {
        builtin = Some(port)
      }
    }
  }
  guard builtin is Some(port) else {
    fail("expected the builtin compact command to be declared")
  }
  let outcome = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("idle-session"))]),
    ),
  )
  guard outcome is Success(feedback~, ..) else {
    fail("expected idle compact to succeed, got \{repr(outcome)}")
  }
  assert_true(feedback.contains("compact completed"))
  assert_eq(model.call_count(), 0)
  assert_eq(model.compact_call_count(), 1)
  let compacts = model.received_compacts()
  assert_eq(compacts[0].0.length(), 2)
  let persisted = store.store["idle-session"]
  assert_eq(persisted.messages.length(), 1)
  assert_true(persisted.messages[0] == @test_support.tk_user_msg("summary"))
}

///|
async test "m35_builtin/idle_compact_requires_session_identity" {
  let mb = @puppetry.ControlMailbox()
  let port = BuiltinCommandPort(mb)
  let outcome = port.invoke("compact", Json::null())
  guard outcome is Failure(reason~) else {
    fail("expected a failure for missing session identity")
  }
  assert_true(reason.contains("session_id"))
}

///|
async test "m35_builtin/idle_compact_reports_modelport_failure_not_locked_session" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::CompactFail(
      error=ResponseParse("no compact endpoint"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("fail-session", {
    messages: [@test_support.tk_user_msg("hello")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let mut builtin : &@port.CommandPort? = None
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == "compact" {
        builtin = Some(port)
      }
    }
  }
  guard builtin is Some(port) else {
    fail("expected the builtin compact command to be declared")
  }
  let outcome = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("fail-session"))]),
    ),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("compact failed"))
  assert_eq(store.store["fail-session"].messages.length(), 1)
  let retry = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("fail-session"))]),
    ),
  )
  match retry {
    Failure(reason~) =>
      assert_true(
        reason.contains("compact failed"),
        msg="retry must fail with the same model-port failure class",
      )
    _ => fail("expected the retried compact to fail the same way")
  }
}

///|
async test "m35_builtin/unknown_id_raises_not_found" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  try port.invoke("nope", Json::null()) catch {
    NotFound(id) => assert_true(id == "nope")
    _ => assert_true(false)
  } noraise {
    _ => assert_true(false)
  }
}

///|
/// BuiltinCommandPort constructed from a mailbox shares the instance.
/// Enqueue through the port's `invoke("/compact")` then consume directly
/// from the original mailbox reference — they must agree.

///|
/// Enqueue through the trait reference, consume through the concrete type.
/// Verifies trait dispatch and instance sharing are consistent.
// ──────────────────────────────────────────────────────────────────────────
// Per-Agent singleton BuiltinCommandPort.
//
// The port is a per-Agent singleton, so `seq` stays monotonic across the
// whole session instead of restarting every turn.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Repeated invokes on the SAME BuiltinCommandPort instance produce
/// distinct, monotonically increasing command ids. This is the contract
// a per-Agent singleton must uphold.

///|
/// The port is constructed before the runtime exists, so a valid session_id
/// with no bound idle-compact entry must yield the dedicated diagnostic —
/// not the missing-argument failure and not a panic.
async test "m35_builtin/idle_compact_without_bound_runtime_reports_unavailable" {
  // No bound run on the mailbox, so invoke reaches the idle-compact branch.
  let port = BuiltinCommandPort(@puppetry.ControlMailbox())
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("any-session"))])),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the unbound idle compact to fail, got \{repr(outcome)}")
  }
  assert_true(
    reason.contains("no active run and no agent runtime bound"),
    msg="unbound idle compact must report the dedicated diagnostic",
  )
}
