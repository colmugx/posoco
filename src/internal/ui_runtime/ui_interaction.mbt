///|
/// Interaction half of the UI runtime: the pending table, the bounded retained
/// window of settled questions, and the interaction feed.

///|
fn ui_interaction_key(owner : String, request_id : String) -> String {
  owner + "\u{0}" + request_id
}

///|
fn ui_interaction_invalid(reason : String) -> @port.UiInteractionError {
  @port.UiInteractionError::InvalidInput(reason~)
}

///|
fn ui_copy_interaction_body(
  body : @port.UiInteractionBody,
) -> @port.UiInteractionBody {
  match body {
    FreeText(default~) => FreeText(default~)
    Confirmation => Confirmation
    Choice(options~, default~) => Choice(options=options.copy(), default~)
  }
}

///|
fn ui_copy_interaction_snapshot(
  snapshot : @port.UiInteractionSnapshot,
) -> @port.UiInteractionSnapshot {
  {
    interaction: snapshot.interaction,
    scope: snapshot.scope,
    prompt: snapshot.prompt,
    body: ui_copy_interaction_body(snapshot.body),
    title: snapshot.title,
  }
}

///|
fn ui_copy_interaction_change(
  change : @port.UiInteractionChange,
) -> @port.UiInteractionChange {
  match change {
    Opened(snapshot~) => Opened(snapshot=ui_copy_interaction_snapshot(snapshot))
    Settled(owner~, request_id~, outcome~) =>
      Settled(owner~, request_id~, outcome~)
  }
}

///|
/// Owner ids are the first half of the internal key; an empty or
/// separator-carrying owner could alias another owner's questions.
fn ui_validate_interaction_owner(owner : String) -> @port.UiInteractionError? {
  if owner == "" {
    return Some(ui_interaction_invalid("interaction owner must not be empty"))
  }
  if owner.contains("\u{0}") {
    return Some(
      ui_interaction_invalid("interaction owner must not contain NUL"),
    )
  }
  None
}

///|
fn ui_validate_interaction_request(
  request : @port.UiInteractionRequest,
) -> @port.UiInteractionError? {
  if request.request_id == "" {
    return Some(
      ui_interaction_invalid("interaction request_id must not be empty"),
    )
  }
  if request.request_id.length() > ui_key_max_length {
    return Some(
      ui_interaction_invalid(
        "interaction request_id exceeds \{ui_key_max_length} characters",
      ),
    )
  }
  if request.request_id.contains("\u{0}") {
    return Some(
      ui_interaction_invalid("interaction request_id must not contain NUL"),
    )
  }
  if request.prompt == "" {
    return Some(ui_interaction_invalid("interaction prompt must not be empty"))
  }
  match request.scope {
    SessionScope(id~) | OperationScope(id~) | ToolCallScope(id~) =>
      if id == "" {
        return Some(
          ui_interaction_invalid("interaction scope id must not be empty"),
        )
      }
    AgentScope => ()
  }
  match request.body {
    Choice(options~, default~) => {
      if options.length() == 0 {
        return Some(
          ui_interaction_invalid("a Choice body needs at least one option"),
        )
      }
      match default {
        Some(index) =>
          if index < 0 || index >= options.length() {
            return Some(
              ui_interaction_invalid(
                "the default choice \{index} is outside the option range",
              ),
            )
          }
        None => ()
      }
    }
    _ => ()
  }
  None
}

///|
/// An answer must fit the body the owner declared; anything else leaves the
/// question pending so the host can answer again.
fn ui_validate_interaction_answer(
  body : @port.UiInteractionBody,
  answer : @port.UiInteractionAnswer,
) -> @port.UiInteractionError? {
  match (body, answer) {
    (FreeText(_), Text(_)) => None
    (Confirmation, Yes) | (Confirmation, No) => None
    (Choice(options~, ..), Choice(index)) =>
      if index >= 0 && index < options.length() {
        None
      } else {
        Some(
          @port.UiInteractionError::InvalidAnswer(
            reason="choice \{index} is outside the option range",
          ),
        )
      }
    (FreeText(_), _) =>
      Some(
        @port.UiInteractionError::InvalidAnswer(
          reason="this question accepts free text only",
        ),
      )
    (Confirmation, _) =>
      Some(
        @port.UiInteractionError::InvalidAnswer(
          reason="this question accepts Yes or No only",
        ),
      )
    (Choice(..), _) =>
      Some(
        @port.UiInteractionError::InvalidAnswer(
          reason="this question accepts a choice index only",
        ),
      )
  }
}

