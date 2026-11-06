///|
/// Operation-owned lifetime of presentation resources, driven by the Agent's
/// admission/release lifecycle.

///|
/// Which capability a mutation arrived through.
priv enum UiCallContext {
  /// The composition-delivered capability: owns `OwnerBound` resources.
  Owner
  /// A capability captured from one admitted operation: owns `OperationBound`
  /// resources and only those.
  Operation(operation_id~ : String)
}

///|
/// Rejection shared by every mutation that arrives through an operation handle
/// whose operation is gone.
fn ui_operation_gone(operation_id : String) -> @port.UiResourceError {
  @port.UiResourceError::InvalidInput(
    reason="operation \{operation_id} is no longer admitted; an operation-bound UI capability never outlives its operation",
  )
}

///|
/// Open the operation's acceptance window; a second live window is refused.
pub fn UiRuntime::begin_operation(
  self : UiRuntime,
  operation_id : String,
) -> Result[Unit, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match self.current_operation {
    Some(current) =>
      return Err(
        ui_invalid(
          "operation \{current} is still live; the UI runtime holds at most one operation window (refused \{operation_id})",
        ),
      )
    None => ()
  }
  self.current_operation = Some(operation_id)
  Ok(())
}

///|
/// Close one operation and reclaim what it owned: the acceptance window closes
/// first, then resources are withdrawn in publish order. Idempotent.
pub fn UiRuntime::settle_operation(
  self : UiRuntime,
  operation_id : String,
) -> Unit {
  let current = match self.current_operation {
    Some(id) => id
    None => return
  }
  if current != operation_id {
    return
  }
  // The acceptance window closes first: no later publish can attach.
  self.current_operation = None
  let keys = match self.operation_keys.get(operation_id) {
    Some(keys) => keys.copy()
    None => []
  }
  self.operation_keys.remove(operation_id)
  for key in keys {
    let bound = match self.operation_bindings.get(key) {
      Some(bound) => bound == operation_id
      None => false
    }
    if !bound {
      continue
    }
    self.operation_bindings.remove(key)
    match self.live.get(key) {
      Some(snapshot) => {
        self.live.remove(key)
        self.push_change(
          @port.UiResourceChange::Withdrawn(
            owner=snapshot.resource.owner,
            key=snapshot.resource.key,
            revision=snapshot.revision,
          ),
        )
      }
      None => ()
    }
  }
}

///|
/// The currently admitted operation id, for diagnostics and tests.
pub fn UiRuntime::current_operation(self : UiRuntime) -> String? {
  self.current_operation
}

///|
/// Capture the live operation as a capability bound to it; without one the
/// caller is refused.
pub fn UiRuntime::operation_capability(
  self : UiRuntime,
  owner : String,
) -> Result[@port.UiResources, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let operation_id = match self.current_operation {
    Some(id) => id
    None =>
      return Err(
        ui_invalid(
          "no admitted operation: UiResources::operation is only valid inside an admitted operation",
        ),
      )
  }
  Ok(self.bind_operation_capability(owner, operation_id))
}

///|
/// Build the restricted capability for one already captured operation; every
/// callback re-checks that same id.
fn UiRuntime::bind_operation_capability(
  self : UiRuntime,
  owner : String,
  operation_id : String,
) -> @port.UiResources {
  @port.UiResources::from_callbacks(
    owner~,
    publish=fn(draft) {
      self.publish(owner, UiCallContext::Operation(operation_id~), draft)
    },
    replace=fn(draft, expected) {
      self.replace(
        owner,
        UiCallContext::Operation(operation_id~),
        draft,
        expected,
      )
    },
    remove=fn(resource) {
      self.remove(owner, UiCallContext::Operation(operation_id~), resource)
    },
    set_action_handler=fn(handler) {
      self.operation_action_handler(owner, operation_id, handler)
    },
    host_support=fn(resource) {
      self.operation_host_support(owner, operation_id, resource)
    },
    // Re-acquiring from a handle yields the same binding, never the current one.
    operation=fn() { self.acquire_operation_capability(owner, operation_id) },
  )
}

