# Changelog

## 0.12.0

### Breaking: streaming protocol and ModelPort message borrowing

`@posoco.StreamMode::Stream((StreamChunk) -> Unit)` now receives the canonical
`@posoco.StreamChunk` type directly; the old `(Json) -> Unit` callback contract
is removed. `HostChunkCallback` is typed likewise. This eliminates the
same-process JSON encode/parse/allocate cycle that ran for every chunk with zero
wire benefit.

`ModelPort::chat` and `ModelPort::compact` now receive
`messages : ArrayView[@kernel.Message]` (a borrow valid only for the duration of
the call; adapters must not retain it). The same change applies to the internal
`HostRuntime::call_model`/`compact` correspondence and to the public advanced
`Runtime` seam. Adapters that need to keep the messages beyond the call should
use `.to_owned()`; adapters that only read once can iterate the view in place.

`StreamAccumulator` internals switched to `StringBuilder`; the `text`,
`reasoning`, and `ToolCallBuilder.arguments_json` fields are now private. Use
the getters `acc.text()`, `acc.reasoning()`, and `tc.arguments_json()`.

A new `@posoco.TurnEvent` variant `StreamChunksDropped(count~ : Int)` is emitted
when the chunk telemetry queue overflows under backpressure. It is non-terminal
and telemetry-only, but exhaustive matches over `TurnEvent` must add the new
arm. See `docs/migrations/2026-08-stream-protocol.md` for the full migration
guide.

### Performance: streaming, reducer, hook, and memory retrieval

Headline numbers, measured on native release on the same machine before and
after this release (full table and methodology:
`docs/perf/2026-08-25-ultraspeed-baseline.md`):

- **StreamAccumulator StringBuilder rewrite — ~500x on accumulation hot
  paths.** 100k × 4-char streamed text deltas: ~498 ms → ~1 ms; tool-call
  argument accumulation at the same volume: ~488 ms → ~1 ms. Both paths were
  quadratic in accumulated length; they are now amortized O(1).
- **Bounded chunk telemetry — ~6x wall time and ~50x observer-event volume
  under chunk floods.** A 50k-chunk streaming turn went from ~6 ms / 50,003
  observer events to ~1 ms / 1,028 events. Per-turn capacity 1024 with
  drop-oldest and a drain task that flushes chunks before committed/terminal
  events; slow observers no longer throttle the provider read loop. Under
  overload the telemetry stream is intentionally lossy (signalled via
  `StreamChunksDropped`).
- **Reducer commits tool results once per wave** — one O(N) transcript
  commit per wave in source order, instead of K O(K·N) rebuilds per wave.
  Journal boundary semantics and the BASELINE counters (2/4/7) are unchanged.
- **`before_model` hook fast path** — the chain skips the O(N) array
  comparison when a hook returned the physically same array
  (physical-equal short-circuit).
- **`MemoryRetrievalHook::search_all` now queries memory ports concurrently**
  via `@async.all`; results are merged in registration order and per-port
  failures are reported through `on_failure`.
- **Session persistence scales with bytes appended, not history size** —
  pure-append turns save through `SessionStore::append_messages` (below)
  instead of a full load + save of the whole transcript.

### Added: `SessionStore::append_messages` and selective append saves

`SessionStore` gains `append_messages(id, from_index, messages :
ArrayView[@kernel.Message])` with a default load-concat-save fallback. The Agent
now calls `append_messages` when a turn was a pure append (a per-session
persisted cursor tracks the boundary), and falls back to a full `save` after
compact/fork/rewrite. Multi-store writes are now executed in parallel via
`@async.all`.

### Core: memory injection renders a plain provenance-tagged section; `MemoryPort` gains `source_name`

The built-in `MemoryRetrievalHook` replaces the legacy `[MEMORY]` line-list
format with a system-prompt-style section: a `## Any Memory About This Work`
header, a provenance line `from {source}. For Your Information.` (recalled
memory may be stale and must not override live instructions), then one
`- {content}` line per entry. `MemoryPort` gains `source_name` (default
`"memory"`) — protocol-level self-description, so the provenance line names
each contributing port without any branding in core. Idempotent
replace-in-place detection now matches the section header prefix. Envelope
rendering leaves core entirely: `render_context` and
`AgentConfig.context_namespace` are removed (breaking — drop the
`context_namespace` config field; the host owns its envelope).

