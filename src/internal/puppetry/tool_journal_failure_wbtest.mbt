///|
priv struct JournalChildHost {
  model : FixtureHost
  execute : async (EffectId, ToolName, @kernel_exec.ToolExecutionScope?) -> @kernel.ToolOutcome
  cancel : async (Array[EffectId]) -> Array[(EffectId, CancelDisposition)]
}

///|
impl @kernel_exec.HostRuntime for JournalChildHost with fn call_model(
  self,
  scope,
  messages,
  tools,
  options,
  chunks,
) {
  self.model.call_model(scope, messages, tools, options, chunks)
}

///|
impl @kernel_exec.HostRuntime for JournalChildHost with fn compact(
  self,
  scope,
  messages,
  tools,
  options,
  trigger,
) {
  self.model.compact(scope, messages, tools, options, trigger)
}

///|
impl @kernel_exec.HostRuntime for JournalChildHost with fn execute_tool(
  _self,
  _id,
  _owner,
  _call,
  _name,
  _arguments,
) {
  RuntimeFailure(
    error_category="MissingScope",
    message="journal fixture requires the real tool scope",
  )
}

///|
impl @kernel_exec.HostRuntime for JournalChildHost with fn execute_tool_scoped(
  self,
  id,
  _owner,
  _call,
  name,
  _arguments,
  scope,
) {
  (self.execute)(id, name, scope)
}

///|
impl @kernel_exec.HostRuntime for JournalChildHost with fn cancel_effects(
  self,
  ids,
  _reason,
) {
  (self.cancel)(ids)
}

///|
async test "tool_tree/journal_failure_at_each_child_boundary_ends_waiters_and_cleans_only_unsettled_work" {
  // Declaration, approval, start intent and completion are distinct durable
  // boundaries. Inject at each, never after a guessed wall-clock delay.
  for fail_on in [5, 6, 7, 8] {
    let replies : Array[@kernel.InvocationResult] = []
    let signal = @async.CondVar::Cond()
    let parent_exited = Ref(false)
    let child_calls = Ref(0)
    let cancel_ids : Array[EffectId] = []
    @async.with_timeout(3_000, async fn() {
      @async.with_task_group(group => {
        let host = JournalChildHost::{
          model: FixtureHost(
            [Ok(fixture_tool_calls([fixture_call("parent", "p")]))],
            Map::from_array([]),
          ),
          execute: async fn(_id, name, scope) {
            if name.to_string() == "child" {
              child_calls.val += 1
              return Success(content="child completed", structured=None)
            }
            defer {
              parent_exited.val = true
            }
            let scope = scope.unwrap()
            group.spawn_bg(() => {
              replies.push((scope.invoke)("child", {}))
              signal.broadcast()
            })
            let never = @async.CondVar::Cond()
            never.wait()
            Success(content="unreachable", structured=None)
          },
          cancel: ids => {
            assert_true(parent_exited.val)
            cancel_ids.append(ids)
            ids.map(id => (id, Stopped))
          },
        }
        let builder = ToolCatalogBuilder()
        for name in ["parent", "child"] {
          ignore(
            builder.add(
              @kernel.ToolDef(
                name=ToolName::unchecked(name),
                description=name,
                input_schema={},
                owner=OwnerId::unchecked(name),
                policy=Exclusive,
                provenance=None,
                exposure=if name == "child" { Deferred } else { Direct },
              ),
            ),
          )
        }
        let journal = FailOnNthJournal(InMemoryJournal(), fail_on)
        let config = canonical_puppet_config(
          host,
          builder.finish(version=CatalogVersion(1)),
          journal,
          [],
          [],
          None,
        )
        let puppet = Puppet({
          ..config,
          tool_call_owners: Map::from_array([("parent", ["child"])]),
          bound_tool_names: fn() { ["parent", "child"] },
        })
        match fixture_prompt(puppet, "journal_child_failure") {
          Rejected(error=SavepointFailed(cause=BarrierFailed(detail~), ..)) =>
            assert_true(
              detail.contains("injected failure on append #\{fail_on}"),
            )
          other => fail("lost primary journal failure: " + other.to_string())
        }
        while replies.is_empty() {
          signal.wait()
        }
        assert_true(parent_exited.val)
        assert_eq(cancel_ids.length(), 1)
        assert_eq(cancel_ids[0].to_int(), 2)
        assert_eq(child_calls.val, if fail_on == 8 { 1 } else { 0 })
        guard replies
          is [Interrupted(cancellation~, side_effects_possible~, ..)] else {
          fail("journal failure left a waiter or invented a committed result")
        }
        assert_eq(side_effects_possible, fail_on == 8)
        assert_eq(cancellation, AlreadySettled)
      })
    })
  }
}
