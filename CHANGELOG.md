# Changelog

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
