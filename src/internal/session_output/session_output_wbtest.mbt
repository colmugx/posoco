///|
fn output_user(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
async test "session_output/replace_body_retry_clears_only_after_success" {
  let output = SessionOutput::SessionOutput()
  output.stage_body("a", {
    messages: [output_user("a-body")],
    metadata: Map::from_array([]),
  })
  let saved = Ref(0)
  let should_fail = Ref(true)
  let attempt : Result[Unit, @error.AgentError] = Ok(
    output.recover_body("a", async fn(session) -> Unit raise @error.AgentError {
      @async.pause()
      saved.val = saved.val + 1
      if should_fail.val {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("offline"),
        )
      }
      if session.messages[0] != output_user("a-body") {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("wrong body"),
        )
      }
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(attempt is Err(_))
  assert_eq(saved.val, 1)
  should_fail.val = false
  output.recover_body("a", async fn(session) -> Unit raise @error.AgentError {
    @async.pause()
    saved.val = saved.val + 1
    if session.messages[0] != output_user("a-body") {
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("wrong body"),
      )
    }
  }) catch {
    error => fail(error.to_string())
  }
  assert_eq(saved.val, 2)
  let retried = Ref(false)
  output.recover_body("a", async fn(_session) -> Unit raise @error.AgentError {
    @async.pause()
    if retried.val {
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("unexpected retry"),
      )
    }
    retried.val = true
  }) catch {
    error => fail(error.to_string())
  }
  assert_false(retried.val)
}

///|
async test "session_output/body_snapshot_is_isolated" {
  let output = SessionOutput::SessionOutput()
  let messages = [output_user("before")]
  let metadata = Map::from_array([("k", Json::string("v"))])
  output.stage_body("iso", { messages, metadata, })
  messages[0] = output_user("poison")
  metadata["k"] = Json::string("poison")
  let seen = Ref("")
  let saved_meta = Ref("")
  output.recover_body("iso", async fn(session) -> Unit raise @error.AgentError {
    @async.pause()
    match session.messages[0] {
      @kernel.UserMessage(content=[@kernel.Text(text)]) => seen.val = text
      _ =>
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("expected user message"),
        )
    }
    match session.metadata["k"] {
      String(value) => saved_meta.val = value
      _ =>
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("expected metadata"),
        )
    }
  }) catch {
    error => fail(error.to_string())
  }
  assert_eq(seen.val, "before")
  assert_eq(saved_meta.val, "v")
}

///|
async test "session_output/new_thread_retry_is_deterministic_and_isolated" {
  let output = SessionOutput::SessionOutput()
  let scope : @types.EventScope = {
    session_id: @kernel.SessionId::unchecked("p"),
    run_id: @kernel.RunId::unchecked("r"),
    turn_id: @kernel.TurnId::unchecked("t"),
  }
  output.stage_new_thread(
    scope,
    "p",
    "child-b",
    [output_user("b")],
    Map::from_array([]),
    "label",
  )
  output.stage_new_thread(
    scope,
    "p",
    "child-a",
    [output_user("a")],
    Map::from_array([("k", Json::string("v"))]),
    "label",
  )
  let seen : Array[String] = []
  let should_fail = Ref(true)
  let attempt : Result[Unit, @error.AgentError] = Ok(
    output.recover_new_threads(async fn(
      pending,
    ) -> Unit raise @error.AgentError {
      @async.pause()
      seen.push(pending.child_session_id)
      pending.messages[0] = output_user("poison")
      pending.metadata["k"] = Json::string("poison")
      if should_fail.val {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("offline"),
        )
      }
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(attempt is Err(_))
  assert_eq(seen, ["child-a"])
  should_fail.val = false
  output.recover_new_threads(async fn(pending) -> Unit raise @error.AgentError {
    @async.pause()
    seen.push(pending.child_session_id)
    if pending.child_session_id == "child-a" {
      if pending.messages[0] != output_user("a") ||
        pending.metadata["k"] != Json::string("v") {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("callback snapshot was aliased"),
        )
      }
    }
  }) catch {
    error => fail(error.to_string())
  }
  assert_eq(seen, ["child-a", "child-a", "child-b"])
  output.recover_new_threads(async fn(
    _pending,
  ) -> Unit raise @error.AgentError {
    @async.pause()
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed(
        "confirmed outputs must not be retried",
      ),
    )
  }) catch {
    error => fail(error.to_string())
  }
}

///|
async test "session_output/body_callback_mutation_is_isolated_on_failure" {
  let output = SessionOutput::SessionOutput()
  output.stage_body("body-fail", {
    messages: [output_user("original")],
    metadata: Map::from_array([
      ("nested", Json::object(Map::from_array([("v", Json::string("clean"))]))),
    ]),
  })
  let should_fail = Ref(true)
  let attempt : Result[Unit, @error.AgentError] = Ok(
    output.recover_body("body-fail", async fn(
      session,
    ) -> Unit raise @error.AgentError {
      @async.pause()
      session.messages[0] = output_user("poison")
      match session.metadata["nested"] {
        Object(fields) => fields["v"] = Json::string("poison")
        _ => ()
      }
      if should_fail.val {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("offline"),
        )
      }
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(attempt is Err(_))
  should_fail.val = false
  output.recover_body("body-fail", async fn(
    session,
  ) -> Unit raise @error.AgentError {
    @async.pause()
    if session.messages[0] != output_user("original") {
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("body aliased"),
      )
    }
    match session.metadata["nested"] {
      Object(fields) =>
        if fields["v"] != Json::string("clean") {
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed("metadata aliased"),
          )
        }
      _ =>
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("metadata missing"),
        )
    }
  }) catch {
    error => fail(error.to_string())
  }
}

///|
async test "session_output/execute_new_thread_retries_only_after_success" {
  let output = SessionOutput::SessionOutput()
  let scope : @types.EventScope = {
    session_id: @kernel.SessionId::unchecked("p"),
    run_id: @kernel.RunId::unchecked("r"),
    turn_id: @kernel.TurnId::unchecked("t"),
  }
  output.stage_new_thread(
    scope,
    "p",
    "child",
    [output_user("original")],
    Map::from_array([("k", Json::string("v"))]),
    "label",
  )
  let should_fail = Ref(true)
  let attempt : Result[Unit, @error.AgentError] = Ok(
    output.execute_new_thread("child", async fn(
      pending,
    ) -> Unit raise @error.AgentError {
      @async.pause()
      pending.messages[0] = output_user("poison")
      pending.metadata["k"] = Json::string("poison")
      if should_fail.val {
        raise @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed("offline"),
        )
      }
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(attempt is Err(_))
  should_fail.val = false
  output.execute_new_thread("child", async fn(
    pending,
  ) -> Unit raise @error.AgentError {
    @async.pause()
    if pending.messages[0] != output_user("original") ||
      pending.metadata["k"] != Json::string("v") {
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("execute snapshot aliased"),
      )
    }
  }) catch {
    error => fail(error.to_string())
  }
  let retried = Ref(false)
  output.execute_new_thread("child", async fn(
    _pending,
  ) -> Unit raise @error.AgentError {
    @async.pause()
    if retried.val {
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("unexpected retry"),
      )
    }
    retried.val = true
  }) catch {
    error => fail(error.to_string())
  }
  assert_false(retried.val)
}