///|
/// Map a terminal outcome to what a waiter returns.
fn ui_interaction_outcome_result(
  outcome : @port.UiInteractionOutcome,
) -> Result[@port.UiInteractionAnswer, @port.UiInteractionError] {
  match outcome {
    Answered(answer~) => Ok(answer)
    Dismissed(reason~) => Err(@port.UiInteractionError::Dismissed(reason~))
    Withdrawn => Err(@port.UiInteractionError::Withdrawn)
    WaitCancelled => Err(@port.UiInteractionError::AlreadySettled(outcome~))
    Closed => Err(@port.UiInteractionError::Closed)
  }
}

///|
/// Build the owner-bound interaction capability for one manifest id.
pub fn UiRuntime::interactions(
  self : UiRuntime,
  owner : String,
) -> @port.UiInteractions {
  @port.UiInteractions::from_callbacks(
    owner~,
    open=fn(request) { self.open_interaction(owner, request) },
    find=fn(request_id) { self.find_interaction(owner, request_id) },
    wait=async fn(interaction) noraise {
      self.wait_interaction(owner, interaction)
    },
    withdraw=fn(interaction) { self.withdraw_interaction(owner, interaction) },
    ask=async fn(request) noraise { self.ask_interaction(owner, request) },
  )
}

///|
/// Everything that must be true before a question may be created; split from
/// creation so `ask` can run it synchronously.
fn UiRuntime::check_open_interaction(
  self : UiRuntime,
  owner : String,
  request : @port.UiInteractionRequest,
) -> Result[Unit, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  match ui_validate_interaction_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  match ui_validate_interaction_request(request) {
    Some(error) => return Err(error)
    None => ()
  }
  let key = ui_interaction_key(owner, request.request_id)
  if self.interactions.contains(key) {
    return Err(
      @port.UiInteractionError::Duplicate(request_id=request.request_id),
    )
  }
  if self.pending_order.length() >= ui_max_pending_interactions {
    return Err(
      @port.UiInteractionError::PendingFull(limit=ui_max_pending_interactions),
    )
  }
  Ok(())
}

///|
/// Create the pending record and announce it. The caller has already passed
/// `check_open_interaction`, so this cannot fail.
fn UiRuntime::create_interaction(
  self : UiRuntime,
  owner : String,
  request : @port.UiInteractionRequest,
) -> @port.UiInteractionSnapshot {
  let key = ui_interaction_key(owner, request.request_id)
  let snapshot : @port.UiInteractionSnapshot = {
    interaction: {
      owner,
      request_id: request.request_id,
      generation: self.generation,
    },
    scope: request.scope,
    prompt: request.prompt,
    body: ui_copy_interaction_body(request.body),
    title: request.title,
  }
  self.interactions[key] = { snapshot, outcome: None, waiters: 0, }
  self.pending_order.push(key)
  self.interaction_order.push(key)
  self.push_interaction_change(
    @port.UiInteractionChange::Opened(
      snapshot=ui_copy_interaction_snapshot(snapshot),
    ),
  )
  ui_copy_interaction_snapshot(snapshot)
}

