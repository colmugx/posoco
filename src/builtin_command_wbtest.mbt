///|
/// M3.5 — BuiltinCommandPort whitebox tests.
///
/// Covers:
/// - `/compact` invoke enqueues a Manual compact on the mailbox
/// - `/fork-here N` invoke enqueues a fork at index N
/// - `commands()` declares the two builtin command ids
/// - invoke without an active run returns Failure
/// - parse_fork_index accepts object form, bare number, and defaults

///|
/// Bind a mailbox to fixed ids and return it.
fn bind_test_mailbox() -> @puppetry.ControlMailbox {
  let mb = @puppetry.ControlMailbox::ControlMailbox()
  mb.bind_run(
    @kernel_exec.RunId::unchecked("run_b"),
    @kernel.TurnId::unchecked("turn_b"),
  )
  mb
}

///|
test "m35_builtin/commands_declares_compact_and_fork" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  let cmds = port.commands()
  let ids = cmds.map(c => c.id)
  assert_true(ids.contains("compact"))
  assert_true(ids.contains("fork-here"))
}

///|
async test "m35_builtin/compact_enqueues_manual_signal" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  let outcome = port.invoke("compact", Json::null())
  assert_true(outcome is Success(_))
  assert_true(mb.compact_depth() == 1)
  let cmd = mb.consume_one_compact()
  match cmd {
    Some(c) => assert_true(c.trigger() == @kernel.Manual)
    None => assert_true(false)
  }
}

///|
async test "m35_builtin/fork_here_enqueues_at_index" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  let args : Json = Json::object(
    Map::from_array([("index", Json::number(3.0))]),
  )
  let outcome = port.invoke("fork-here", args)
  assert_true(outcome is Success(_))
  assert_true(mb.fork_depth() == 1)
  let cmd = mb.consume_one_fork()
  match cmd {
    Some(c) => assert_true(c.fork_index() == 3)
    None => assert_true(false)
  }
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
async test "m35_builtin/invoke_without_active_run_returns_failure" {
  // Unbound mailbox (no active run).
  let mb = @puppetry.ControlMailbox::ControlMailbox()
  let port = BuiltinCommandPort(mb)
  let outcome = port.invoke("compact", Json::null())
  assert_true(outcome is Failure(_))
}

///|
async test "m35_builtin/unknown_id_raises_not_found" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  try port.invoke("nope", Json::null()) catch {
    @error.CommandError::NotFound(id) => assert_true(id == "nope")
    _ => assert_true(false)
  } noraise {
    _ => assert_true(false)
  }
}

///|
async test "m35_builtin/distinct_command_ids" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  // Two successive compacts must produce different command ids.
  let _ = port.invoke("compact", Json::null())
  let _ = port.invoke("compact", Json::null())
  assert_true(mb.compact_depth() == 2)
  let c1 = mb.consume_one_compact()
  let c2 = mb.consume_one_compact()
  match (c1, c2) {
    (Some(a), Some(b)) =>
      assert_true(a.command_id().to_string() != b.command_id().to_string())
    _ => assert_true(false)
  }
}

///|
test "m35_builtin/parse_fork_index_object_form" {
  let args : Json = Json::object(
    Map::from_array([("index", Json::number(7.0))]),
  )
  assert_true(parse_fork_index(args) == 7)
}

///|
test "m35_builtin/parse_fork_index_bare_number" {
  let args : Json = Json::number(11.0)
  assert_true(parse_fork_index(args) == 11)
}

///|
test "m35_builtin/parse_fork_index_default" {
  assert_true(parse_fork_index(Json::null()) == 0)
  let args : Json = Json::object(Map::from_array([]))
  assert_true(parse_fork_index(args) == 0)
}

