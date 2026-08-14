# Posoco quickstart

This is a complete, no-network MoonBit executable. It uses only the stable
public `Agent(exts~, config~)` API and public extension ports:

- `QuickstartModel` implements `ModelPort` and returns one fixed completion.
- `QuickstartSessionStore` implements `SessionStore` in memory.
- `QuickstartExtension` implements `Extension` and publishes both ports from a
  production-style `ExtensionManifest`.

The model has no API key and performs no HTTP request. The local `moon.work`
resolves `colmugx/posoco` to this checkout's repository root (`../..`), so the
example can be checked and run without fetching Posoco from a registry.

From the repository root:

```bash
rtk moon -C examples/quickstart check --target native --output-json
rtk moon -C examples/quickstart test --target native --output-json -f 'quickstart_persists*'
rtk moon -C examples/quickstart run --target native .
```

The focused test also verifies that the saved session contains both the user
message and the assistant response.

The executable prints:

```text
Hello from the Posoco quickstart.
```

The example keeps errors visible. `Agent` composition still raises typed
`CompositionError` values for invalid manifests (for example, a missing model,
missing session store, or tool collision), and the fixed model's unsupported
`compact` operation raises `ModelError::ResponseParse` instead of silently
falling back.

See [`main.mbt`](main.mbt) for the full implementation.
