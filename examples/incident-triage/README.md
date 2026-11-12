# Incident triage — an on-call Agent

**Scenario:** A production checkout API starts failing. An on-call assistant
inspects service health, files an incident report, and summarizes the result.
The example demonstrates a **real Posoco Agent turn with multiple model/tool
round trips**, not a UI application.

Run from the repository root, offline:

~~~bash
moon -C examples/incident-triage check --target native --output-json
moon -C examples/incident-triage test --target native --output-json
moon -C examples/incident-triage run --target native .
~~~

Expected output:

~~~text
diagnostic: checkout API error rate 17%
report: INC-1042 created
~~~

## Walkthrough

1. The scripted `ModelPort` proposes `inspect_service`.
2. Posoco resolves the tool definition and invokes `ToolProvider::execute`.
3. The next model step proposes `file_incident`; that tool is declared
   `Exclusive` because writing an incident is an explicit side-effect boundary.
4. The final model step returns a summary and finishes the turn.
5. The smoke test verifies the **actual provider execution order** and two
   tool outcomes, rather than treating a model-generated tool request as
   successful execution.

The scripted model deliberately makes the flow deterministic. To connect real
providers, replace it with your preferred `ModelPort` and implement the
monitoring/ticketing tool adapters. All error percentages and ticket IDs in
this example are mock data; the demo performs **no real monitoring or ticket
writes**.

See [tool execution policy](../../src/kernel/domain_tool.mbt).