### Core: `Hook::on_turn_end` — async turn-end slot (public API)

`Hook` gains a defaulted `async fn on_turn_end(Self, outcome : TurnEndOutcome)
-> Unit`. The Agent awaits it once per `run_turn`, after the terminal
observer projection (`TurnCompleted` / `TurnFailed`) and before the call
returns — on both the completed and the failed path — making it the slot for
side effects that must land by turn end, such as committing buffered writes
to an external system. `TurnEndOutcome` (`Completed` / `Failed(reason~)`)
labels the terminal state; the reason is the sanitized category label the
observers already saw in `TurnFailed`. A raise is a secondary failure —
reported to observers as `secondary_failure(hook_point="on_turn_end")`,
never replacing the turn's primary outcome — and cancellation is not a
defect. Non-breaking: the default implementation is a no-op, existing hooks
are unaffected.

### Model context window crosses the ModelPort seam; auto-compact is occupancy-based

`ProviderConfig` (a modelport's self-description) gains two optional fields:
`context_window : Int?` and `compact_threshold : Double?`. The Agent now reads
the active modelport's `provider_config()` **per turn** and sizes auto-compact
from it — precedence is defined exactly once: host `AgentConfig` override >
provider report > core default. `AgentConfig` gains `compact_threshold` in
(0, 1]; the previously hardcoded 0.9 default becomes **0.88**. `/model`
switching takes effect on the next turn without recomposing the Agent.

Auto-compact semantics (`Puppet::check_auto_compact`) now compare the
**latest verified context occupancy** — the most recent model step's
`total_tokens` (else `input + output` when both are reported) — instead of the
run-wide cumulative total, so several large-but-far-from-full calls can no
longer sum into a false trigger (`max_total_tokens` keeps policing the
cumulative account). After a compact rewrite the occupancy is unknown until
the next reliable reading, and each run gets at most ONE auto-compact
attempt. An auto-triggered compact that fails (e.g. a modelport that does not
implement compact, or a transport hiccup) no longer kills the turn: the skip
is recorded and surfaces to observers as a
`secondary_failure(hook_point="auto_compact")` event; manual `/compact`
failures still fail loudly.

### Hook lattice: every hook votes; user consent beats gates

`ToolHookDecision` gains `ApproveAfterConsent(call~, consent_scope~ : String)`.
The pump no longer short-circuits on the first non-Approve decision: every
registered `before_tool` hook is evaluated and the decisions merge —

1. a hook raising stays terminal (`HookRejected` → `AgentError::HookAborted`);
2. `Defer` still terminal-rejects until M5;
3. any `ApproveAfterConsent` executes the call even if other hooks returned
   `Reject` — an explicit user decision outranks a gate's veto, so plan mode
   cannot block a call the user just allowed at a permission ask (and
   registration order no longer decides life or death);
4. otherwise any `Reject` skips the call and feeds the **joined** reasons
   back to the model as `NotExecuted(RejectedByHook)`.

Policy pre-approvals (permission read class, Yolo) intentionally stay plain
`Approve` and do NOT count as consent — under Yolo, plan-mode rules still
apply while planning, with the plan auto-accepted at exit.

### `before_tool` Reject is steering, not a run failure

A `ToolHookDecision::Reject` no longer aborts the run. The rejected call is
never dispatched to the executor; instead the pump resolves the pending
`ExecuteTool` effect with a `ToolOutcome::NotExecuted` result carrying the new
`NotExecutedReason::RejectedByHook(reason)` payload. The reason flows back to
the model as a normal tool message and the run continues on the next model
step.

- Composition gates (plan mode, permission) now redirect the model instead of
  killing the turn: e.g. in plan mode a rejected `bash` call comes back as
  feedback and the model steers to read-only tools — previously the whole turn
  died with `AgentError::HookAborted`.
- Terminal semantics are unchanged for the other paths: raising from
  `before_tool` still aborts as `HookRejected` → `AgentError::HookAborted`, and
  `Defer` still terminal-rejects until M5 lands real suspension.
- Public API: `NotExecutedReason` gains the `RejectedByHook(reason~ : String)`
  variant (additive; exhaustive matches on the enum must handle it).
- The `Hook::before_tool` doc contract now states this explicitly — extensions
  should treat `Reject` as model-facing steering text.

### Capability completion: declared consumption + three-phase Lifecycle

The manifest gains a consumption direction. Extensions no longer need
host-specific constructor injection to reach the composed model or UI (the
pattern previously hand-wired by `posoco-ext-askquestion`,
`posoco-ext-statusbar`, `posoco-ext-permission`, and `cetas-core`).

```moonbit
pub(open) trait Lifecycle {
  fn on_compose(Self, ctx : CompositionView) -> Unit raise @error.CompositionError = _
  async fn on_start(Self) -> Unit = _
  async fn on_shutdown(Self) -> Unit
}
```

- `ExtensionManifest.requires : Array[Capability]` (`Capability::Model |
  Capability::Ui`) declares which composed capabilities an extension
  consumes. `Lifecycle::on_compose` delivers a curated `CompositionView`
  after every composition gate has passed, gated on the declaration —
  undeclared capabilities read `None`; raise
  `CompositionError::ExtensionComposeFailed` (new variant) to fail the
  composition loudly with no partial Agent. `on_compose` is sync by design:
  async port calls are impossible there, so the type system enforces
  "wire, don't act".
- `Lifecycle::on_start` fires once per Agent lifetime inside the first
  `run_turn`, before the first `TurnStarted` — the legitimate birth point
  for persisted-state reload and background loops (construction has no async
  root). Both new methods have defaults; existing `on_shutdown`-only
  implementations are unaffected, and shutdown still drains in reverse
  registration order.
- The `CompositionView` is curated, not a service locator: it will never
  expose tool invocation (would bypass `Hook::before_tool`), session stores
  (state ownership), or observer-event emission (core-owned).
- **Breaking (narrow)**: `ExtensionManifest` gains the `requires` field.
  `ExtensionManifest::empty(...)` + struct-update syntax is unaffected; full
  struct literals must add `requires: []`. In-repo callers (READMEs,
  `external/extension/*` manifests, `cetas-core` tests, testkit `tk_ext`)
  are updated.
- Extensions calling the composed model outside a business run must mint a
  synthetic `InvocationScope` in their own namespace (`effect_id=None`,
  never a business session/run identity) — scope is the cost/telemetry
  attribution key. See `docs/EXTENSIONS.md` "Consuming composed
  capabilities".

### Capability completion: scoped observation (`EventScope`)

Observer and post-event hook dispatches now carry run attribution, so
extensions can correlate telemetry, cost, and diagnostics to the exact
session/run/turn that produced them — no re-parsing, no heuristics.

```moonbit
pub(all) struct EventScope {
  session_id : SessionId
  run_id : RunId
  turn_id : TurnId
}

pub(open) trait Observer {
  fn on_event(Self, event : TurnEvent) -> Unit = _
  fn on_event_at(Self, scope : EventScope?, event : TurnEvent) -> Unit = _
}

pub(open) trait Hook {
  // ... before_model / before_tool unchanged ...
  fn on_post_event(Self, stage : HookStage) -> Unit = _
  fn on_post_event_at(Self, scope : EventScope?, stage : HookStage) -> Unit = _
}
```

- The core dispatches ONLY the scoped variants; their defaults delegate to
  the legacy unscoped methods, so existing `Observer`/`Hook`
  implementations keep working unchanged (non-breaking).
- Scope guarantees: turn-lifecycle events (`TurnStarted`/`TurnCompleted`/
  `TurnFailed`), envelope-projected events (`ModelResponseReceived`,
  `ToolCallPending`, `ToolCallResult`, `SessionRedirect`), and post-event
  hook stages always carry `Some(scope)` — minted by the Agent before
  `TurnStarted`, so even the first event is attributable. Out-of-run
  diagnostics (`StreamChunkReceived`, `Custom` secondary failures) carry
  `None`.
- Pinned by `src/scope_projection_wbtest.mbt` (`scope_projection/*`).

### Kernel: declared `ExecutionPolicy` is honored

`build_agent_catalog` no longer pins every provider tool to `Parallel`; the
provider's declared policy flows into the catalog as M1-T06 always intended.
No behavior change for existing tools (they all declare `Parallel`); it lets
mutation tools opt into `Exclusive` so they never share a tool wave. Pinned
by a new catalog test.

### Tool-loop limit: unbounded by default, opt-in budget

The tool-loop limit moves to the posture used by peer coding agents:
**unbounded by default, opt-in budget**. Previously
`AgentConfig.max_tool_rounds` was a required `Int` — and an internal
mis-conversion (`max_iterations = rounds + 1` while the pump burns 2
iterations per round) silently halved the effective limit, so a "20-round"
budget killed turns after ~10 tool rounds. The kernel budget is now the sole
semantic gate; the pump iteration cap is a derived livelock backstop that
always lets the budget fire first.

### Breaking: `AgentConfig.max_tool_rounds` is `Int?`

`None` is unbounded (the recommended product default — the human abort and
compaction govern loop length); `Some(n)` allows n full tool rounds and
rejects the (n+1)-th batch atomically; `Some(0)` still forbids tool
execution. All literals need wrapping:

```moonbit
// before
{ max_tool_rounds: 10, .. }
// after
{ max_tool_rounds: Some(10), .. }
```

The budget check is now exclusive (`>` instead of `>=`), so `Some(n)` really
means n full rounds — previously the n-th batch was already rejected.

### Breaking: `AgentError::ToolLoopExceeded` carries `consumed~, limit~`

The variant now reports the round count at rejection and the configured
limit, and its message tells the caller how to raise the ceiling
(kimi-code style). Pattern matches need `ToolLoopExceeded(..)`. A pump
livelock backstop trip no longer masquerades as `ToolLoopExceeded` — it
surfaces as `AgentError::Runtime(InvocationFailed(..))`.

### Breaking: model-side calls take an `InvocationScope`

`ModelPort::chat`/`compact` and their `Runtime` correspondences
(`call_model`/`compact`) now receive the identity of the session/run they
serve as the first parameter after `Self`:

```moonbit
pub(all) struct InvocationScope {
  session_id : SessionId
  run_id : RunId
  effect_id : EffectId? // Some = CallModel effect; None = compact
}
```

This is the canonical answer to "which session is this call serving" for
adapters that key behaviour on session identity — continuity, telemetry, cost
attribution, per-session policy. `effect_id` is always `Some` for
`chat`/`call_model` (the reducer-allocated effect identity; hosts that
propagate cancellation key in-flight model calls by it, mirroring
`EffectContext.effect_id` on the tool side) and always `None` for `compact`
(host-driven, not an effect). Scope-agnostic adapters simply ignore the new
parameter; forwarding adapters (routers) must forward it unchanged.

Migration: add `scope : @posoco.InvocationScope` (or `_scope`) as the first
parameter of your `chat`/`compact` implementations, and of
`call_model`/`compact` for custom `Runtime` hosts. Testkit gains
`ScopeRecordingModel` (records per-call scopes) and `tk_scope()` for driving
a port directly in tests. The `posoco-101` tutorial pins the last published
release and will be bumped when this change ships.

## 0.10.0

This release makes the `Hook::before_tool` interception point `async`, so
hooks can suspend for real host interaction — an approval prompt over
`UiPort::request`, a sandbox round-trip, a worker hop — instead of having to
decide synchronously. Under MoonBit's colorless-coroutine model this is an
extension, not a rewrite: an existing synchronous `fn before_tool(...)` impl
still satisfies the now-`async` slot, so existing hook implementations keep
compiling. The Puppet pump is the part that gained real behavior: it now
catches errors from `before_tool` and keeps the existing
cancellation/error classification intact — a cancellation raised inside the
hook (e.g. the host aborts an approval prompt) stays a cancellation, not a
hook defect.

The second user-visible change is a `raw : Json?` field on the canonical
`@kernel.Reasoning` type, carrying a provider-defined replay payload for the
OpenAI Responses API reasoning items that must be replayed verbatim when a
host manages conversation state itself. The Kernel never interprets it;
adapters that replay plain `content` text (DeepSeek, Kimi, OpenAI-compatible)
leave it `None`. This is a struct-shape break (see below).

### Breaking: `Reasoning` gains a `raw : Json?` field

`@kernel.Reasoning` now has `raw : Json?` alongside `content`. Anywhere that
constructs a `Reasoning` literal must add the field:

```moonbit
// before
Reasoning::{ content: text }
// after
Reasoning::{ content: text, raw: None }
```

`StreamAccumulator::to_completion` and the in-tree adapters are updated; the
field defaults to `None` at every site that does not carry a replay payload.

### Changed: `Hook::before_tool` is `async`

```moonbit
pub(open) trait Hook {
  fn before_model(Self, Array[@kernel.Message]) -> Array[@kernel.Message] raise HookAbort = _
  async fn before_tool(Self, @kernel.ToolCall) -> ToolHookDecision = _   // ← now async
  fn on_post_event(Self, HookStage) -> Unit = _
}
```

- **Existing implementors need no change:** a plain `fn before_tool(...)` body
  satisfies the `async` slot under MoonBit's colorless-coroutine model. This
  only *enables* suspending hooks; it does not *require* them.
- **New capability:** a hook that needs host interaction — `UiPort::request`
  for an approval prompt, a sandbox/worker round-trip — implements
  `before_tool` as an `async fn` and suspends inside it.
- **Error classification preserved by the pump:** errors raised from
  `before_tool` are caught. A cancellation (e.g. the host aborts an approval
  prompt mid-suspend) rejects the run as `EffectExecutionCancelled(phase:
  "AwaitingTools")`; any other raise rejects it as a terminal `HookRejected`
  carrying the message — cancellation stays cancellation, not a hook defect.
  (Pinned by new cases in `src/posoco_wbtest.mbt`.)

### Added

- `Reasoning::raw : Json?` — opaque provider replay payload; see breaking note
  above.
- First-class CI/CD for the project:
  - `check.yml` and `coverage.yml` pipelines restructured with **JS backend
    support** (native remains the primary gate); a `moon update` step runs
    before every job so the toolchain is fresh.
  - `publish.yml` — on GitHub release, runs the full `moon check` / `moon
    info` (with `git diff --exit-code`) / `moon test` / `moon fmt` gate and
    then `moon publish` to mooncakes using `MOONCAKES_TOKEN`.
  - `--deny-warn` removed from the `moon check` step in `check.yml` and
    `publish.yml` so the gate fails on errors, not on pending warnings.

### Fixed

- `control_test.mbt` uses `repr(...)` instead of the removed `Repr(...)`,
  matching the current MoonBit builtin.

### Notes

- Removed the unused `xlog` dependency from `moon.mod`.
- The runtime seam and `Agent(exts, config)` defaults from 0.9.0 are
  unchanged; suspending hooks compose with both.

## 0.9.0

This release opens the **runtime seam**: a supported, public way for
advanced hosts to control how effects execute — cancellation propagation,
dynamic tool catalogs, and host-initiated follow-ups — without importing
anything under `internal/`. It exists for host builders (tool protocol
bridges, remote or sandboxed executors, browser/worker runtimes), not for
extension authors: **the Ports API and `Agent(exts, config)` are unchanged
and remain the recommended default.** No breaking changes this time;
everything below is additive.

The seam is deliberately 1:1 with the internal effect-execution boundary, so
the Kernel/Puppet state machine stays the single owner of phases, journals,
run/turn identity, terminal events, and session commits.

### Added: experimental runtime seam (`colmugx/posoco/runtime`)

- `Agent::with_runtime(exts~, config~, runtime~, ui_projection?, catalog_source?)` —
  same Agent, same assembly as the default constructor, but the caller
  supplies the effect-execution runtime. Typical shape: wrap `PortRuntime`
  and override only the methods you need (e.g. `execute_tool` +
  `cancel_effects` for cancellation propagation).
- `Runtime` — the public effect-execution contract: `call_model`,
  `execute_tool(EffectContext)`, `cancel_effects(effect_ids, reason)`,
  `compact(...)`. `execute_tool` receives the reducer-allocated `effect_id` —
  the same id later passed to `cancel_effects` — which is the correlation
  key for cancellation (e.g. `EffectId → AbortController`) and incremental
  progress. `cancel_effects` is best-effort, idempotent per effect id, and
  reports `Propagated` / `NotPropagated` / `AlreadySettled`.
- `PortRuntime` — the default `Runtime` over your `ModelPort` +
  `ToolProvider`s; this is what `Agent(exts, config)` now builds internally.
  Both constructors share one assembly path.
- `Agent::control() -> RuntimeControl` — available on **every** Agent,
  custom runtime or not:
  - `enqueue_follow_up(message)` — a background task can ask the Agent to
    continue. Queued follow-ups drain FIFO at turn boundaries, each driving
    a full turn on the same session (real `TurnStarted`/`TurnCompleted` and
    session commits); `run_turn` returns the last drained turn's
    `TurnResult`. Identity-guarded: no active run → `RejectedStale`; queue
    full (64) → `RejectedQueueFull`.
  - `abort_active(detail)` — idempotent per active run; in-flight effects
    receive a best-effort `cancel_effects` at the loop's next safe point.
  - `active_run_id()` / `active_turn_id()` / `pending_follow_ups()`.
- `CatalogSource` — host-owned, versioned tool catalog for `with_runtime`.
  Posoco reads it at construction and re-reads it at each prompt boundary
  where `revision()` changed. One rebuild attempt per revision: invalid
  definitions keep the previous snapshot and surface a `secondary_failure`
  observer event; in-flight runs always keep their pinned snapshot.
  Definitions are taken verbatim — `owner` and `policy` respected, unlike
  port-declared tools (which stay pinned to `Parallel`).
- Canonical wire types promoted to `@kernel`: `RunId`, `TurnId`,
  `SessionId`, `EffectId`, `CatalogVersion`, `CancelReason`,
  `CancelDisposition` — the public seam references them without internal
  imports.
- `docs/RUNTIME.md` — the host-facing contract: when you need the seam,
  the mental model, MUSTs pinned by named tests, an assembly guide
  (L0–L2), anti-patterns, and the stability policy.

### Notes

- The runtime seam is **experimental**: it may evolve with the active Lean
  Puppetry milestone, and any change lands here with migration notes. The
  contracts are pinned by `src/runtime_seam_wbtest.mbt` and
  `src/runtime/control_test.mbt`, which run in the required native gate.
- `Agent::run_turn` now drains queued follow-ups at turn boundaries (cap 64
  per call). This is observable only when a host submits follow-ups through
  `control()`; the default turn flow is unchanged.

## 0.8.0

This release fixes places where posoco violated its own design principles —
most visibly, three parallel hook traits where one was promised. We broke
your manifests to do it; we're sorry for the churn, and we chose to cut once
at 0.8.0 rather than keep two registration channels alive (a dual track
would defeat the point of unifying). Every break below is mechanical, and
each has a before/after migration.

### Breaking: three hook traits merged into one `Hook`

`PreModelHook`, `PreToolHook` and `PostEventHook` are deleted. There is now a
single `pub(open) trait Hook` whose three methods all have default
implementations — implementors override only the interception points they
care about:

```moonbit
pub(open) trait Hook {
  fn before_model(Self, Array[@kernel.Message]) -> Array[@kernel.Message] raise HookAbort = _
  fn before_tool(Self, @kernel.ToolCall) -> ToolHookDecision = _
  fn on_post_event(Self, HookStage) -> Unit = _
}
```

What was unified is registration, not signatures: each point keeps its
precise contract (can-abort / can-rewrite / read-only). Adding a new
interception point is now non-breaking — one defaulted method plus one call
site in the pump.

- **Implementors:** change `impl PreModelHook for X with fn before_model(...)`
  to `impl Hook for X with fn before_model(...)` (same for `before_tool` /
  `on_post_event`). A type that implemented several old traits now has
  several `impl Hook for X with fn ...` blocks, one per method.
- **Manifests:** the three manifest fields `pre_model_hooks` /
  `pre_tool_hooks` / `post_event_hooks` are replaced by one
  `hooks : Array[&Hook]`. Merge your arrays in the order
  pre_model → pre_tool → post_event.
- **Testkit:** `tk_ext(..., pre_model_hooks=..., pre_tool_hooks=..., post_event_hooks=...)`
  becomes `tk_ext(..., hooks=[...])`.
- **Trigger semantics (documented, unchanged behavior):** `before_model`
  fires at prompt start on the initial messages and after each Resume —
  *not* before every model call inside a tool round-trip. `before_tool`
  fires per `ExecuteTool` effect; `on_post_event` fires after every effect.
- **`PostStage` renamed to `HookStage`.** The old name collided with
  `KernelEvent` variant names while carrying different payload shapes;
  `HookStage` makes the hook-facing projection unmistakable. Mechanical
  rename, variants unchanged.
- **Testkit:** `HookRecord2` renamed to `HookRecord` (the transitional
  suffix is gone).

### Breaking: `Observer::on_kernel_event` deleted

`Observer` keeps only `on_event(TurnEvent)`. If you overrode
`on_kernel_event` for per-step kernel notifications, move that logic to
`Hook.on_post_event(HookStage)` and register the type as a hook.

### Breaking: built-in adapters moved out of the port package

`src/port` now contains only extension contracts. The concrete adapters
`SystemPromptHook`, `SystemPromptSection`, `MemoryRetrievalHook`,
`UiRenderHook`, `NoopUiPort` and `CompositeUiPort` moved to the root
package. Root paths (`@posoco.SystemPromptHook`, …) are unchanged; any
direct `@port.X` reference to these structs must become `@posoco.X`.

### Breaking: `UiRenderHook` projection is opt-in

`Agent` no longer auto-installs the built-in UI render policy. To restore
the previous behavior, pass the new optional constructor flag:

```moonbit
Agent(exts=..., config=..., ui_projection=true)
```

Hosts with their own UI policy should leave it off (default) and register
their own `Hook` instead — this is what cetas-js was already doing by
fighting the auto-injection.

Why a constructor flag rather than "just register `UiRenderHook` yourself":
the flag wires the hook to the **aggregated** `UiPort` (the Composite fan-out
across every manifest's `ui=[...]` contribution), which a hand-registered
hook cannot reach. Registering manually still works for a single host-owned
UI.

### Behavior change: hook/observer secondary failures are non-fatal

A failing hook (`on_post_event`) or observer no longer jeopardizes the run:
the failure is emitted as exactly one
`Custom(source="posoco.core", label="secondary_failure")` event with a
sanitized payload, and the turn continues. `MemoryRetrievalHook` search
failures take the same channel via its new optional `on_failure?` callback
(wired by `Agent` automatically). This finally matches what the docs always
promised.

### Breaking: internal machinery sealed

`@kernel` now exports only the canonical protocol types (the set already
re-exported at the root). The execution machinery — reducer, state, effect,
event, input, error, run context, scheduler, catalog, schema validation,
host runtime — moved to `colmugx/posoco/internal/kernel_exec`, and the whole
`puppetry` package moved to `colmugx/posoco/internal/puppetry`. MoonBit
enforces `internal/` visibility, so these can no longer be imported from
outside. The supported runtime entry point is, as documented, `Agent`;
nothing in `external/` referenced these packages.

Speculative M2 machinery that no production path used was removed outright:
the `PuppetLifecycleNode` startup/rollback executor (Agent drives the public
`Lifecycle` port itself) and the shipped `scripted_driver` (it survives only
as a test-scope fixture for the reducer golden suite).

### Added

- `ToolRegistry::register_strict` — raises on name collision. `register`
  keeps its hot-replace semantics and now says so in its docstring.
- `Hook` default-method pass-through and single-impl-all-points conformance
  tests; `ui_projection` opt-in/out regression tests.

### Fixed

- The reducer is again the sole transcript writer: same-length pre-model
  rewrites and compact results route through kernel inputs instead of the
  pump mutating run state directly.
- System-prompt section headers now name their source: the assembled prompt
  uses the contributing extension's manifest id instead of the meaningless
  synthetic `section_0`, `section_1`, …
- Assorted documentation drift: `docs/02-architecture.md`,
  `docs/04-developer-guide.md`, `docs/EXTENSIONS.md` and the README
  quickstart now show the real, compiling API.
