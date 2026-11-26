///|
using @bridge {type RuntimeHostShim}

///|
using @builtin {
  type CompositeUiPort,
  type NoopUiPort,
  type SystemPromptHook,
  type SystemPromptSection,
  type UiRenderHook,
}

///|
using @command {type BuiltinCommandPort, compose_agent_commands}

///|
pub(all) struct RuntimeConfig {
  max_tool_rounds : Int32?
  max_tool_calls : Int32?
  max_tool_depth : Int32?
  temperature : Double?
  max_output_tokens : Int32?
  model_context_window : Int32?
  compact_threshold : Double?
  system_prompt : String?
  memory_inbound_timeout_ms : Int32?
}

///|
fn RuntimeConfig::to_call_options_json(self : RuntimeConfig) -> Json {
  let fields : Map[String, Json] = Map::from_array([])
  match self.temperature {
    Some(t) => fields["temperature"] = Json::number(t)
    None => ()
  }
  match self.max_output_tokens {
    Some(n) => fields["max_output_tokens"] = Json::number(n.to_double())
    None => ()
  }
  Json::object(fields)
}

///|
pub struct AgentRuntime {
  priv puppet : @puppetry.Puppet
  priv model : &@port.ModelPort
  priv events : @event_runtime.EventRuntime
  priv hooks : Array[&@port.PipelineHook]
  priv memory : Array[(String, &@port.MemoryPort)]
  priv memory_inbound_attempted : Map[String, Bool]
  priv sessions : Array[&@port.SessionPort]
  priv lifecycle : Array[&@port.Lifecycle]
  priv commands : Array[&@port.CommandPort]
  priv builtin_command_port : BuiltinCommandPort
  priv control : ControlCore
  priv task_runtime : @task.TaskRuntime
  priv operations : @operation_guard.OperationGuard
  priv wakeup : @wakeup.WakeupRuntime
  priv ui_runtime : @ui.UiRuntime
  priv config : RuntimeConfig
  priv mut next_catalog_version : Int32
  priv tool_contributions : ToolContributionRegistry
  priv tool_revocations : @puppetry.ToolRevocationFacts
  priv binding_versions : Ref[Map[String, Int32]]
  priv versions : @directory.ToolVersionLeases
  priv tool_bindings : Ref[Map[String, &@port.ToolProvider]]
  priv tool_runtime : RuntimeHostShim
  priv mut next_run_seq : Int32
  priv mut shutdown_started : Bool
  priv mut shutdown_complete : Bool
  priv mut next_lifecycle_shutdown : Int32
  priv mut start_notified : Bool
  priv mut turn_active : Bool
  priv chunk_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?]
  priv mut chunk_dispatcher_generation : Int32
  priv progress : @session_state.SessionProgress
  priv core_facts : @core_facts.CoreFacts
  priv event_subscriber : @event_projection.EventProjection
  priv session_output : @session_output.SessionOutput
}

///|
fn validate_runtime_config(
  config : RuntimeConfig,
) -> Unit raise @error.CompositionError {
  match config.max_tool_rounds {
    Some(value) if value < 0 =>
      raise ManifestSchemaError(
        manifest_id="agent.config",
        detail="max_tool_rounds must be non-negative",
      )
    _ => ()
  }
  for
    (name, limit) in [
      ("max_tool_calls", config.max_tool_calls),
      ("max_tool_depth", config.max_tool_depth),
    ] {
    if limit is Some(value) && value < 0 {
      raise ManifestSchemaError(
        manifest_id="agent.config",
        detail=name + " must be non-negative",
      )
    }
  }
  match config.model_context_window {
    Some(value) if value <= 0 =>
      raise ManifestSchemaError(
        manifest_id="agent.config",
        detail="model_context_window must be positive",
      )
    _ => ()
  }
  match config.compact_threshold {
    Some(value) if value <= 0.0 || value > 1.0 =>
      raise ManifestSchemaError(
        manifest_id="agent.config",
        detail="compact_threshold must be in (0, 1]",
      )
    _ => ()
  }
  match config.memory_inbound_timeout_ms {
    Some(value) if value <= 0 =>
      raise ManifestSchemaError(
        manifest_id="agent.config",
        detail="memory_inbound_timeout_ms must be positive",
      )
    _ => ()
  }
}

