# Approval gate — ship or stop?

**Story:** A release bot proposes a production deployment. A policy owner can
reject its proposed tool call or explicitly consent to that exact action.
A rejected tool is **not executed**, while the Agent receives a regular tool
outcome and may continue reasoning.

Run from the repository root, offline (no API key required):

~~~bash
moon -C examples/approval-gate check --target native --output-json
moon -C examples/approval-gate test --target native --output-json
moon -C examples/approval-gate run --target native .
~~~

Expected output:

~~~text
REJECTED: no deployment tool executed
APPROVED: deployment tool executed once
~~~

## What happens

1. `DeployModel` requests a `deploy_release` tool through the regular Agent loop.
2. `DeploymentPolicy` implements `PipelineHook::before_tool`, returning
   `Reject` or `ApproveAfterConsent` for that call.
3. `DeployTools` counts **executed side effects**, not model requests.
4. The demo runs each policy in a fresh Agent to isolate scenario state.

The `approved` boolean stands in for an actual user approval prompt. Use a
real interactive permission/UI extension for production. Tool permission is an
Agent execution gate, **not** an OS sandbox. This demo does not perform a real
deployment.

Related contract: [PipelineHook](../../src/port/hook.mbt).
