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
moon add colmugx/posoco@0.9.0
```

## Ports

Ports are the only seams between Posoco core and the capabilities an agent
uses.

| Port | Purpose |
|---|---|
| `ModelPort` | Model chat + context compaction (`chat`, `compact`, `provider_config`) |
| `ToolProvider` | Tool discovery and execution |
| `SessionStore` | Load / save conversation session |
| `Observer` | Read-only turn-event observation |
| `Hook` | Pipeline interception with default methods: rewrite messages or abort before model (`before_model`), approve / defer / reject before tool (`before_tool`), read-only after each effect (`on_post_event`) |
| `MemoryPort` | Long-term memory storage and retrieval |
| `Lifecycle` | Async resource cleanup on shutdown |
| `CommandPort` | User-side slash-command enumeration and dispatch |
| `UiPort` | Structured UI intents + interaction requests (Status / Notice / Widget / Input / Confirm / Select) |
| `SystemPromptContributor` | Declare system-prompt sections (assembled and injected before the model call) |
| `Extension` | Self-report protocol: `extension_id` + `manifest` declaring which ports an extension contributes |
| `ProviderConfig` | Model-side provider config (companion type, not a runtime port) |

## create an extension

An extension is a struct that implements one or more port traits **and**
`@posoco.Extension`. The same `self` reference goes in every manifest slot
whose port the struct implements; the `id` string is used only for composition
diagnostics (tool-collision messages, observer attribution), never for routing
or persistence.

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
///    every slot whose trait ReadTools implements; the rest stay empty.
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_read",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
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

For a `ModelPort` extension, put `self` under `models: [self]` instead and
leave `tools: []`.

## compose an agent

Agent authors import extension packages and wire their instances into one
`Agent`. `exts` is an array of self-reporting extensions — order-independent;
Agent aggregates their manifests.

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
- `EmptyPort("SessionStore")` — no extension contributes a required port

A turn that has emitted `TurnStarted` emits exactly one terminal event:
`TurnCompleted` on success, or `TurnFailed` on any primary failure.

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
