///|
/// Host connection registry: capability declarations, matching and the
/// per-connection answer/dismiss routes.

///|
fn ui_copy_host_capabilities(
  capabilities : @port.UiHostCapabilities,
) -> @port.UiHostCapabilities {
  {
    resource_kinds: capabilities.resource_kinds.copy(),
    fallback: capabilities.fallback,
    interactions: capabilities.interactions.copy(),
  }
}

///|
fn ui_validate_host_capabilities(
  capabilities : @port.UiHostCapabilities,
) -> @port.UiInteractionError? {
  if capabilities.resource_kinds.length() > ui_max_host_capability_entries {
    return Some(
      @port.UiInteractionError::InvalidInput(
        reason="host capability resource kinds exceed \{ui_max_host_capability_entries} entries",
      ),
    )
  }
  if capabilities.interactions.length() > ui_max_host_capability_entries {
    return Some(
      @port.UiInteractionError::InvalidInput(
        reason="host capability interactions exceed \{ui_max_host_capability_entries} entries",
      ),
    )
  }
  for kind in capabilities.resource_kinds {
    if kind.namespace_ == "" || kind.name == "" {
      return Some(
        @port.UiInteractionError::InvalidInput(
          reason="host capability resource kinds need a namespace and a name",
        ),
      )
    }
    if kind.namespace_.contains("\u{0}") || kind.name.contains("\u{0}") {
      return Some(
        @port.UiInteractionError::InvalidInput(
          reason="host capability resource kinds must not contain NUL",
        ),
      )
    }
    if kind.schema_version < 1 {
      return Some(
        @port.UiInteractionError::InvalidInput(
          reason="host capability resource kind schema_version must be positive",
        ),
      )
    }
  }
  for index in 0..<capabilities.resource_kinds.length() {
    for other in (index + 1)..<capabilities.resource_kinds.length() {
      let kind = capabilities.resource_kinds[index]
      if kind == capabilities.resource_kinds[other] {
        return Some(
          @port.UiInteractionError::InvalidInput(
            reason="duplicate host capability resource kind \{kind.namespace_}/\{kind.name}@\{kind.schema_version}",
          ),
        )
      }
    }
  }
  for index in 0..<capabilities.interactions.length() {
    for other in (index + 1)..<capabilities.interactions.length() {
      let kind = capabilities.interactions[index]
      if kind == capabilities.interactions[other] {
        return Some(
          @port.UiInteractionError::InvalidInput(
            reason="duplicate host capability interaction kind \{ui_interaction_kind_label(kind)}",
          ),
        )
      }
    }
  }
  None
}

///|
fn ui_interaction_kind_label(kind : @port.UiInteractionKind) -> String {
  match kind {
    TextInput => "TextInput"
    YesNo => "YesNo"
    SingleChoice => "SingleChoice"
  }
}

///|
fn ui_capabilities_support_interaction(
  capabilities : @port.UiHostCapabilities,
  kind : @port.UiInteractionKind,
) -> Bool {
  for declared in capabilities.interactions {
    if declared == kind {
      return true
    }
  }
  false
}

///|
fn ui_host_support_for_kind(
  kind : @port.UiResourceKind,
  capabilities : @port.UiHostCapabilities,
) -> @port.UiHostSupport {
  for declared in capabilities.resource_kinds {
    if declared == kind {
      return Native
    }
  }
  if capabilities.fallback {
    Fallback
  } else {
    Unsupported
  }
}

///|
fn ui_host_unavailable(reason : String) -> @port.UiInteractionError {
  @port.UiInteractionError::HostUnavailable(reason~)
}

///|
fn UiRuntime::host_connection_connected(self : UiRuntime, id : Int32) -> Bool {
  if self.closed {
    return false
  }
  self.host_connections.contains(id)
}

///|
fn UiRuntime::bump_host_epoch(self : UiRuntime) -> Unit {
  self.host_epoch = self.host_epoch + 1
  self.interaction_wake.broadcast()
}

///|
fn UiRuntime::forget_host_connection(self : UiRuntime, id : Int32) -> Unit {
  self.host_connections.remove(id)
  let mut index = 0
  while index < self.host_connection_order.length() {
    if self.host_connection_order[index] == id {
      ignore(self.host_connection_order.remove(index))
    } else {
      index = index + 1
    }
  }
}

