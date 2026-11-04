# Posoco

Posoco is a protocol-first LLM agent framework for MoonBit: the core owns the
agent loop and its invariants, and every runtime capability — model, tool,
session, observer, hook, UI, command, prompt, memory, lifecycle — is injected
through open port traits. Products compose one `Agent(exts~, config~)`; the
core never dictates shape.

> **API docs:** <https://mooncakes.io/docs/colmugx/posoco> · **中文 README:**
> [`README-zh.mbt.md`](./README-zh.mbt.md)
>
> **WARNING:** Posoco is experimental (0.x). The public API is subject to
> change.

## Installation

```bash
moon add colmugx/posoco@0.24.0
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
| `UiPort` | Structured UI intents + interaction requests (Status / Notice / Widget / Input / Confirm / Select) |
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
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "session_1")
```

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
`TurnCompleted` on success, or `TurnFailed` on any primary failure.

## Typed events

Posoco owns one event system per Agent for both core notifications and community
protocols. Define a closed payload ADT and add a constructor to the open
`@posoco.Event`; publishers and listeners exchange typed values, not JSON topics.

- **Extensions:** declare `requires: [@posoco.Capability::Events]` and register a
  `Lifecycle`; obtain `view.events()` in `on_compose`, then call
  `events.publish(event)` or `events.subscribe(handler, namespace_=...)`.
- **Hosts:** call `agent.subscribe_events(handler, namespace_=...)`; cancel the
  returned `Subscription` when finished. No bus construction or runtime factory
  is needed.
- **Namespaces:** publication is bound to `Extension(manifest_id)`. `Posoco` is
  reserved for `Core(TurnEvent)` notifications; an extension cannot publish
  `Core`. Subscriptions may select any namespace, or all with `None`.
- **Boundaries:** handlers are synchronous and non-raising, notifications have
  no replay, and shutdown closes retained capabilities. `Observer` is a core-only
  adapter on this same system; `Hook` remains the interception API. Event
  notifications do not replace awaited journal/checkpoint commits.

## Extension library

[`colmugx/posoco-extension`](https://github.com/colmugx/posoco-extension) maintains a curated set of ready-to-use extensions, and other port implementations you can drop straight into `Agent(exts~, config~)`.

## Learn more — Posoco 101

[`posoco-101/`](./posoco-101/) is a chapter-by-chapter course that builds from
"what is an agent loop" up to a mini coding agent. The outline and chapter
status live in [`posoco-101/OUTLINE.md`](./posoco-101/OUTLINE.md):

| # | Chapter | Status |
|---|---|---|
| 01 | Agent Loop principles: how to write your own | ✅ |
| 02 | Your first agent with Posoco (10 lines) | ✅ |

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