///|
fn compose_tool_catalog(
  agg : AggregatedPorts,
) -> (@kernel_exec.ToolCatalogSnapshot, Array[ToolEntry]) raise @error.CompositionError {
  let entries = agg.tools.copy()
  if !agg.memory.is_empty() {
    let provider : &@port.ToolProvider = @memory.MemoryToolProvider(
      sources=agg.memory,
      on_failure=reason => {
        emit_secondary_failure(agg.events, "memory_search", reason)
      },
    )
    for definition in provider.list_tools() {
      entries.push(ToolEntry::bound(definition, "posoco.core", provider))
    }
  }
  ignore(@directory.entry_routing(entries))
  (
    build_catalog_from_defs(entries.map(e => e.definition), CatalogVersion(1)),
    entries,
  )
}

///|
fn compose_hook_chain(
  agg : AggregatedPorts,
  config : RuntimeConfig,
  ui_projection : Bool,
) -> Array[&@port.PipelineHook] {
  let composed_hooks : Array[&@port.PipelineHook] = []
  let base_prompt = match config.system_prompt {
    Some(p) => p
    None => ""
  }
  if base_prompt != "" || !agg.prompt_contributors.is_empty() {
    let sections : Array[SystemPromptSection] = []
    for pair in agg.prompt_contributors {
      let (mid, contributor) = pair
      sections.push(SystemPromptSection(id=mid, contributor~))
    }
    let sys_hook = SystemPromptHook(base_prompt~, contributors=sections)
    composed_hooks.push(sys_hook as &@port.PipelineHook)
  }
  for h in agg.hooks {
    composed_hooks.push(h)
  }
  if ui_projection {
    let ui_hook = UiRenderHook(ui=agg.ui)
    composed_hooks.push(ui_hook as &@port.PipelineHook)
  }
  composed_hooks
}

///|
fn create_agent_stream_callback(
  events : @event_runtime.EventRuntime,
  dispatcher_ref : Ref[@chunk_dispatch.ChunkDispatcher?],
) -> @kernel_exec.HostChunkCallback? {
  let cb = fn(chunk : @types.StreamChunk) {
    if !events.has_listeners() {
      return
    }
    match dispatcher_ref.val {
      Some(dispatcher) => dispatcher.enqueue(chunk)
      None => ()
    }
  }
  Some(cb)
}

///|
fn compose_mailbox_and_host(
  agg : AggregatedPorts,
  host_override : &@runtime.Runtime?,
  bindings : Ref[Map[String, &@port.ToolProvider]],
) -> (
  &@puppetry.Mailbox,
  BuiltinCommandPort,
  Array[&@port.CommandPort],
  &@kernel_exec.HostRuntime,
  RuntimeHostShim,
) {
  let mailbox_ref : &@puppetry.Mailbox = @puppetry.ControlMailbox()
  let builtin_command_port = BuiltinCommandPort(mailbox_ref)
  let command_ports = compose_agent_commands(agg.commands, builtin_command_port)
  let runtime : &@runtime.Runtime = host_override.unwrap_or(
    @runtime.PortRuntime(model=agg.model),
  )
  let shim = RuntimeHostShim(
    runtime,
    bindings,
    cancel_settle_ms=operation_cancel_settle_ms,
    on_cleanup_failure=reason => {
      emit_secondary_failure(agg.events, "tool_cleanup", reason)
    },
  )
  (mailbox_ref, builtin_command_port, command_ports, shim, shim)
}

