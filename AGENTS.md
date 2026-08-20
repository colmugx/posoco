# Posoco Agent Guide

This is a [MoonBit](https://docs.moonbitlang.com) project: **`colmugx/posoco`** — an LLM agent framework using hexagonal (ports-and-adapters) architecture. Depends on `moonbitlang/async`.

## One-Line Summary

Posoco exposes `Agent` as its stable high-level deep module: products compose
`Agent(exts, config)`, while Agent internally owns one long-lived Puppet backed
by a functional Kernel.

## Architecture correction (2026-08-02; supersedes the 2026-07-26 directive)

- `Agent` and its high-level turn API are the stable, supported product
  boundary.
- Each Agent internally owns one long-lived `Puppet`. Puppet is the sole
  execution loop, but it is an implementation detail, not a product-facing
  composition API.
- Cetas consumes `Agent`; it must not construct Puppet or depend directly on
  Kernel, journal, effect, reducer, `HostRuntime`, or `PuppetConfig` contracts.
- Public ports exist only where community extensions have genuine behavioral
  variability. Internal execution mechanics must not become root public ports
  merely because they are separate components.
- This section supersedes conflicting product-boundary or deletion guidance in
  the former **Breaking migration directive (2026-07-26)**.

## Developer roles and trust boundary

- **Posoco core developers** own reliable data flow, invariants, the Agent deep
  module, and the small set of public hexagonal ports needed by extensions.
- **Community extension developers** implement those public extension ports;
  they do not modify or couple to Posoco internals.
- **Agent developers** compose `Agent(exts, config)` and use its high-level API
  without learning Puppet or Kernel internals.
- **Customers** consume products powered by Posoco and should be able to trust
  their reliability; internal complexity must not leak into product APIs.

## Active product direction (2026-08-02)

The active milestone remains **Lean Puppetry / Trusted Recoverable Coding
Turn**: one long-lived internal Puppet, real parallel tool waves, boundary
commits, capability declarations, and deletion of duplicate execution
semantics. These capabilities deepen Agent; they do not replace Agent with
Puppet as the public runtime.

`CETAS-REBUILD-PROGRESS.md` is the current incremental implementation record.
Do not add new horizontal Puppetry abstractions unless they directly serve this
vertical milestone, and do not expose those abstractions through the
product-facing API.

## Target Architecture

```
Layer 3 — Products (Cetas and other agent applications)
  construct Agent(exts, config) and call its high-level lifecycle/turn API

Layer 2 — Public Posoco boundary
  Agent is the stable deep module; genuine extension variability is expressed
  through intentional public hexagonal ports

Layer 1 — Internal implementation
  Agent owns one long-lived Puppet; Puppet is the sole loop and interprets the
  internal Kernel's reducer/effects/journal/invariants
```

## Commands

```bash
rtk moon check --target native --output-json   # type check (also runs in pre-commit hook)
rtk moon test  --target native --output-json   # all root tests; see REPAIR-IMPLEMENTATION.md for current count
rtk moon test --target native --output-json -f 't05*'  # filter by glob
rtk moon test --update                         # refresh snapshots
rtk moon fmt                                   # format all code
rtk moon info                                  # update .mbti generated interface
rtk moon coverage analyze                      # coverage report (redirect explicitly if needed)
```

> **IMPORTANT**: All `moon check`/`test`/`build` commands MUST use `--output-json`
> so diagnostics are machine-readable and test counts are captured. Always pass
> `--target native` for the primary gate (default target runs sync tests only).

**Pre-commit checklist** (the hook only runs `moon check`, but run all 4):
```bash
rtk moon check --target native --output-json
rtk moon test --target native --output-json
rtk moon fmt
rtk moon info
```

## MoonBit Syntax Traps (Common Mistakes)

| Trap | Wrong | Correct |
|------|-------|---------|
| Trait impl | `impl Trait for Type { fn method(...) }` | `pub impl Trait for Type with method_name(self, ...) { }` |
| Async trait impl | `with async fn method(...)` (parse error) | `with method(self, ...)` — async is inferred from the body; a plain sync body also satisfies an `async` slot |
| Try operator | `func()?` | Match `Ok`/`Err` explicitly |
| Optional chain | `self.hook?.call()` | `match self.hook { Some(h) => ..., None => () }` |
| Map literal | `{ key: value }` | `Map::from_array([("key", value)])` |
| Trait object | `Box<dyn Trait>` | `&Trait` — Agent has no generics |
| Named enum variant | `Variant { field: Type }` | `Variant(field~ : Type)` — note `~` label |
| Infinite loop | `loop { }` (Rust) | `while true { }` |
| Struct fields `mut` | Needs `mut` on Map/Array fields | Only `mut` on scalar index counters, not on Array/Map fields |
| Map access | `map[key]` without guard | Guard with `.contains()` first (returns V, not Option[V]) |
| Json null | `Json::Null` | `Json::null()` |

## Mock Pattern for Tests

Tests exercise the same high-level interface used by agent developers. Build
extension manifests with `tk_ext`, then compose one Agent:

```moonbit
let model = ScriptedModel(steps=[Respond(tk_stop_response("hi"))])
let tools = RecordingToolProvider(
  tool_defs=[],
  outcomes=Map::from_array([]),
)
let store = RecordingSessionStore()
let observer = RecordingObserver()
let agent = Agent(
  exts=[
    tk_ext(id="model", model=Some(model)),
    tk_ext(id="tools", tools=[tools]),
    tk_ext(id="io", sessions=[store], observers=[observer]),
  ],
  config=tk_config(),
)
let result = agent.run_turn(tk_user_msg("hello"), "session_1")
```

Key mock conventions:
- `MockModelPort` — `mut index : Int`, cycles through `responses` array, fails when exhausted
- `MockToolProvider` — unified: declares `tools` AND holds `results` map for execute; guard with `.contains()` first
- `MockSessionStore` — in-memory map; returns empty session for unknown IDs
- `MockObserver` — records all events for post-turn inspection
- Always use `Map::from_array([])` for empty maps and session metadata
- Always use `Json::null()` for ToolCall arguments
- For new regression tests, prefer the testkit fakes (`ScriptedModel`, `RecordingToolProvider`, `RecordingSessionStore`, `RecordingObserver`) in `testkit.mbt`

## Useful Context from Docs

See `docs/` for detailed guidance:
- `docs/support-matrix.md` — Supported/experimental package matrix + per-target truth (M0-T01/T03)
- `docs/workspace.md` — Workspace & local-resolution entry (M0-T02)
- `docs/architecture.md` — Full design rationale, type definitions, loop pseudocode
- `docs/DEVELOPING.md` — MoonBit syntax traps and coding conventions (essential reading for newcomers)
- `docs/EXTENSIONS.md` — How to create extension packages that implement Posoco traits
- `docs/TESTING.md` — Mock patterns, test coverage map, common pitfalls
- `docs/questions.md` — Open MoonBit syntax/toolchain questions (checked by User)

## Rules

- Before starting work, load the `moonbit-agent-guide` skill (per the instruction at the top of this file); load `moonbit-orientation` when you need more MoonBit documentation or toolchain detail.

## MoonBit Syntax Uncertainty

遇到 MoonBit 语法不确定时，不要自信地给出方案。把问题记录到 `docs/questions.md`，每个工作阶段结束后（或关键代码卡住时），User 会检查列表并帮助解决。
