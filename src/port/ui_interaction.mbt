///|
/// Owner-bound structured interactions. A resource is state the host renders;
/// an interaction is a question the host has to answer.

///|
/// Address of one interaction: owner-local id plus the runtime generation that
/// issued it. A ref from a previous generation is never accepted.
#derive(Eq, Debug)
pub(all) struct UiInteractionRef {
  owner : String
  request_id : String
  generation : Int32
}

///|
pub extend UiInteractionRef with Eq::{not_equal, equal}

///|
pub extend UiInteractionRef with Debug::{to_repr}

///|
/// What the user is allowed to answer.
#derive(Eq, Debug)
pub(all) enum UiInteractionBody {
  /// Free-form text, with an optional pre-fill.
  FreeText(default~ : String?)
  /// Yes/no confirmation.
  Confirmation
  /// Choose one option; `default` is the pre-selected index.
  Choice(options~ : Array[String], default~ : Int32?)
}

///|
pub extend UiInteractionBody with Eq::{not_equal, equal}

///|
pub extend UiInteractionBody with Debug::{to_repr}

///|
/// Coarse body category a connected host can answer. A host declares these in
/// `UiHostCapabilities`; an empty list means it can answer nothing.
#derive(Eq, Debug)
pub(all) enum UiInteractionKind {
  /// `FreeText` prompts.
  TextInput
  /// `Confirmation` prompts.
  YesNo
  /// `Choice` prompts.
  SingleChoice
}

///|
pub extend UiInteractionKind with Eq::{not_equal, equal}

///|
pub extend UiInteractionKind with Debug::{to_repr}

///|
/// The capability category of a body.
pub fn UiInteractionBody::kind(self : UiInteractionBody) -> UiInteractionKind {
  match self {
    FreeText(_) => TextInput
    Confirmation => YesNo
    Choice(..) => SingleChoice
  }
}

///|
/// The value the host answered with.
#derive(Eq, Debug)
pub(all) enum UiInteractionAnswer {
  Text(String)
  Yes
  No
  Choice(Int32)
}

///|
pub extend UiInteractionAnswer with Eq::{not_equal, equal}

///|
pub extend UiInteractionAnswer with Debug::{to_repr}

///|
pub extend UiInteractionAnswer with Show::{to_string, output}

///|
pub impl Show for UiInteractionAnswer with fn to_string(self) -> String {
  match self {
    Text(text) => "UiInteractionAnswer::Text(\"" + text + "\")"
    Yes => "UiInteractionAnswer::Yes"
    No => "UiInteractionAnswer::No"
    Choice(index) => "UiInteractionAnswer::Choice(" + index.to_string() + ")"
  }
}

///|
/// Owner-supplied request to open one question.
#derive(Eq, Debug)
pub(all) struct UiInteractionRequest {
  /// Owner-local id; reusing a live or retained id is `Duplicate`.
  request_id : String
  /// Where the question belongs.
  scope : UiResourceScope
  prompt : String
  body : UiInteractionBody
  title : String?
}

///|
pub extend UiInteractionRequest with Eq::{not_equal, equal}

///|
pub extend UiInteractionRequest with Debug::{to_repr}

///|
/// Construct a request with `AgentScope`, no title and no pre-fill.
pub fn UiInteractionRequest::new(
  request_id~ : String,
  prompt~ : String,
  body~ : UiInteractionBody,
  scope~ : UiResourceScope = AgentScope,
  title? : String,
) -> UiInteractionRequest {
  { request_id, scope, prompt, body, title, }
}

///|
/// One pending question as the host reads it.
#derive(Eq, Debug)
pub(all) struct UiInteractionSnapshot {
  interaction : UiInteractionRef
  scope : UiResourceScope
  prompt : String
  body : UiInteractionBody
  title : String?
}

///|
pub extend UiInteractionSnapshot with Eq::{not_equal, equal}

///|
pub extend UiInteractionSnapshot with Debug::{to_repr}

///|
/// Terminal state of one interaction. Every terminal path is named; none of
/// them is a silent removal from the pending set.
#derive(Eq, Debug)
pub(all) enum UiInteractionOutcome {
  /// A host answer settled the question.
  Answered(answer~ : UiInteractionAnswer)
  /// The user closed the prompt without choosing. `reason` is host-supplied
  /// and may be empty.
  Dismissed(reason~ : String)
  /// The owner withdrew its own pending question.
  Withdrawn
  /// The last waiting task was cancelled.
  WaitCancelled
  /// The Agent shut down (or a failed composition revoked the protocol) while
  /// the question was pending.
  Closed
}

///|
pub extend UiInteractionOutcome with Eq::{not_equal, equal}