///|
pub fn AgentRuntime::compose(
  exts~ : Array[&@port.Extension],
  config~ : RuntimeConfig,
  events~ : @event_runtime.EventRuntime,
  ui_projection~ : Bool = false,
  host_override~ : &@runtime.Runtime? = None,
) -> AgentRuntime raise @error.CompositionError {
  let agg = aggregate_extensions(exts, events~)
  validate_runtime_config(config)
  let (catalog, entries) = compose_tool_catalog(agg)
  let launch_gate = @kernel_exec.ToolLaunchGate::ToolLaunchGate()
  let tool_revocations = @puppetry.ToolRevocationFacts::ToolRevocationFacts()
  let binding_versions : Ref[Map[String, Int32]] = Ref(Map::from_array([]))
  let tool_contributions = ToolContributionRegistry::ToolContributionRegistry(
    entries,
    launcher=launch_gate,
    on_change=change => emit_tool_catalog_change(agg.events, change),
    on_revoke=fn(versions, _names) {
      let affected : Array[String] = []
      for name, version in binding_versions.val {
        if versions.contains(version) {
          affected.push(name)
        }
      }
      tool_revocations.add(affected)
    },
  )
  let static_tools = tool_contributions.captured_tools()
  let composed_hooks = compose_hook_chain(agg, config, ui_projection)
  let tool_bindings = Ref(static_tools.copy())
  let (mailbox_ref, builtin_command_port, command_ports, host, tool_runtime) = compose_mailbox_and_host(
    agg, host_override, tool_bindings,
  )
  let journal = @puppetry.InMemoryJournal()
  let chunk_dispatcher_ref : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let context_state_of : Ref[((String) -> @types.ContextState?)?] = Ref(None)
  let task_runtime = @task.TaskRuntime::TaskRuntime()
  task_runtime.set_ready_notifier(fn(outcome) {
    emit_custom_event(
      agg.events,
      None,
      "posoco.tasks",
      "background_outcome_ready",
      [
        ("task_id", Json::string(outcome.receipt.id)),
        ("session", Json::string(outcome.receipt.session_id)),
        ("extension_id", Json::string(outcome.receipt.extension_id)),
        ("label", Json::string(outcome.receipt.label)),
        (
          "status",
          Json::string(@task.task_outcome_status_label(outcome.status)),
        ),
      ],
    )
  })
  let wakeup = @wakeup.WakeupRuntime::WakeupRuntime(events=agg.events)
  let ui_runtime = @ui.UiRuntime::UiRuntime()
  errdefer ui_runtime.close()
  let operations = @operation_guard.OperationGuard::OperationGuard()
  let control = ControlCore(mailbox_ref)
  control.set_abort_hook(fn(run_id) {
    task_runtime.cancel_foreground_for_run(run_id)
  })
  control.install_message_events(agg.events)
  let progress = @session_state.SessionProgress::SessionProgress()
  let core_facts = @core_facts.CoreFacts::CoreFacts()
  let checkpoint_subscriber = @session_checkpoint.SessionCheckpointSubscriber::SessionCheckpointSubscriber(
    agg.sessions,
    progress,
  )
  let event_subscriber = @event_projection.EventProjection::EventProjection(
    agg.events,
    chunk_dispatcher_ref,
    context_state_of~,
    acknowledge_message=Some(fn(command_id) {
      control.inbox.acknowledge_step_delivery(command_id)
    }),
  )
  let puppet_config : @puppetry.PuppetConfig = {
    host,
    catalog,
    journal: journal as &@puppetry.RunJournal,
    contributors: [],
    subscribers: [
      checkpoint_subscriber as &@puppetry.EventSubscriber,
      event_subscriber as &@puppetry.EventSubscriber,
    ],
    stream_chunks: create_agent_stream_callback(
      agg.events,
      chunk_dispatcher_ref,
    ),
    hooks: composed_hooks,
    tool_call_owners: agg.tool_call_owners,
    max_tool_depth: config.max_tool_depth,
    max_iterations: match config.max_tool_rounds {
      Some(rounds) => Some(2 * rounds + 1)
      None => None
    },
    commands: command_ports,
    mailbox: mailbox_ref,
  }
  for entry in agg.lifecycle {
    let task_capability = task_runtime.capability(entry.id)
    let wakeup_capability = wakeup.capability(entry.id)
    let contribution_capability = tool_contributions.capability(entry.id)
    let view = @port.CompositionView::resolve(
      requires=entry.requires,
      model=agg.model,
      decision=agg.decision,
      log=agg.log,
      ui=agg.ui,
      ui_resources=Some(ui_runtime.capability(entry.id)),
      ui_interactions=Some(ui_runtime.interactions(entry.id)),
      tasks=Some(task_capability),
      wakeup=Some(wakeup_capability),
      tool_contributions=Some(contribution_capability),
      events=Some(agg.events.capability(entry.id)),
    )
    entry.port.on_compose(view)
  }
  let puppet = @puppetry.Puppet(puppet_config)
  puppet.install_tool_lifecycle(launch_gate, tool_revocations)
  puppet.set_source_observer(
    Some(fn(run_id, session_id, messages, prefix) {
      core_facts.capture_source(
        run_id.to_string(),
        session_id,
        messages,
        prefix,
      )
    }),
  )
  puppet.set_core_fact_observer(
    Some(fn(fact) {
      core_facts.record_boundary(
        fact.run_id.to_string(),
        fact.session_id,
        fact.committed_revision,
        fact.savepoint_id,
        fact.is_terminal,
        fact.messages,
        metadata_update=fact.metadata,
      )
    }),
  )
  let runtime : AgentRuntime = {
    puppet,
    model: agg.model,
    events: agg.events,
    hooks: composed_hooks,
    memory: agg.memory,
    memory_inbound_attempted: Map::from_array([]),
    sessions: agg.sessions,
    lifecycle: agg.lifecycle.map(fn(entry) { entry.port }),
    commands: agg.commands,
    builtin_command_port,
    control,
    task_runtime,
    operations,
    wakeup,
    ui_runtime,
    config,
    next_catalog_version: 2,
    tool_contributions,
    tool_revocations,
    binding_versions,
    versions: ToolVersionLeases(),
    tool_bindings,
    tool_runtime,
    next_run_seq: 1,
    shutdown_started: false,
    shutdown_complete: false,
    next_lifecycle_shutdown: agg.lifecycle.length() - 1,
    start_notified: false,
    turn_active: false,
    chunk_dispatcher: chunk_dispatcher_ref,
    chunk_dispatcher_generation: 0,
    progress,
    core_facts,
    event_subscriber,
    session_output: SessionOutput(),
  }
  builtin_command_port.idle_compact.val = Some(async fn(
    session_id,
  ) -> Result[@types.CompactOutcome, @error.AgentError] {
    Ok(runtime.compact_session(session_id)) catch {
      error => Err(error)
    }
  })
  builtin_command_port.idle_fork.val = Some(async fn(
    session_id,
    new_session_id,
    at_message_index,
  ) -> Result[@types.ForkOutcome, @error.AgentError] {
    Ok(runtime.fork_session(session_id, new_session_id~, at_message_index~)) catch {
      error => Err(error)
    }
  })
  context_state_of.val = Some(fn(session_id) {
    runtime.puppet.session_context_state(session_id)
  })
  runtime
}