///|
/// Capability query through an operation-bound handle.
fn UiRuntime::operation_host_support(
  self : UiRuntime,
  owner : String,
  operation_id : String,
  resource : @port.UiResourceRef,
) -> Result[Array[@port.UiHostConnectionSupport], @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let context = UiCallContext::Operation(operation_id~)
  match self.check_call_context(context) {
    Some(error) => return Err(error)
    None => ()
  }
  if resource.owner != owner {
    return Err(ui_invalid("resource owner does not match this capability"))
  }
  if resource.key.contains("\u{0}") {
    return Err(ui_invalid("resource key must not contain NUL"))
  }
  let key = ui_resource_key(owner, resource.key)
  if !self.owns_live_resource(context, key) {
    return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  self.host_support(owner, resource)
}

///|
/// Re-acquire the capability for one captured operation; `Closed` outranks a
/// missing operation.
fn UiRuntime::acquire_operation_capability(
  self : UiRuntime,
  owner : String,
  operation_id : String,
) -> Result[@port.UiResources, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match self.check_call_context(UiCallContext::Operation(operation_id~)) {
    Some(error) => Err(error)
    None => Ok(self.bind_operation_capability(owner, operation_id))
  }
}

///|
/// Handler registration is owner-scoped; the handle is dead once its
/// operation settles.
fn UiRuntime::operation_action_handler(
  self : UiRuntime,
  owner : String,
  operation_id : String,
  handler : @port.UiActionHandler,
) -> Result[Unit, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match self.check_call_context(UiCallContext::Operation(operation_id~)) {
    Some(error) => Err(error)
    None => self.set_action_handler(owner, handler)
  }
}

///|
/// A captured handle is only usable while its own operation is the live one.
fn UiRuntime::check_call_context(
  self : UiRuntime,
  context : UiCallContext,
) -> @port.UiResourceError? {
  match context {
    Owner => None
    Operation(operation_id~) =>
      match self.current_operation {
        Some(current) if current == operation_id => None
        _ => Some(ui_operation_gone(operation_id))
      }
  }
}

///|
/// Whether the caller may take over an already live resource with the same
/// key; a resource never changes lifetime or operation.
fn UiRuntime::check_takeover(
  self : UiRuntime,
  context : UiCallContext,
  key : String,
  live : @port.UiResourceSnapshot,
) -> @port.UiResourceError? {
  match live.lifetime {
    OwnerBound =>
      match context {
        Owner => None
        Operation(operation_id~) =>
          Some(
            ui_invalid(
              "resource \{live.resource.key} is OwnerBound and cannot be taken over by operation \{operation_id}; use the composition-delivered capability",
            ),
          )
      }
    OperationBound =>
      match self.operation_bindings.get(key) {
        Some(bound) =>
          match context {
            Operation(operation_id~) if operation_id == bound => None
            _ =>
              Some(
                ui_invalid(
                  "resource \{live.resource.key} belongs to operation \{bound}; replace it through that operation's capability or remove it",
                ),
              )
          }
        None =>
          Some(
            ui_invalid(
              "resource \{live.resource.key} has no live operation binding",
            ),
          )
      }
    // Session-bound resources never become live; the lifetime is refused at
    // draft validation.
    SessionBound =>
      Some(
        @port.UiResourceError::Unsupported(
          feature="session-scoped lifetime cleanup",
        ),
      )
  }
}

///|
/// Record that the live resource at `key` belongs to the caller's operation.
/// Only an operation context binds; `OwnerBound` callers have no operation.
fn UiRuntime::bind_operation_resource(
  self : UiRuntime,
  context : UiCallContext,
  key : String,
) -> Unit {
  match context {
    Owner => ()
    Operation(operation_id~) => {
      self.operation_bindings[key] = operation_id
      let keys = match self.operation_keys.get(operation_id) {
        Some(keys) => keys
        None => {
          let fresh : Array[String] = []
          self.operation_keys[operation_id] = fresh
          fresh
        }
      }
      if !keys.contains(key) {
        keys.push(key)
      }
    }
  }
}

///|
/// Whether a withdrawal is addressable from this capability: the owner
/// capability may withdraw anything it published; an operation handle only its
/// own operation's resources.
fn UiRuntime::owns_live_resource(
  self : UiRuntime,
  context : UiCallContext,
  key : String,
) -> Bool {
  match context {
    Owner => true
    Operation(operation_id~) =>
      match self.operation_bindings.get(key) {
        Some(bound) => bound == operation_id
        None => false
      }
  }
}