///|
pub extend UiInteractionOutcome with Debug::{to_repr}

///|
pub extend UiInteractionOutcome with Show::{to_string, output}

///|
pub impl Show for UiInteractionOutcome with fn to_string(self) -> String {
  match self {
    Answered(answer~) =>
      "UiInteractionOutcome::Answered(" + answer.to_string() + ")"
    Dismissed(reason~) => "UiInteractionOutcome::Dismissed(\{reason})"
    Withdrawn => "UiInteractionOutcome::Withdrawn"
    WaitCancelled => "UiInteractionOutcome::WaitCancelled"
    Closed => "UiInteractionOutcome::Closed"
  }
}

///|
/// One lifecycle change of the interaction feed.
#derive(Eq, Debug)
pub(all) enum UiInteractionChange {
  /// The question became pending.
  Opened(snapshot~ : UiInteractionSnapshot)
  /// The question settled. `outcome` says how; the snapshot is no longer
  /// pending.
  Settled(
    owner~ : String,
    request_id~ : String,
    outcome~ : UiInteractionOutcome
  )
}

///|
pub extend UiInteractionChange with Eq::{not_equal, equal}

///|
pub extend UiInteractionChange with Debug::{to_repr}

///|
/// Explicit failures of the interaction protocol.
#derive(Eq, Debug)
pub(all) enum UiInteractionError {
  /// The Agent shut down, or composition failed after this capability was
  /// delivered; capabilities are closed and pending questions are settled as
  /// `UiInteractionOutcome::Closed`.
  Closed
  /// No live or retained interaction for this owner/id at this generation.
  NotFound(owner~ : String, request_id~ : String)
  /// The owner already used this request id; the old question is live or still
  /// retained in the settled window.
  Duplicate(request_id~ : String)
  /// Structurally invalid request (empty id/prompt, bad body, forged owner).
  InvalidInput(reason~ : String)
  /// The answer does not fit the body the owner declared. The question stays
  /// pending, so the host can answer again.
  InvalidAnswer(reason~ : String)
  /// The question already ended another way; answering now changes nothing.
  AlreadySettled(outcome~ : UiInteractionOutcome)
  /// A repeated answer carries a different value than the accepted one.
  Conflict(reason~ : String)
  /// Too many pending questions; the request is refused, never dropped.
  PendingFull(limit~ : Int32)
  /// No connected host can handle this interaction. An explicit `open` stays
  /// pending for a later host; an `ask` that never created one consumed
  /// nothing.
  HostUnavailable(reason~ : String)
  /// The runtime already holds the maximum number of connected hosts.
  ConnectionsFull(limit~ : Int32)
  /// The user dismissed the prompt before an answer arrived.
  Dismissed(reason~ : String)
  /// The owner withdrew the question before an answer arrived.
  Withdrawn
}

///|
pub extend UiInteractionError with Eq::{not_equal, equal}

///|
pub extend UiInteractionError with Debug::{to_repr}

///|
pub extend UiInteractionError with Show::{to_string, output}

///|
pub impl Show for UiInteractionError with fn to_string(self) -> String {
  match self {
    Closed => "UiInteractionError::Closed"
    NotFound(owner~, request_id~) =>
      "UiInteractionError::NotFound(owner=\{owner}, request_id=\{request_id})"
    Duplicate(request_id~) => "UiInteractionError::Duplicate(\{request_id})"
    InvalidInput(reason~) => "UiInteractionError::InvalidInput(\{reason})"
    InvalidAnswer(reason~) => "UiInteractionError::InvalidAnswer(\{reason})"
    AlreadySettled(outcome~) =>
      "UiInteractionError::AlreadySettled(" + outcome.to_string() + ")"
    Conflict(reason~) => "UiInteractionError::Conflict(\{reason})"
    PendingFull(limit~) => "UiInteractionError::PendingFull(\{limit})"
    HostUnavailable(reason~) => "UiInteractionError::HostUnavailable(\{reason})"
    ConnectionsFull(limit~) => "UiInteractionError::ConnectionsFull(\{limit})"
    Dismissed(reason~) => "UiInteractionError::Dismissed(\{reason})"
    Withdrawn => "UiInteractionError::Withdrawn"
  }
}

///|
/// Host-side intent to answer one pending question.
#derive(Eq, Debug)
pub(all) struct UiInteractionAnswerRequest {
  interaction : UiInteractionRef
  answer : UiInteractionAnswer
}

///|
pub extend UiInteractionAnswerRequest with Eq::{not_equal, equal}

///|
pub extend UiInteractionAnswerRequest with Debug::{to_repr}