///|
/// Attach one host lease. The capability lists are copied before they are
/// stored, and the returned handle is the only way to update, detach, answer or
/// dismiss through this lease.
fn UiRuntime::connect_host(
  self : UiRuntime,
  capabilities : @port.UiHostCapabilities,
) -> Result[@port.UiHostConnection, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  match ui_validate_host_capabilities(capabilities) {
    Some(error) => return Err(error)
    None => ()
  }
  if self.host_connection_order.length() >= ui_max_host_connections {
    return Err(
      @port.UiInteractionError::ConnectionsFull(limit=ui_max_host_connections),
    )
  }
  let id = self.next_host_connection
  self.next_host_connection = id + 1
  self.host_connections[id] = {
    capabilities: ui_copy_host_capabilities(capabilities),
  }
  self.host_connection_order.push(id)
  self.bump_host_epoch()
  Ok(
    @port.UiHostConnection::from_callbacks(
      id~,
      is_connected=fn() { self.host_connection_connected(id) },
      update=fn(capabilities) { self.update_host_connection(id, capabilities) },
      detach=fn() { self.detach_host_connection(id) },
      answer=fn(request) { self.connection_answer(id, request) },
      dismiss=fn(interaction, reason) {
        self.connection_dismiss(id, interaction, reason)
      },
    ),
  )
}

///|
/// Replace the declarations of a live lease; the registry epoch moves so
/// every waiter re-checks.
fn UiRuntime::update_host_connection(
  self : UiRuntime,
  id : Int32,
  capabilities : @port.UiHostCapabilities,
) -> Result[Unit, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  let record = match self.host_connections.get(id) {
    Some(record) => record
    None => return Err(ui_host_unavailable("host connection is detached"))
  }
  match ui_validate_host_capabilities(capabilities) {
    Some(error) => return Err(error)
    None => ()
  }
  record.capabilities = ui_copy_host_capabilities(capabilities)
  self.bump_host_epoch()
  Ok(())
}

///|
/// Release a lease. Idempotent, and never closes the Agent or another host.
fn UiRuntime::detach_host_connection(
  self : UiRuntime,
  id : Int32,
) -> Result[Unit, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  match self.host_connections.get(id) {
    Some(_) => {
      self.forget_host_connection(id)
      self.bump_host_epoch()
    }
    None => ()
  }
  Ok(())
}

///|
/// True while at least one connected host declares the question's body kind.
fn UiRuntime::interaction_supported(
  self : UiRuntime,
  body : @port.UiInteractionBody,
) -> Bool {
  let kind = body.kind()
  for id in self.host_connection_order {
    match self.host_connections.get(id) {
      Some(record) =>
        if ui_capabilities_support_interaction(record.capabilities, kind) {
          return true
        }
      None => ()
    }
  }
  false
}

///|
/// Resolve one online lease and require it to declare the question's body kind,
/// so a connection cannot answer a prompt it never said it could display.
fn UiRuntime::connection_for_interaction(
  self : UiRuntime,
  id : Int32,
  interaction : @port.UiInteractionRef,
) -> Result[UiHostConnectionRecord, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  let record = match self.host_connections.get(id) {
    Some(record) => record
    None => return Err(ui_host_unavailable("host connection is detached"))
  }
  let question = match self.interaction_record(interaction) {
    Ok(question) => question
    Err(error) => return Err(error)
  }
  let kind = question.snapshot.body.kind()
  if !ui_capabilities_support_interaction(record.capabilities, kind) {
    return Err(
      ui_host_unavailable(
        "this host connection does not declare \{ui_interaction_kind_label(kind)} support",
      ),
    )
  }
  Ok(record)
}

///|
fn UiRuntime::connection_answer(
  self : UiRuntime,
  id : Int32,
  request : @port.UiInteractionAnswerRequest,
) -> Result[@port.UiInteractionAnswerReceipt, @port.UiInteractionError] {
  match self.connection_for_interaction(id, request.interaction) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.answer_interaction(request)
}

///|
fn UiRuntime::connection_dismiss(
  self : UiRuntime,
  id : Int32,
  interaction : @port.UiInteractionRef,
  reason : String,
) -> Result[@port.UiInteractionOutcome, @port.UiInteractionError] {
  match self.connection_for_interaction(id, interaction) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.dismiss_interaction(interaction, reason)
}

///|
/// Per-connection display support for one live resource, in attach order; an
/// empty result means no host is connected.
fn UiRuntime::host_support(
  self : UiRuntime,
  owner : String,
  resource : @port.UiResourceRef,
) -> Result[Array[@port.UiHostConnectionSupport], @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match ui_validate_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  if resource.owner != owner {
    return Err(ui_invalid("resource owner does not match this capability"))
  }
  if resource.key.contains("\u{0}") {
    return Err(ui_invalid("resource key must not contain NUL"))
  }
  if resource.generation != self.generation {
    return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  let live = match self.live.get(ui_resource_key(owner, resource.key)) {
    Some(snapshot) => snapshot
    None =>
      return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  let reports : Array[@port.UiHostConnectionSupport] = []
  for id in self.host_connection_order {
    match self.host_connections.get(id) {
      Some(record) =>
        reports.push({
          connection: id,
          support: ui_host_support_for_kind(live.kind, record.capabilities),
        })
      None => ()
    }
  }
  Ok(reports)
}
