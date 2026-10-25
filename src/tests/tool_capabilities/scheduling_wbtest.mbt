///|
async test "tool_invoke/sequential_slot_includes_a_waiting_grandchild" {
  let grandchild_running = Ref(false)
  let second_admitted = Ref(false)
  let second_started = Ref(false)
  let release = Ref(false)
  let signal = @async.CondVar::Cond()
  let parent = InvocationFixture::{
    id: "parent",
    owners: ["child"],
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    action: async fn(ctx) {
      let results = @async.all([
        async fn() { ctx.invoke("first", {}) },
        async fn() { ctx.invoke("second", {}) },
      ])
      if results.all(result => result is Completed(Success(..))) {
        tk_ok_result("joined subtree")
      } else {
        RuntimeFailure(
          error_category="ChildFailed",
          message="children did not finish",
        )
      }
    },
  }
  let children = InvocationFixture::{
    id: "child",
    owners: ["grandchild"],
    definitions: ["first", "second"].map(name => {
      ..tk_tool_def(name, name),
      policy: Sequential,
      exposure: Deferred,
    }),
    action: async fn(ctx) {
      if ctx.name.to_string() == "first" {
        match ctx.invoke("grandchild", {}) {
          Completed(outcome) => outcome
          Interrupted(reason~, ..) =>
            RuntimeFailure(error_category="Interrupted", message=reason)
        }
      } else {
        second_started.val = true
        if grandchild_running.val {
          RuntimeFailure(
            error_category="SchedulingBroken",
            message="sibling overlapped the grandchild",
          )
        } else {
          tk_ok_result("second")
        }
      }
    },
  }
  let grandchild = InvocationFixture::{
    id: "grandchild",
    owners: [],
    definitions: [
      { ..tk_tool_def("grandchild", "grandchild"), exposure: Deferred, },
    ],
    action: async fn(_ctx) {
      grandchild_running.val = true
      signal.broadcast()
      while !release.val {
        signal.wait()
      }
      grandchild_running.val = false
      tk_ok_result("grandchild")
    },
  }
  let hook = InvocationHook::{
    decide: call => {
      if call.name.to_string() == "second" {
        second_admitted.val = true
        signal.broadcast()
      }
      Approve(call~)
    },
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), hooks=[hook]),
      parent,
      children,
      grandchild,
    ],
    config=@agent.agent_config(
      max_tool_rounds=tk_config().max_tool_rounds,
      max_tool_calls=Some(8),
      max_tool_depth=Some(4),
    ),
  )
  @async.with_timeout(2000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        agent.run_turn(tk_user_msg("hello"), "subtree-slot")
      })
      while !grandchild_running.val || !second_admitted.val {
        signal.wait()
      }
      assert_false(second_started.val)
      release.val = true
      signal.broadcast()
      let result = turn.wait()
      assert_eq(contribution_result_texts(result.tool_results), [
        "joined subtree",
      ])
      assert_true(second_started.val)
    })
  })
}

///|
async test "tool_invoke/sequential_siblings_keep_their_entire_execution_slot" {
  let running = Ref(0)
  let maximum = Ref(0)
  let order : Array[String] = []
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["child"],
    action: async fn(ctx) {
      let results = @async.all([
        async fn() { ctx.invoke("first", Json::null()) },
        async fn() { ctx.invoke("second", Json::null()) },
      ]) catch {
        error => raise @error.RuntimeError::InvocationFailed(error.to_string())
      }
      guard results is [Completed(Success(..)), Completed(Success(..))] else {
        return RuntimeFailure(
          error_category="UnexpectedChildren",
          message="expected both children",
        )
      }
      tk_ok_result("joined")
    },
  }
  let children = InvocationFixture::{
    id: "child",
    owners: [],
    definitions: ["first", "second"].map(name => {
      ..tk_tool_def(name, name),
      policy: Sequential,
      exposure: Deferred,
    }),
    action: async fn(ctx) {
      running.val += 1
      if running.val > maximum.val {
        maximum.val = running.val
      }
      order.push(ctx.name.to_string())
      @async.sleep(5)
      running.val -= 1
      tk_ok_result("child")
    },
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[tk_ext(id="model", model=Some(model)), parent, children],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "sequential-children")
  assert_eq(contribution_result_texts(result.tool_results), ["joined"])
  assert_eq(maximum.val, 1)
  assert_eq(order, ["first", "second"])
}

///|
async test "tool_invoke/parallel_siblings_can_overlap" {
  let entered = Ref(0)
  let gate = @async.CondVar::Cond()
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [{ ..tk_tool_def("parent", "parent"), policy: Exclusive, }],
    owners: ["child"],
    action: async fn(ctx) {
      let _ = @async.all([
        async fn() { ctx.invoke("child", Json::null()) },
        async fn() { ctx.invoke("child", Json::null()) },
      ]) catch {
        error => raise @error.RuntimeError::InvocationFailed(error.to_string())
      }
      tk_ok_result("joined")
    },
  }
  let children = InvocationFixture::{
    id: "child",
    owners: [],
    definitions: [
      { ..tk_tool_def("child", "child"), policy: Parallel, exposure: Deferred, },
    ],
    action: async fn(_ctx) {
      entered.val += 1
      gate.broadcast()
      while entered.val < 2 {
        gate.wait()
      }
      tk_ok_result("child")
    },
  }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("parent", "p", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[tk_ext(id="model", model=Some(model)), parent, children],
    config=tk_config(),
  )
  let result = @async.with_timeout(2000, async fn() {
    agent.run_turn(tk_user_msg("hello"), "parallel-children")
  })
  assert_eq(contribution_result_texts(result.tool_results), ["joined"])
  assert_eq(entered.val, 2)
}