///|
/// Receipt of an accepted answer.
#derive(Eq, Debug)
pub(all) struct UiInteractionAnswerReceipt {
  interaction : UiInteractionRef
  answer : UiInteractionAnswer
  /// True when this question was already answered with the same value; the
  /// stored receipt is returned instead of settling a second time.
  replayed : Bool
}

///|
pub extend UiInteractionAnswerReceipt with Eq::{not_equal, equal}

///|
pub extend UiInteractionAnswerReceipt with Debug::{to_repr}

///|
/// Owner-bound interaction capability delivered through
/// `CompositionView::ui_interactions`.
pub struct UiInteractions {
  priv owner_ : String
  priv open_ : (UiInteractionRequest) -> Result[
    UiInteractionSnapshot,
    UiInteractionError,
  ]
  priv find_ : (String) -> Result[UiInteractionSnapshot, UiInteractionError]
  priv ask_ : (async (UiInteractionRequest) -> Result[
    UiInteractionAnswer,
    UiInteractionError,
  ] noraise)?
  priv wait_ : async (UiInteractionRef) -> Result[
    UiInteractionAnswer,
    UiInteractionError,
  ] noraise
  priv withdraw_ : (UiInteractionRef) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ]
}

///|
/// The manifest id this capability is bound to.
pub fn UiInteractions::owner(self : UiInteractions) -> String {
  self.owner_
}

///|
/// Open one question and return its pending snapshot. Opening twice with the
/// same request id is `Duplicate`; open a new id instead of retrying silently.
pub fn UiInteractions::open(
  self : UiInteractions,
  request~ : UiInteractionRequest,
) -> Result[UiInteractionSnapshot, UiInteractionError] {
  (self.open_)(request)
}

///|
/// Find one of this owner's questions by its local `request_id`, whether it is
/// still pending or retained in the settled window. Unknown or evicted ids are
/// `NotFound`; a closed runtime is `Closed`.
pub fn UiInteractions::find(
  self : UiInteractions,
  request_id~ : String,
) -> Result[UiInteractionSnapshot, UiInteractionError] {
  (self.find_)(request_id)
}

///|
/// Wait for the terminal outcome of an already open question. Cancelling this
/// call settles the question as `WaitCancelled` instead of answering it `No`.
/// Without a connected host declaring the body kind the call returns
/// `HostUnavailable` immediately and leaves the question pending; a waiter
/// joining after the question settled still reads its terminal outcome.
pub async fn UiInteractions::wait(
  self : UiInteractions,
  interaction~ : UiInteractionRef,
) -> Result[UiInteractionAnswer, UiInteractionError] noraise {
  (self.wait_)(interaction)
}

///|
/// Open and wait in one call. When no connected host declares the body kind,
/// returns `HostUnavailable` without creating a pending question or consuming
/// the request id.
pub async fn UiInteractions::ask(
  self : UiInteractions,
  request~ : UiInteractionRequest,
) -> Result[UiInteractionAnswer, UiInteractionError] noraise {
  match self.ask_ {
    Some(callback) => callback(request)
    None =>
      Err(
        UiInteractionError::HostUnavailable(
          reason="this UiInteractions adapter does not negotiate host capabilities",
        ),
      )
  }
}

///|
/// Withdraw one pending question. Returns `Withdrawn` on success; the host sees
/// the same outcome on the feed and any waiting task resumes with `Withdrawn`.
pub fn UiInteractions::withdraw(
  self : UiInteractions,
  interaction~ : UiInteractionRef,
) -> Result[UiInteractionOutcome, UiInteractionError] {
  (self.withdraw_)(interaction)
}

///|
/// Framework construction hook. Omitting `ask` or `find` makes the
/// corresponding calls report `HostUnavailable`.
pub fn UiInteractions::from_callbacks(
  owner~ : String,
  open~ : (UiInteractionRequest) -> Result[
    UiInteractionSnapshot,
    UiInteractionError,
  ],
  wait~ : async (UiInteractionRef) -> Result[
    UiInteractionAnswer,
    UiInteractionError,
  ] noraise,
  withdraw~ : (UiInteractionRef) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ],
  find? : (String) -> Result[UiInteractionSnapshot, UiInteractionError],
  ask? : async (UiInteractionRequest) -> Result[
    UiInteractionAnswer,
    UiInteractionError,
  ] noraise,
) -> UiInteractions {
  let find_callback = match find {
    Some(callback) => callback
    None =>
      fn(_request_id) {
        Err(
          UiInteractionError::HostUnavailable(
            reason="this UiInteractions adapter does not expose owner-bound lookup",
          ),
        )
      }
  }
  {
    owner_: owner,
    open_: open,
    find_: find_callback,
    ask_: ask,
    wait_: wait,
    withdraw_: withdraw,
  }
}