///|
pub async fn[X] AgentRuntime::run_scoped_with(
  self : AgentRuntime,
  body : async () -> X,
) -> X {
  if !self.task_runtime.scope_available() {
    raise @error.AgentError::Runtime(
      InvocationFailed("task scope is already active or the Agent is closed"),
    )
  }
  let body_outcome : Ref[X?] = Ref(None)
  @async.with_task_group(async fn(group) {
    let owns_scope = Ref(false)
    errdefer (if owns_scope.val {
      ignore(
        Ok(@async.protect_from_cancel(async fn() { self.shutdown() })) catch {
          error => {
            emit_secondary_failure(
              self.events,
              "run_scoped_shutdown",
              error.to_string(),
            )
            Err(error)
          }
        },
      )
    })
    let startup : Result[Unit, Error] = Ok(
      {
        self.task_runtime.activate(group)
        owns_scope.val = true
        self.wakeup.activate()
        self.notify_start_if_first()
        self.wakeup.start_pump(group, self)
      },
    ) catch {
      error => Err(error)
    }
    let body_result : Result[X, Error] = match startup {
      Err(error) => Err(error)
      Ok(_) => Ok(body()) catch { error => Err(error) }
    }
    let shutdown_result : Result[Unit, Error] = if owns_scope.val {
      Ok(@async.protect_from_cancel(async fn() { self.shutdown() })) catch {
        error => Err(error)
      }
    } else {
      Ok(())
    }
    match body_result {
      Ok(value) =>
        match shutdown_result {
          Ok(_) => body_outcome.val = Some(value)
          Err(error) => raise error
        }
      Err(error) =>
        match shutdown_result {
          Ok(_) => raise error
          Err(cleanup_error) => {
            emit_secondary_failure(
              self.events,
              "run_scoped_shutdown",
              cleanup_error.to_string(),
            )
            raise error
          }
        }
    }
  })
  match body_outcome.val {
    Some(value) => value
    None =>
      raise @error.AgentError::Runtime(
        InvocationFailed("run_scoped: no body outcome"),
      )
  }
}