///|
/// Open one question. Opening is allowed without a connected host; it never
/// starts waiting by itself.
fn UiRuntime::open_interaction(
  self : UiRuntime,
  owner : String,
  request : @port.UiInteractionRequest,
) -> Result[@port.UiInteractionSnapshot, @port.UiInteractionError] {
  match self.check_open_interaction(owner, request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(self.create_interaction(owner, request))
}

///|
/// Atomic one-shot question: validation, host matching and creation happen in
/// one synchronous admission step.
async fn UiRuntime::ask_interaction(
  self : UiRuntime,
  owner : String,
  request : @port.UiInteractionRequest,
) -> Result[@port.UiInteractionAnswer, @port.UiInteractionError] noraise {
  match self.check_open_interaction(owner, request) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !self.interaction_supported(request.body) {
    return Err(
      ui_host_unavailable(
        "no connected host declares \{ui_interaction_kind_label(request.body.kind())} support",
      ),
    )
  }
  let snapshot = self.create_interaction(owner, request)
  self.wait_interaction(owner, snapshot.interaction)
}

///|
/// Owner-bound lookup by local request id. Reads a copy, never settles or
/// waits; unknown or evicted ids are `NotFound`; a retained settled question is
/// still found.
fn UiRuntime::find_interaction(
  self : UiRuntime,
  owner : String,
  request_id : String,
) -> Result[@port.UiInteractionSnapshot, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  match ui_validate_interaction_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  if request_id.contains("\u{0}") {
    return Err(
      ui_interaction_invalid("interaction request_id must not contain NUL"),
    )
  }
  match self.interactions.get(ui_interaction_key(owner, request_id)) {
    Some(record) => Ok(ui_copy_interaction_snapshot(record.snapshot))
    None => Err(@port.UiInteractionError::NotFound(owner~, request_id~))
  }
}

///|
/// Resolve a ref to its record, rejecting foreign generations and malformed
/// owners before any state is touched.
fn UiRuntime::interaction_record(
  self : UiRuntime,
  interaction : @port.UiInteractionRef,
) -> Result[UiInteractionRecord, @port.UiInteractionError] {
  match ui_validate_interaction_owner(interaction.owner) {
    Some(error) => return Err(error)
    None => ()
  }
  if interaction.request_id.contains("\u{0}") {
    return Err(
      ui_interaction_invalid("interaction request_id must not contain NUL"),
    )
  }
  if interaction.generation != self.generation {
    return Err(
      @port.UiInteractionError::NotFound(
        owner=interaction.owner,
        request_id=interaction.request_id,
      ),
    )
  }
  let key = ui_interaction_key(interaction.owner, interaction.request_id)
  match self.interactions.get(key) {
    Some(record) => Ok(record)
    None =>
      Err(
        @port.UiInteractionError::NotFound(
          owner=interaction.owner,
          request_id=interaction.request_id,
        ),
      )
  }
}

///|
fn UiRuntime::push_interaction_change(
  self : UiRuntime,
  change : @port.UiInteractionChange,
) -> Unit {
  self.interaction_seq = self.interaction_seq + 1
  self.interaction_changes.push(change)
  while self.interaction_changes.length() > ui_change_window {
    ignore(self.interaction_changes.remove(0))
    self.interaction_base_seq = self.interaction_base_seq + 1
  }
  self.notify({
    cursor: { generation: self.generation, seq: self.interaction_seq, },
    change: @port.UiChange::Interaction(
      change=ui_copy_interaction_change(change),
    ),
  })
}

///|
/// Settle one question exactly once and wake every waiter in the same
/// synchronous step.
fn UiRuntime::settle_interaction(
  self : UiRuntime,
  key : String,
  record : UiInteractionRecord,
  outcome : @port.UiInteractionOutcome,
) -> Unit {
  if record.outcome is Some(_) {
    return
  }
  record.outcome = Some(outcome)
  let mut index = 0
  while index < self.pending_order.length() {
    if self.pending_order[index] == key {
      ignore(self.pending_order.remove(index))
    } else {
      index = index + 1
    }
  }
  self.push_interaction_change(
    @port.UiInteractionChange::Settled(
      owner=record.snapshot.interaction.owner,
      request_id=record.snapshot.interaction.request_id,
      outcome~,
    ),
  )
  self.interaction_wake.broadcast()
  self.evict_interactions()
}

///|
/// Trim the retained window oldest-first, never dropping a pending question.
fn UiRuntime::evict_interactions(self : UiRuntime) -> Unit {
  let mut index = 0
  while self.interaction_order.length() > ui_interaction_window &&
        index < self.interaction_order.length() {
    let key = self.interaction_order[index]
    let evictable = match self.interactions.get(key) {
      Some(record) => record.outcome is Some(_)
      None => true
    }
    if evictable {
      ignore(self.interaction_order.remove(index))
      self.interactions.remove(key)
    } else {
      index = index + 1
    }
  }
}

///|
/// Answer one pending question from the host; validation happens before any
/// state change.
fn UiRuntime::answer_interaction(
  self : UiRuntime,
  request : @port.UiInteractionAnswerRequest,
) -> Result[@port.UiInteractionAnswerReceipt, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  let record = match self.interaction_record(request.interaction) {
    Ok(record) => record
    Err(error) => return Err(error)
  }
  let key = ui_interaction_key(
    request.interaction.owner,
    request.interaction.request_id,
  )
  match record.outcome {
    Some(Answered(answer~)) =>
      if answer == request.answer {
        // A duplicate replays the receipt instead of settling twice.
        return Ok({ interaction: request.interaction, answer, replayed: true, })
      } else {
        return Err(
          @port.UiInteractionError::Conflict(
            reason="interaction \{request.interaction.request_id} was already answered with a different value",
          ),
        )
      }
    Some(outcome) =>
      return Err(@port.UiInteractionError::AlreadySettled(outcome~))
    None => ()
  }
  match ui_validate_interaction_answer(record.snapshot.body, request.answer) {
    Some(error) => return Err(error)
    None => ()
  }
  self.settle_interaction(
    key,
    record,
    @port.UiInteractionOutcome::Answered(answer=request.answer),
  )
  Ok({
    interaction: request.interaction,
    answer: request.answer,
    replayed: false,
  })
}

///|
/// Dismiss one pending question: the user closed the prompt without choosing.
fn UiRuntime::dismiss_interaction(
  self : UiRuntime,
  interaction : @port.UiInteractionRef,
  reason : String,
) -> Result[@port.UiInteractionOutcome, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  let record = match self.interaction_record(interaction) {
    Ok(record) => record
    Err(error) => return Err(error)
  }
  let key = ui_interaction_key(interaction.owner, interaction.request_id)
  match record.outcome {
    Some(outcome) => Err(@port.UiInteractionError::AlreadySettled(outcome~))
    None => {
      let outcome : @port.UiInteractionOutcome = Dismissed(reason~)
      self.settle_interaction(key, record, outcome)
      Ok(outcome)
    }
  }
}

///|
/// Owner-initiated withdrawal of its own pending question.
fn UiRuntime::withdraw_interaction(
  self : UiRuntime,
  owner : String,
  interaction : @port.UiInteractionRef,
) -> Result[@port.UiInteractionOutcome, @port.UiInteractionError] {
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  if interaction.owner != owner {
    return Err(
      ui_interaction_invalid("interaction owner does not match this capability"),
    )
  }
  let record = match self.interaction_record(interaction) {
    Ok(record) => record
    Err(error) => return Err(error)
  }
  let key = ui_interaction_key(interaction.owner, interaction.request_id)
  match record.outcome {
    Some(outcome) => Err(@port.UiInteractionError::AlreadySettled(outcome~))
    None => {
      self.settle_interaction(
        key,
        record,
        @port.UiInteractionOutcome::Withdrawn,
      )
      Ok(@port.UiInteractionOutcome::Withdrawn)
    }
  }
}

///|
/// Wait for one question to settle. `defer` releases the waiter on every exit;
/// losing the last waiter to cancellation settles the question as
/// `WaitCancelled`. Without a host declaring the body kind the call returns
/// `HostUnavailable` and leaves the question pending; only the owning
/// capability may wait; an already settled question reports its outcome.
async fn UiRuntime::wait_interaction(
  self : UiRuntime,
  owner : String,
  interaction : @port.UiInteractionRef,
) -> Result[@port.UiInteractionAnswer, @port.UiInteractionError] noraise {
  if interaction.owner != owner {
    return Err(
      ui_interaction_invalid("interaction owner does not match this capability"),
    )
  }
  let record = match self.interaction_record(interaction) {
    Ok(record) => record
    Err(error) =>
      if self.closed {
        return Err(@port.UiInteractionError::Closed)
      } else {
        return Err(error)
      }
  }
  match record.outcome {
    Some(outcome) => return ui_interaction_outcome_result(outcome)
    None => ()
  }
  if self.closed {
    return Err(@port.UiInteractionError::Closed)
  }
  if !self.interaction_supported(record.snapshot.body) {
    return Err(
      ui_host_unavailable(
        "no connected host declares \{ui_interaction_kind_label(record.snapshot.body.kind())} support",
      ),
    )
  }
  let key = ui_interaction_key(interaction.owner, interaction.request_id)
  record.waiters = record.waiters + 1
  // Normal exits mark the wait complete; cancellation unwinds without setting
  // it, so the cleanup only abandons a cancelled wait.
  let mut completed = false
  let mut epoch = self.host_epoch
  defer self.release_waiter(key, record, completed)
  for ;; {
    match record.outcome {
      Some(outcome) => {
        completed = true
        return ui_interaction_outcome_result(outcome)
      }
      None =>
        if self.closed {
          completed = true
          return Err(@port.UiInteractionError::Closed)
        } else if self.host_epoch != epoch {
          epoch = self.host_epoch
          if !self.interaction_supported(record.snapshot.body) {
            completed = true
            return Err(
              ui_host_unavailable(
                "the last connected host able to answer this question detached or dropped the capability",
              ),
            )
          }
        } else {
          self.interaction_wake.wait()
        }
    }
  }
}

///|
/// Release one waiter; abandon the question only when the last waiter ended by
/// cancellation and no outcome was recorded.
fn UiRuntime::release_waiter(
  self : UiRuntime,
  key : String,
  record : UiInteractionRecord,
  completed : Bool,
) -> Unit {
  if record.waiters > 0 {
    record.waiters = record.waiters - 1
  }
  if !completed && record.waiters == 0 && record.outcome is None {
    self.settle_interaction(
      key,
      record,
      @port.UiInteractionOutcome::WaitCancelled,
    )
  }
}

///|
fn UiRuntime::interactions_since(
  self : UiRuntime,
  cursor : @port.UiCursor,
) -> Result[@port.UiInteractionChanges, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let cursor_error = ui_check_cursor(
    cursor,
    self.generation,
    self.interaction_seq,
    self.interaction_base_seq,
    "interaction",
  )
  match cursor_error {
    Some(error) => return Err(error)
    None => ()
  }
  let changes : Array[@port.UiInteractionChange] = []
  let from = cursor.seq - self.interaction_base_seq
  for index in from..<self.interaction_changes.length() {
    changes.push(ui_copy_interaction_change(self.interaction_changes[index]))
  }
  Ok({
    cursor: { generation: self.generation, seq: self.interaction_seq, },
    changes,
  })
}

///|
/// Pending questions in open order, as copies the reader may keep or mutate.
fn UiRuntime::pending_snapshots(
  self : UiRuntime,
) -> Array[@port.UiInteractionSnapshot] {
  let snapshots : Array[@port.UiInteractionSnapshot] = []
  for key in self.pending_order {
    match self.interactions.get(key) {
      Some(record) =>
        if record.outcome is None {
          snapshots.push(ui_copy_interaction_snapshot(record.snapshot))
        }
      None => ()
    }
  }
  snapshots
}

///|
/// Close-path settlement: every pending question ends as `Closed` and its
/// waiters are released; feed writes are skipped.
fn UiRuntime::settle_all_interactions_closed(self : UiRuntime) -> Unit {
  for key in self.pending_order {
    match self.interactions.get(key) {
      Some(record) =>
        if record.outcome is None {
          record.outcome = Some(@port.UiInteractionOutcome::Closed)
        }
      None => ()
    }
  }
  self.pending_order.clear()
  self.interaction_wake.broadcast()
}
