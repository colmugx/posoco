# Posoco Agent Guide

This is a [MoonBit](https://docs.moonbitlang.com) project: **`colmugx/posoco`** — an LLM agent framework using hexagonal (ports-and-adapters) architecture. Depends on `moonbitlang/async`.

## One-Line Summary

Posoco exposes `Agent` as its stable high-level deep module: products compose
`Agent(exts, config)`, while Agent internally owns one long-lived Puppet backed
by a functional Kernel. The supported `Agent::resume_turn(session_id,
continuation?)` entry recovers a persisted interrupted turn without exposing
Puppet or Kernel internals.

## Developer roles and trust boundary

- **Posoco core developers** own reliable data flow, invariants, the Agent deep
  module, and the small set of public hexagonal ports needed by extensions.
- **Community extension developers** implement those public extension ports;
  they do not modify or couple to Posoco internals.
- **Agent developers** compose `Agent(exts, config)` and use its high-level API
  without learning Puppet or Kernel internals.
- **Customers** consume products powered by Posoco and should be able to trust
  their reliability; internal complexity must not leak into product APIs.


## Commands

```bash
moon check --output-json   # type check (also runs in pre-commit hook)
moon test --output-json   # full suite; see note below
moon test --update         # refresh snapshots
moon fmt                   # format all code
moon info                  # update .mbti generated interface
```

> **IMPORTANT**: All `moon check`/`test`/`build` commands MUST use `--output-json` so diagnostics are machine-readable and test counts are captured.

## Mock Pattern for Tests

Root tests exercise the same high-level interface used by agent developers;
their fakes live in the internal package `colmugx/posoco/internal/test_support`
(root `wbtest` only — products, tutorials and other modules bring their own
fakes). Build extension manifests with `tk_ext`, then compose one Agent:

```moonbit
let model = @test_support.ScriptedModel([
  @test_support.ScriptedModelStep::Respond(
    @test_support.tk_stop_response("hi"),
  ),
])
let tools = @test_support.RecordingToolProvider([], Map::from_array([]))
let store = @test_support.RecordingSessionPort()
let observer = @test_support.RecordingObserver()
let agent = Agent(
  exts=[
    @test_support.tk_ext(id="model", model=Some(model)),
    @test_support.tk_ext(id="tools", tools=[tools]),
    @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
  ],
  config=agent_config(max_tool_rounds=Some(10)),
)
let result = agent.run_turn(@test_support.tk_user_msg("hello"), "session_1")
```

## Rules

- Before starting work, load the `moonbit-agent-guide` skill (per the instruction at the top of this file); load `moonbit-orientation` when you need more MoonBit documentation or toolchain detail.
- Please ensure you haven't included redundant or overly abstract comments. Avoid comments that provide zero value for handoffs—especially documenting self-explanatory functions or stating the obvious (e.g., explaining why there are eggs in tomato scrambled eggs). KEPP FILE SIMPLE.