///|
pub async fn AgentRuntime::shutdown(self : AgentRuntime) -> Unit {
  if self.shutdown_complete {
    return
  }
  self.shutdown_started = true
  errdefer self.ui_runtime.close()
  self.tool_contributions.close()
  self.wakeup.begin_shutdown()
  self.settle_operation_for_shutdown()
  self.tool_runtime.cleanup_unconfirmed()

  let task_shutdown : Result[Unit, @error.AgentError] = Ok(
    self.task_runtime.shutdown(),
  ) catch {
    error => Err(error)
  }
  match task_shutdown {
    Ok(_) => ()
    Err(error) => {
      self.wakeup.drop_pending()
      @task.emit_managed_task_shutdown_failure(
        self.events,
        error.to_string(),
        self.task_runtime.shutdown_straggler_detail(),
      )
      raise error
    }
  }
  self.wakeup.drop_pending()
  self.puppet.shutdown() catch {
    error =>
      raise @error.AgentError::Runtime(
        InvocationFailed(
          "puppet shutdown: " + @diagnostic.safe_error_label(error.to_string()),
        ),
      )
  }
  while self.next_lifecycle_shutdown >= 0 {
    self.lifecycle[self.next_lifecycle_shutdown].on_shutdown()
    self.next_lifecycle_shutdown = self.next_lifecycle_shutdown - 1
  }
  self.ui_runtime.close()
  self.release_retained_versions()
  self.tool_contributions.begin_retire_all()
  ignore(self.tool_contributions.retire_unreferenced())
  let cleanup = self.tool_contributions.pending_cleanup()
  if !cleanup.is_empty() {
    raise @error.AgentError::Runtime(
      InvocationFailed(
        "tool version cleanup pending: \{cleanup.length()} version(s): " +
        @diagnostic.safe_error_label(cleanup[0].detail),
      ),
    )
  }
  self.events.close()
  self.shutdown_complete = true
}

///|
fn agent_error_category(error : Error) -> String {
  match error {
    @error.AgentError::Model(_) => "AgentError::Model"
    @error.AgentError::Session(_) => "AgentError::Session"
    @error.AgentError::Runtime(_) => "AgentError::Runtime"
    @error.AgentError::ToolLoopExceeded(..) => "AgentError::ToolLoopExceeded"
    @error.AgentError::Busy(..) => "AgentError::Busy"
    @error.AgentError::PipelineAborted(_) => "AgentError::PipelineAborted"
    @error.AgentError::Cancelled(_) => "AgentError::Cancelled"
    @error.AgentError::AutoCompactFailed(_) => "AgentError::AutoCompactFailed"
    _ => "Unclassified"
  }
}

///|
fn AgentRuntime::emit_turn_event(
  self : AgentRuntime,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  self.events.emit_core(scope, event)
}

///|
async fn AgentRuntime::dispatch_on_turn_begin(
  self : AgentRuntime,
) -> Unit noraise {
  for hook in self.hooks {
    hook.on_turn_begin() catch {
      error =>
        emit_secondary_failure(self.events, "on_turn_begin", error.to_string())
    }
  }
}

///|
async fn AgentRuntime::dispatch_on_turn_end(
  self : AgentRuntime,
) -> Unit noraise {
  for hook in self.hooks {
    hook.on_turn_end() catch {
      error =>
        emit_secondary_failure(self.events, "on_turn_end", error.to_string())
    }
  }
}

///|
fn AgentRuntime::drain_core_facts_errors(self : AgentRuntime) -> Unit {
  for detail in self.core_facts.take_errors() {
    emit_secondary_failure(self.events, "core_shadow_boundary", detail)
  }
}

