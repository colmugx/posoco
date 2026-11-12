# Posoco Agent examples

These examples are separate, runnable **MoonBit Agent applications**. Each
has its own `moon.mod`, `moon.pkg`, `moon.work`, `main.mbt`, README,
and smoke test. They resolve the local Posoco checkout through `moon.work`.

Each example runs offline without an API key. The tiny scripted `ModelPort`
keeps runs reproducible, while Posoco handles the actual Agent lifecycle,
tool scheduling, policy gates and tool-catalog management.

| Example | Agent application | Runtime behavior |
| --- | --- | --- |
| [quickstart](quickstart/) | First Agent | Model/session/event composition |
| [incident-triage](incident-triage/) | On-call incident response | Multi-round model/tool execution, sequential investigation and exclusive write |
| [approval-gate](approval-gate/) | Deployment release assistant | Reject a proposed tool call before any execution; approve and execute exact action |
| [live-tool-swap](live-tool-swap/) | Commerce checkout assistant | Publish a replacement tool implementation without restarting the Agent |

## Run the samples

From the repository root:

~~~bash
moon -C examples/incident-triage run --target native .
moon -C examples/approval-gate run --target native .
moon -C examples/live-tool-swap run --target native .
~~~

Check and test independently:

~~~bash
for example in incident-triage approval-gate live-tool-swap; do
  moon -C "examples/$example" check --target native --output-json
  moon -C "examples/$example" test --target native --output-json
done
~~~

All external systems are intentionally simulated. These samples demonstrate
the Agent runtime boundary; they are not production monitoring or deployment
integrations. For the stronger in-flight version-pinning guarantees, see
[dynamic tools](../docs/06-dynamic-tools.md).
