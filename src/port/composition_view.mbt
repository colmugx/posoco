///|
/// CompositionView: the curated read-only view of composed capabilities
/// delivered to `Lifecycle::on_compose` after every composition gate has
/// passed. This is the consumption direction of the manifest contract — an
/// extension declares `requires` and the corresponding getter reads `Some`;
/// undeclared capabilities read `None`.
///
/// Curation discipline: the view only ever carries capabilities whose use
/// cannot bypass governance. `model` calls still carry `InvocationScope`
/// attribution; `ui` has no governance surface. The view NEVER exposes tool
/// invocation (would bypass `PipelineHook::before_tool`), session stores (state
/// ownership), or observer-event emission (core-owned). Fields are private
/// with getters so new capabilities can be added without breaking
/// extensions that destructure or construct views in tests.
pub struct CompositionView {
  priv model_ : &ModelPort?
  priv decision_ : &DecisionPort?
  priv ui_ : &UiPort?
  priv tasks_ : Tasks?
}

///|
/// The single composed ModelPort — present only when the extension declared
/// `Capability::Model` in its manifest's `requires`. This is the unique
/// outlet that passed the composition cardinality gate, source-agnostic
/// (the extension cannot tell a plain provider from a routing
/// meta-extension, and must not).
pub fn CompositionView::model(self : CompositionView) -> &ModelPort? {
  self.model_
}

///|
/// The single optional composed DecisionPort — visible only when the extension
/// declared `Capability::Decision`. Absence is legal: consumers that treat
/// decision support as an enhancement should keep their deterministic
/// fallback; consumers that require it may fail explicitly in `on_compose`.
pub fn CompositionView::decision(self : CompositionView) -> &DecisionPort? {
  self.decision_
}

///|
/// The composed UiPort (single contributor, `CompositeUiPort`, or
/// `NoopUiPort`) — present only when the extension declared
/// `Capability::Ui`. Human-interaction requests (`UiRequest::Confirm` /
/// `Select` / `Input`) go here; do not occupy the `ui` manifest slot just to
/// consume the composed UI.
pub fn CompositionView::ui(self : CompositionView) -> &UiPort? {
  self.ui_
}

///|
/// The Agent-owned structured task capability, present only when the
/// extension declares `Capability::Tasks`.
pub fn CompositionView::tasks(self : CompositionView) -> Tasks? {
  self.tasks_
}

///|
/// Gate a view on a manifest's declared `requires`: a declared capability is
/// populated from the composed ports, an undeclared one reads `None`.
/// Called by the composition after every gate has passed, so `model` and
/// `ui` are guaranteed to be the final composed values.
pub fn CompositionView::resolve(
  requires~ : Array[Capability],
  model~ : &ModelPort,
  decision? : &DecisionPort? = None,
  ui~ : &UiPort,
  tasks? : Tasks? = None,
) -> CompositionView {
  {
    model_: if requires.contains(Model) {
      Some(model)
    } else {
      None
    },
    decision_: if requires.contains(Decision) {
      decision
    } else {
      None
    },
    ui_: if requires.contains(Ui) {
      Some(ui)
    } else {
      None
    },
    tasks_: if requires.contains(Tasks) {
      tasks
    } else {
      None
    },
  }
}
