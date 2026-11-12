# Live tool swap — upgrade an assistant in place

**Story:** A checkout assistant has a shipping price calculator. Operations
already completed under the standard calculator remain attributable to v1.
A shipping feature owner publishes v2 **without constructing another Agent**.
The next operation executes the new calculator.

Run from the repository root (offline, no API key):

~~~bash
moon -C examples/live-tool-swap check --target native --output-json
moon -C examples/live-tool-swap test --target native --output-json
moon -C examples/live-tool-swap run --target native .
~~~

The console shows the publishing ACKs and quotes:

~~~text
published shipping catalog revision 1
operation A: standard: $8
replaced shipping catalog revision 2
operation B: express: $12
~~~

## Why this matters

- The extension explicitly declares `Capability::ToolContribution` and
  receives an **owner-bound** `ToolContributions` handle.
- Each publish commits an atomically validated group with a revision ACK.
- The same Agent and model run two operations with different executor versions.
- The demo checks **actual tool executions**, rather than only reading the
  tool directory.

This sample intentionally replaces the provider **between** operations so the
behavior is easy to understand. Posoco also supports replacement *during* an
operation: the admitted operation retains its captured snapshot, and a later
operation adopts the new group. See [dynamic tools](../../docs/06-dynamic-tools.md)
for the stronger in-flight semantics.

This is an in-process educational sample, not an external feature-flag service.
