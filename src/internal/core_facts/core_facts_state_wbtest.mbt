///|
test "core_facts/h2_missing_provenance_not_revived_by_rewrite" {
  let shadow = CoreFacts::CoreFacts()
  shadow.mark_missing_provenance("missing-child")
  shadow.record_boundary("run-1", "missing-child", 1, "sp-1", false, [
    @test_support.tk_user_msg("rewritten"),
  ])
  match
    shadow.record_terminal(
      "missing-child",
      "run-1",
      [@test_support.tk_user_msg("terminal")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(_) => ()
  }
  assert_false(shadow.store.sessions.contains("missing-child"))
  match shadow.state.get("missing-child") {
    Some(MissingProvenance) => ()
    _ => fail("expected missing provenance to survive the rewrite")
  }
}

///|
test "core_facts/late_run_terminal_is_rejected" {
  let shadow = CoreFacts::CoreFacts()
  match
    shadow.hydrate(
      "late-parent",
      [@test_support.tk_user_msg("old")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "late-parent",
      [@test_support.tk_user_msg("old")],
      Map::from_array([]),
      [@test_support.tk_user_msg("old")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  let late = shadow.record_terminal(
    "late-parent",
    "run-2",
    [@test_support.tk_user_msg("late")],
    Map::from_array([]),
  )
  match late {
    Err(_) => ()
    Ok(_) => fail("expected a late run terminal to be rejected")
  }
  let current = shadow.store.current("late-parent") catch {
    _ => fail("expected the original core body")
  }
  assert_true(current.session.messages[0] == @test_support.tk_user_msg("old"))
  match shadow.state.get("late-parent") {
    Some(Tracking(run_id~)) => assert_eq(run_id, "run-1")
    _ => fail("expected the original run to remain tracking")
  }
  shadow.record_boundary("run-1", "late-parent", 1, "sp-1", true, [
    @test_support.tk_user_msg("done"),
  ])
  match
    shadow.record_terminal(
      "late-parent",
      "run-1",
      [@test_support.tk_user_msg("done")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  let done = shadow.store.current("late-parent") catch {
    _ => fail("expected the terminal core body")
  }
  assert_true(done.session.messages[0] == @test_support.tk_user_msg("done"))
  match shadow.store.sessions["late-parent"].versions[2].body {
    Append(tail~) => assert_eq(tail.length(), 0)
    Full(..) => fail("terminal metadata update must not create a Full body")
  }
}

///|
test "core_facts/duplicate_boundary_is_ignored" {
  let shadow = CoreFacts::CoreFacts()
  match
    shadow.hydrate(
      "boundary-parent",
      [@test_support.tk_user_msg("seed")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "boundary-parent",
      [@test_support.tk_user_msg("seed")],
      Map::from_array([]),
      [@test_support.tk_user_msg("seed")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  shadow.record_boundary("run-1", "boundary-parent", 1, "sp-1", false, [
    @test_support.tk_user_msg("seed"),
    @test_support.tk_user_msg("one"),
  ])
  let first = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the first committed boundary")
  }
  assert_eq(first.version, 1)
  match shadow.store.sessions["boundary-parent"].versions[1].body {
    Append(..) => ()
    Full(..) => fail("prefix growth must use Append, not Full")
  }
  shadow.record_boundary("run-1", "boundary-parent", 1, "sp-1", false, [
    @test_support.tk_user_msg("seed"),
    @test_support.tk_user_msg("poison"),
  ])
  let duplicate = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the duplicate boundary")
  }
  assert_eq(duplicate.version, 1)
  assert_true(duplicate.session.messages[1] == @test_support.tk_user_msg("one"))
  shadow.record_boundary("run-1", "boundary-parent", 2, "sp-2", true, [
    @test_support.tk_user_msg("seed"),
    @test_support.tk_user_msg("one"),
    @test_support.tk_user_msg("two"),
  ])
  let terminal = shadow.store.current("boundary-parent") catch {
    _ => fail("expected the terminal boundary")
  }
  assert_eq(terminal.version, 2)
  assert_eq(terminal.session.messages.length(), 3)
  assert_true(shadow_is_state_complete(shadow, "boundary-parent"))
}

///|
fn shadow_is_state_complete(shadow : CoreFacts, session_id : String) -> Bool {
  match shadow.state.get(session_id) {
    Some(Complete) => true
    _ => false
  }
}

///|
test "core_facts/terminal_body_mismatch_is_rejected_without_overwrite" {
  let shadow = CoreFacts::CoreFacts()
  match
    shadow.hydrate(
      "terminal-mismatch",
      [@test_support.tk_user_msg("seed")],
      Map::from_array([]),
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  match
    shadow.admit(
      "terminal-mismatch",
      [@test_support.tk_user_msg("seed")],
      Map::from_array([]),
      [@test_support.tk_user_msg("seed")],
      "run-1",
    ) {
    Ok(_) => ()
    Err(detail) => fail(detail)
  }
  shadow.record_boundary("run-1", "terminal-mismatch", 1, "sp-1", true, [
    @test_support.tk_user_msg("seed"),
    @test_support.tk_user_msg("committed"),
  ])
  match
    shadow.record_terminal(
      "terminal-mismatch",
      "run-1",
      [@test_support.tk_user_msg("forged")],
      Map::from_array([]),
    ) {
    Err(_) => ()
    Ok(_) => fail("expected the mismatched terminal body to be rejected")
  }
  let current = shadow.store.current("terminal-mismatch") catch {
    _ => fail("expected the committed body")
  }
  assert_eq(current.session.messages.length(), 2)
  assert_true(
    current.session.messages[1] == @test_support.tk_user_msg("committed"),
  )
  match shadow.state.get("terminal-mismatch") {
    Some(Stopped(reason~, ..)) => assert_eq(reason, "terminal_body_mismatch")
    _ => fail("expected the mismatch to stop shadow completion")
  }
}
