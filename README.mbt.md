# Posoco

Posoco is a protocol-first LLM agent framework for MoonBit: the core owns the
agent loop and its invariants, and every runtime capability — model, tool,
session, observer, hook, UI, command, prompt, memory, lifecycle — is injected
through open port traits. Products compose one `Agent(exts~, config~, events~)`;
the core never dictates shape.

> **API docs:** <https://mooncakes.io/docs/colmugx/posoco> · **中文 README:**
> [`README-zh.mbt.md`](./README-zh.mbt.md)
>
> **WARNING:** Posoco is experimental (0.x). The public API is subject to
> change.

## Installation

```bash
moon add colmugx/posoco@0.24.2
```

## Ports

Ports are the only seams between Posoco core and the capabilities an agent
uses.

| Port | Purpose |
|---|---|
| `ModelPort` | Model chat + context compaction (`chat`, `compact`, `provider_config`) |
| `DecisionPort` | Provider-neutral structured semantic judgement |
| `ToolProvider` | Tool discovery and execution |
| `LogPort` | Structured application logging with caller-selected durability |
| `SessionPort` | Load / save conversation session |
| `Observer` | Read-only turn-event observation |
| `Hook` | Pipeline interception with default methods: rewrite messages or abort before model (`before_model`), approve / defer / reject before tool (`before_tool`), read-only after each effect (`on_post_event`) |
| `MemoryPort` | Long-term memory storage and retrieval |
| `Lifecycle` | Composition wiring, one-time async startup, shutdown cleanup |
| `CommandPort` | User-side slash-command enumeration and dispatch |
| `UiPort` | Structured UI intents + interaction requests (Status / Notice / Widget / Input / Confirm / Select) — legacy adapter, see [UI protocol](#ui-protocol) |
| `SystemPromptContributor` | Declare system-prompt sections (assembled and injected before the model call) |
| `Extension` | Self-report protocol: `extension_id` + `manifest` declaring which ports an extension contributes |
| `ProviderConfig` | Model-side provider config (companion type, not a runtime port) |

## create an extension

An extension is a struct that implements one or more port traits **and**
`@posoco.Extension`. The same `self` reference goes in every manifest slot
whose port the struct implements. The manifest `id` identifies the extension
in composition diagnostics and binds its event-publishing namespace. If an
extension requires `Events`, its id must be unique within the Agent.

The minimal shape is two methods plus one `pub extend` line:

```moonbit nocheck
// 1. Implement the port trait(s) your extension contributes.
//    (ToolProvider shown here; the body is omitted for brevity.)

///|
pub impl @posoco.Extension for ReadTools with fn extension_id(_self) -> String {
  "posoco_ext_read"
}

///|
/// 2. Declare which ports ReadTools contributes. The same `self` goes under
///    every slot whose trait ReadTools implements; omitted slots default to [].
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_read", tools=[self])
}

///|
/// 3. Expose Extension methods for dot-syntax callers and so `&ReadTools`
///    coerces to `&@posoco.Extension` inside `Array[&@posoco.Extension]`.
pub extend ReadTools with @posoco.Extension::{extension_id, manifest}

///|
/// 4. Optional factory for hosts that construct from defaults.
pub fn read_extension() -> ReadTools {
  ReadTools::ReadTools()
}
```

For a `ModelPort` extension, put `self` under `models: [self]` instead:
`ExtensionManifest(id=..., models=[self])`.

## compose an agent

Agent authors import extension packages and wire their instances into one
`Agent`. Agent aggregates their manifests; extension order determines hook,
observer, and lifecycle registration order. It does not give colliding tools a
last-wins priority.

```moonbit nocheck
// The host owns one event resource per Agent. Create it first: ports and plain
// objects may need their owner-bound `Events` before the Agent exists.
let system = @posoco.EventSystem()

let agent = @posoco.Agent(
  exts=[
    model_ext,   // an extension contributing ModelPort
    read_ext,    // the ReadTools extension built above, contributing ToolProvider
  ],
  config={
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  },
  events=system,
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "session_1")
```

`events~` is required: Posoco no longer creates an implicit event resource.
Composition takes exclusive ownership of the value, so one `EventSystem` serves
one Agent.

`AgentConfig` has four fields: `max_tool_rounds` (`Int?` — `None` is
unbounded and the recommended default; `Some(n)` allows n full tool rounds),
`temperature`, `max_output_tokens`, `model_context_window`. `run_turn(message, session_id)`
is async and raises `AgentError`. Composition is fail-fast and raises
`CompositionError`:

- `MissingModel` — no extension contributes `ModelPort`
- `MultipleModels` — more than one extension contributes `ModelPort` directly
  (multi-model routing belongs inside a meta-extension such as
  `posoco-ext-llm`, not in the core)
- `ToolCollision` — two extensions register the same tool name (no last-wins)
- `SessionPort` is optional; without one the Agent runs ephemerally and skips durable session persistence

A turn that has emitted `TurnStarted` emits exactly one terminal event:
`TurnCompleted` on success, `TurnFailed` on any primary failure, or
`TurnCancelled` when the turn was cancelled (soft abort, hard cancellation,
Agent shutdown, or a cancelled resume). Cancellation is never reported as a
failure: the caller still gets the typed `AgentError::Cancelled`, and the
operation settles `cancelled`. A cancelled compact publishes no turn event at
all — a compact is an operation, not a turn.

## Typed events

Posoco owns one event resource per Agent for both core notifications and
community protocols. Define a closed payload ADT and add a constructor to the
open `@posoco.Event`; publishers and listeners exchange typed values, not JSON
topics. The resource is live: it grants capabilities and delivers notifications
before, during, and after composition — it never replays history.

```moonbit nocheck
let system = @posoco.EventSystem()

// A plain object (no Lifecycle field, no Agent reference) publishes into
// Extension("status_bar"). The grant survives the Agent takeover.
let granted = system.publisher(owner="status_bar") // Result[Events, EventError]

// Hosts can listen before the Agent exists.
let subscription = system.subscribe(
  envelope => handle(envelope),
  namespace_=Some(@posoco.EventNamespace::Extension("status_bar")),
)
```

- **Host resource:** create `EventSystem()` before the ports and pass the same
  value to exactly one `Agent(..., events=system)`. Construction takes exclusive
  ownership; a second Agent on that value is rejected and leaves the first
  Agent working.
- **Plain objects:** `system.publisher(owner~)` grants an owner-bound `Events`
  without a `Lifecycle` and without an Agent. Publication is fixed to
  `Extension(owner)` at grant time; `owner` is chosen by the host and may differ
  from a manifest id.
- **Hosts:** subscribe with `system.subscribe(handler, namespace_=...)` before
  composition, or with `agent.subscribe_events(handler, namespace_=...)`
  afterwards. Cancel the returned `Subscription` when finished.
- **Extensions:** declare `requires: [@posoco.Capability::Events]` and register a
  `Lifecycle`; obtain `view.events()` in `on_compose`, then call
  `events.publish(event)` or `events.subscribe(handler, namespace_=...)`.
- **Namespaces:** `Posoco` is reserved for `Core(TurnEvent)` notifications; an
  owner-bound capability cannot publish `Core`. Subscriptions may select any
  namespace, or all with `None`.
- **Lifecycle:** a failed or cancelled turn keeps the resource open; any
  composition failure after takeover closes it and revokes the capabilities
  already granted; `shutdown()` closes it. Grants, publishes and subscriptions
  then return `Err(Closed)`; `cancel()` stays idempotent. Closing an owned
  resource directly, or taking it over twice, is a typed error — never a silent
  reopen.
- **Boundaries:** handlers are synchronous and non-raising, deliveries follow
  registration order with a per-batch snapshot, and the resource is never
  replayed. `Observer` is a core-only adapter on this same system; `Hook` remains
  the interception API. Event notifications do not replace awaited
  journal/checkpoint commits.

A runnable end-to-end host example (plain publisher before the Agent, early
subscription, typed delivery, `Closed` after shutdown) is
[`examples/quickstart`](./examples/quickstart/README.md). The full resource
contract and migration steps are in
[`src/events/MIGRATION.md`](./src/events/MIGRATION.md).

## UI protocol

`UiPort` stays the legacy render / blocking-request adapter. Next to it, the
Agent carries a state protocol: extensions publish resources and ask structured
questions, hosts observe and answer.

- **Extensions** declare `requires: [@posoco.Capability::Ui]` and take
  `view.ui_resources()` / `view.ui_interactions()` in `on_compose`. Resources are
  owner-bound (manifest id + local key + runtime generation), published as a
  complete replacement with a monotonic revision, updated through
  `replace(expected=...)`, and withdrawn explicitly. `resources.operation()`
  returns a handle bound to the currently admitted operation; its
  `OperationBound` resources are reclaimed when that turn or compaction settles.
- **Hosts** use `agent.ui_host()`. One `snapshot()` is a single synchronous cut of
  live resources, pending questions and both cursors; continue with
  `changes_since` / `interactions_since`, or `subscribe` for ordered push
  delivery. `dispatch` routes a declared action back to the owning extension and
  returns an acceptance receipt — the resulting state arrives on the feed.
  `connect` declares what a host can render and answer; a blocked question
  without a matching connection fails fast with `HostUnavailable`.
- **Boundaries:** all of it is in-process — cursors, pending questions and
  replay windows do not survive an Agent restart and there is no cross-process
  recovery. `UiPort` keeps its old semantics and gains none of these guarantees.
  Actions and answers grant no tool, model or session authority.

Walkthrough: [`posoco-101/13-ui-observe-and-ask.mbt.md`](./posoco-101/13-ui-observe-and-ask.mbt.md);
contract: [`docs/ui-protocol.md`](./docs/ui-protocol.md).

## Extension library

[`colmugx/posoco-extension`](https://github.com/colmugx/posoco-extension) maintains a curated set of ready-to-use extensions, and other port implementations you can drop straight into `Agent(exts~, config~, events~)`.

## Learn more — Posoco 101

[`posoco-101/`](./posoco-101/) is a chapter-by-chapter course that builds from
"what is an agent loop" up to a mini coding agent. The outline and chapter
status live in [`posoco-101/OUTLINE.md`](./posoco-101/OUTLINE.md):

| # | Chapter | Status |
|---|---|---|
| 01 | Agent Loop principles: how to write your own | ✅ |
| 02 | Your first agent with Posoco (10 lines) | ✅ |
| 03–12 | Extension composition, tool use, routing, reflection, parallelization, planning, memory, observers, typed errors, capstone | planned |
| 13 | Make the interface observable: UI resources, push observation, structured questions | ✅ |
| 14 | Streaming identity: scope, drop notices and the final response | ✅ |
| 15 | Several hosts and nobody answering: capabilities and fail-fast | ✅ |
| 16 | Cancellation is not failure: the three turn terminals | ✅ |

## Development & validation

```bash
moon check --output-json
moon test --output-json
moon fmt
moon info
```

## Why "Posoco"?

"Posoco" comes from **persocom** — the humanoid computers in CLAMP's manga *Chobits*. Since Posoco is the agent runtime split out of Elyra's architectural philosophy, it takes the homophone Posoco.

## License

Apache-2.0.
