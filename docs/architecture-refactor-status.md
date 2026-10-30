# Posoco package-boundary refactor — verification ledger

Base revision: `e1c65aff41e6e024523e76fde9b7a30896fc8bda` (2026-10-30 audit).

## Design constraints

- `Agent` remains the only supported product-level composition entry point.
- `Puppet` is the sole run loop; the reducer/effect/journal are internal details.
- Public ports are reserved for third-party extension variability.
- Packages form an acyclic import graph; no internal package imports the root package.
- Preserve every existing test file verbatim and retain business-core semantics.
- Do not equate a move-only refactor with a runtime performance improvement.

## Observed baseline (static)

- Root `src/`: ~290 KB of non-test, non-testkit MoonBit implementation across 21 files.
- Root contains another ~62 KB across 10 `testkit*.mbt` and `ui_testkit.mbt` files.
- Existing internal packages: `kernel_exec`, `puppetry`, `tool_directory`, `runtime_bridge`.
- Existing native performance guards: 100,000 TextDelta pushes <2s; 8x4 tool waves <5s; 50,000 streaming chunks <5s. These are regression tripwires, not benchmark baselines.

## This PR: move-only changes

- [x] Split the reusable `ToolRegistry` and command argument parsing into `src/builtin/` as an actual MoonBit package.
- [x] Retain legacy root symbol names through `pub using` aliases.
- [x] Extract the self-contained built-in UI/prompt hooks and no-op lifecycle adapter without changing their method bodies.
- [x] Extract the built-in memory collector, message builder and tool provider to `src/internal/memory/`, retaining root local imports for unchanged whitebox tests.
- [x] Extract `SessionProgress` persisted-prefix cursor/dirty bookkeeping to `src/internal/session_state/`.
- [x] Establish an independent `src/testkit/` package for the self-contained `RecordingUiPort` fake and pure trace assertion helpers; retain root compatibility aliases.
- [x] Leave all tests and runtime business rules untouched.
- [x] Initial CI: native/release builds and tests were successful on Linux/macOS/Windows where configured.
- [ ] Resolve CI formatting and generated `.mbti` checks for the expanded migration.

## Follow-on work blocked by the no-test-change constraint

- [ ] Move the 10 root testkit implementation files to `src/testkit/`. Current root whitebox tests refer to `ScriptedModelStep` constructors (e.g. `Respond`, `Stream`), which are not re-exported simply by `pub using type`.
- [ ] Move `CoreVersionStore`, `CoreShadowRecording`, `AgentTaskRuntime`, `ChunkDispatcher` to internal packages. Current `_wbtest.mbt` files directly name their private types and constructors, which would cease to be same-package members.
- [ ] Move `AgentRuntime` as an indivisible package transition. The main package currently owns private state and methods spanning several files; an internal package cannot import the root Facade without creating a cycle.
- [ ] Record reproducible cold/warm build timing, native benchmarks and platform profiling on pinned toolchain/OS hardware.
- [ ] Verify consumers of `Agent::with_runtime` and generated `.mbti` compatibility before shrinking public types.

## Required gates

```sh
moon check --target native --output-json
moon test --target native --output-json
moon test --release
moon fmt
moon info
moon bench --target native --release
```

**Scope accounting:** This document is an honest ledger, **not** a claim that the full architecture checklist has been completed. Completing the remaining moves without touching the existing whitebox tests requires preserving old private implementations, weakening package encapsulation, or introducing additional compatibility infrastructure. Do not mark a gate complete without evidence.