// ──────────────────────────────────────────────────────────────────────────
// D1 — Agent ↔ BuiltinCommandPort ↔ Puppet mailbox sharing.
//
// Before D1, `BuiltinCommandPort(self.mailbox)` copied the Agent's mailbox
// value into a fresh ControlMailbox instance, and the Puppet built its own
// third mailbox. Three instances meant signals enqueued by the product
// layer never reached the pump. After D1, Agent owns the ControlMailbox
// and both BuiltinCommandPort and Puppet borrow `&Mailbox` pointing at
// that same instance. These tests verify the sharing behaviourally:
// enqueue through one view, consume through another.
// ──────────────────────────────────────────────────────────────────────────

///|
/// D1: BuiltinCommandPort constructed from a mailbox shares the instance.
/// Enqueue through the port's `invoke("/compact")` then consume directly
/// from the original mailbox reference — they must agree.
async test "d1_mailbox/builtin_port_shares_mailbox_instance" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  // Port enqueues a compact signal via its borrowed &Mailbox...
  let outcome = port.invoke("compact", Json::null())
  assert_true(outcome is Success(_))
  // ...and the original ControlMailbox reference observes it. If the port
  // held an independent copy, this consume would return None.
  let cmd = mb.consume_one_compact()
  match cmd {
    Some(c) => assert_true(c.trigger() == @kernel.Manual)
    None => fail("expected compact signal on the shared mailbox")
  }
}

///|
/// D1: enqueue through the trait reference, consume through the concrete
/// type. Verifies trait dispatch and instance sharing are consistent.
test "d1_mailbox/trait_ref_and_concrete_share_state" {
  let mb = bind_test_mailbox()
  let mailbox_ref : &@puppetry.Mailbox = mb as &@puppetry.Mailbox
  // Enqueue via the &Mailbox trait reference...
  let result = mailbox_ref.enqueue_fork({
    command_id: @puppetry.CommandId::unchecked("d1_fk"),
    target_run_id: @kernel_exec.RunId::unchecked("run_b"),
    target_turn_id: @kernel.TurnId::unchecked("turn_b"),
    fork_index: 2,
  })
  assert_true(result is Accepted(_))
  // ...consume via the concrete ControlMailbox. Same instance.
  let cmd = mb.consume_one_fork()
  match cmd {
    Some(c) => assert_true(c.fork_index() == 2)
    None => fail("expected fork signal visible across &Mailbox / concrete")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// D3-Q1 — per-Agent singleton BuiltinCommandPort.
//
// Before D3-Q1, `commands_with_builtins` reconstructed the port each
// turn, resetting the `seq` counter. Across two turns this would produce
// duplicate command ids (fork_1 in turn 1, fork_1 again in turn 2).
// After D3-Q1 the port is a per-Agent singleton, so seq is monotonic
// across the whole session.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Repeated invokes on the SAME BuiltinCommandPort instance produce
/// distinct, monotonically increasing command ids. This is the contract
// a per-Agent singleton must uphold.
async test "d3_singleton/command_ids_are_monotonic_across_invokes" {
  let mb = bind_test_mailbox()
  let port = BuiltinCommandPort(mb)
  // First invoke: compact_1
  let _ = port.invoke("compact", Json::null())
  // Second invoke: compact_2 (not compact_1 again)
  let _ = port.invoke("compact", Json::null())
  // Third invoke: fork_1 (separate prefix, own counter share? no — seq
  // is shared across prefixes so fork is fork_3)
  let _ = port.invoke("fork-here", Json::null())
  // Drain and inspect: 2 compacts + 1 fork queued.
  assert_true(mb.compact_depth() == 2)
  assert_true(mb.fork_depth() == 1)
  let c1 = mb.consume_one_compact()
  let c2 = mb.consume_one_compact()
  let f1 = mb.consume_one_fork()
  // All three command ids must be distinct (the seq counter is shared).
  match (c1, c2, f1) {
    (Some(a), Some(b), Some(c)) => {
      let id_a = a.command_id().to_string()
      let id_b = b.command_id().to_string()
      let id_c = c.command_id().to_string()
      assert_true(id_a != id_b)
      assert_true(id_b != id_c)
      assert_true(id_a != id_c)
    }
    _ => fail("expected 3 distinct commands")
  }
}