///|
fn emit_secondary_failure(
  events : @event_runtime.EventRuntime,
  hook_point : String,
  detail : String,
) -> Unit {
  let event : @types.TurnEvent = Custom(
    source="posoco.core",
    label="secondary_failure",
    data=Json::object(
      Map::from_array([
        ("hook_point", Json::string(hook_point)),
        ("error", Json::string(@diagnostic.safe_error_label(detail))),
      ]),
    ),
  )
  events.emit_core(None, event)
}

///|
fn AgentRuntime::ensure_agent_running(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if self.shutdown_started {
    raise Runtime(InvocationFailed("agent is shut down"))
  }
}

///|
let follow_up_drain_limit : Int32 = 64

///|
pub async fn AgentRuntime::run_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  self.run_turn_with_mode(input, session_id, false)
}

///|
pub async fn AgentRuntime::resume_turn(
  self : AgentRuntime,
  session_id : String,
  continuation~ : String = "continue",
) -> @types.TurnResult raise @error.AgentError {
  self.run_turn_with_mode(
    UserMessage(content=[Text(continuation)]),
    session_id,
    true,
    origin=Resume,
  )
}

///|
async fn AgentRuntime::run_turn_with_mode(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  resume_persisted_user : Bool,
  origin~ : OperationOrigin = Turn,
  operation_label~ : String? = None,
  on_admitted~ : ((OperationAdmission) -> Unit)? = None,
) -> @types.TurnResult raise @error.AgentError {
  let admission = self.admit_operation(session_id, origin, operation_label~)
  match on_admitted {
    Some(hook) => hook(admission)
    None => ()
  }
  errdefer (if self.operations.current_id() == Some(admission.operation_id) {
    self.retire_released_versions()
    self.release_operation(admission, Cancelled)
  })
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    self.execute_operation(admission, async fn() -> Result[
      @types.TurnResult,
      @error.AgentError,
    ] {
      let typed : Result[@types.TurnResult, @error.AgentError] = Ok(
        {
          let mut result = self.run_single_turn(
            input, session_id, resume_persisted_user, admission,
          )
          let mut drained = 0
          while drained < follow_up_drain_limit {
            match self.control.select_follow_up() {
              Some(command) => {
                drained = drained + 1
                let follow_up = self.mint_turn_identity(session_id)
                self.control.arm_follow_up(
                  command.command_id,
                  follow_up.run_id,
                  follow_up.turn_id,
                )
                result = self.run_single_turn(
                  command.message,
                  session_id,
                  false,
                  admission_for_follow_up(admission, follow_up),
                )
              }
              None => break
            }
          }
          result
        },
      ) catch {
        error => Err(error)
      }
      typed
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = match result {
    Ok(_) => Completed
    Err(error) => agent_error_operation_outcome(error)
  }
  self.retire_released_versions()
  self.release_operation(admission, outcome)
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
fn admission_for_follow_up(
  parent : OperationAdmission,
  identity : TurnIdentity,
) -> OperationAdmission {
  {
    operation_id: parent.operation_id,
    origin: Turn,
    identity,
    session_id: identity.session_id.to_string(),
  }
}

///|
async fn AgentRuntime::notify_start_if_first(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if self.start_notified {
    return
  }
  for lc in self.lifecycle {
    lc.on_start() catch {
      error =>
        raise Runtime(
          InvocationFailed(
            "lifecycle on_start: " +
            @diagnostic.safe_error_label(error.to_string()),
          ),
        )
    }
  }
  self.start_notified = true
}

///|
priv struct TurnTerminal {
  mut started : Bool
  mut settled : Bool
}

///|
fn AgentRuntime::settle_turn_terminal(
  self : AgentRuntime,
  identity : TurnIdentity,
  terminal : TurnTerminal,
  event : @types.TurnEvent,
) -> Unit {
  if terminal.settled {
    return
  }
  terminal.settled = true
  self.emit_turn_event(Some(identity.scope()), event)
}

///|
fn AgentRuntime::abandon_pending_calls(
  self : AgentRuntime,
  identity : TurnIdentity,
  reason : String,
) -> Unit {
  self.event_subscriber.drain_pending(Some(identity.scope()), reason)
}

///|
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_single_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  resume_persisted_user : Bool,
  admission : OperationAdmission,
) -> @types.TurnResult raise @error.AgentError {
  self.ensure_agent_running()
  self.notify_start_if_first()
  let identity = admission.identity
  defer self.core_facts.finish_run(
    session_id,
    identity.run_id.to_string(),
    "turn_ended_without_terminal",
  )
  defer self.drain_core_facts_errors()
  self.task_runtime.begin_operation(
    session_id,
    identity.run_id,
    identity.turn_id,
  )
  self.control.bind_turn(identity.run_id, identity.turn_id)
  defer self.settle_turn_messages(identity)
  let terminal = TurnTerminal::{ started: false, settled: false, }
  errdefer (if terminal.started && !terminal.settled {
    self.abandon_pending_calls(identity, "turn cancelled")
    self.settle_turn_terminal(identity, terminal, TurnCancelled)
  })
  terminal.started = true
  self.emit_turn_event(Some(identity.scope()), TurnStarted)
  self.dispatch_on_turn_begin()

  let result = self.run_turn_via_puppet(
    input,
    session_id,
    identity,
    resume_persisted_user,
    admission.operation_id,
  ) catch {
    primary => {
      let cleanup : Result[Unit, @error.AgentError] = Ok(
        self.task_runtime.finish_active_operation(),
      ) catch {
        error => Err(error)
      }
      match cleanup {
        Ok(_) => ()
        Err(error) =>
          emit_secondary_failure(
            self.events,
            "foreground_task_cleanup",
            error.to_string(),
          )
      }
      let cancelled = primary is Cancelled(_)
      let reason = if cancelled { "turn cancelled" } else { "turn failed" }
      self.abandon_pending_calls(identity, reason)
      let event : @types.TurnEvent = if cancelled {
        TurnCancelled
      } else {
        TurnFailed("turn failed: " + agent_error_category(primary))
      }
      self.settle_turn_terminal(identity, terminal, event)
      self.dispatch_on_turn_end()
      raise primary
    }
  }

  let cleanup : Result[Unit, @error.AgentError] = Ok(
    self.task_runtime.finish_active_operation(),
  ) catch {
    error => Err(error)
  }
  match cleanup {
    Ok(_) => {
      self.settle_turn_terminal(identity, terminal, TurnCompleted)
      self.dispatch_on_turn_end()
      result
    }
    Err(error) => {
      self.abandon_pending_calls(identity, "turn failed")
      self.settle_turn_terminal(
        identity,
        terminal,
        TurnFailed("turn failed: AgentError::Runtime"),
      )
      self.dispatch_on_turn_end()
      raise error
    }
  }
}

///|
pub async fn AgentRuntime::context_state(
  self : AgentRuntime,
  session_id : String,
) -> @types.ContextState? {
  match self.puppet.session_context_state(session_id) {
    Some(state) => Some(state)
    None => {
      let loaded_result : Result[@types.Session, @error.AgentError] = Ok(
        self.load_session_for_operation(session_id),
      ) catch {
        error => Err(error)
      }
      let loaded : @types.Session? = match loaded_result {
        Ok(session) => Some(session)
        Err(_) => None
      }
      match loaded {
        Some(session) => @types.ContextState::from_metadata(session.metadata)
        None => None
      }
    }
  }
}

///|
pub fn AgentRuntime::set_active_session(
  self : AgentRuntime,
  session_id : String?,
) -> Unit {
  self.wakeup.set_active_session(session_id)
}

///|
pub fn AgentRuntime::ui_host(self : AgentRuntime) -> @port.UiHost {
  self.ui_runtime.host()
}

///|
pub fn AgentRuntime::control(self : AgentRuntime) -> ControlCore {
  self.control
}

///|
pub fn AgentRuntime::subscribe_events(
  self : AgentRuntime,
  handler : (@events.EventEnvelope) -> Unit,
  namespace_~ : @events.EventNamespace? = None,
) -> Result[@events.Subscription, @events.EventError] {
  self.events.subscribe(handler, namespace_~)
}

///|
pub fn AgentRuntime::commands(self : AgentRuntime) -> Array[&@port.CommandPort] {
  compose_agent_commands(self.commands, self.builtin_command_port)
}
