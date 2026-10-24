# posoco/ears

**posoco/ears is the SDK for inline code and live code** — the MoonBit
programs an agent submits directly as tool calls (`code` bodies and complete
`.mbtx` scripts alike). Guests reach back into the host through it.

Guest-side MoonBit SDK for calling Posoco host capabilities from a program.
The host passes only the run-scoped connection: a guest is a complete
`.mbtx` program — its own imports, its own `main` — that imports this
version-pinned package and calls `serve`. The host never injects source,
so compiler line numbers are the program's own.

## Guest contract

```mbt nocheck
import {
  "posoco/ears@0.1.0" @ears,
  "moonbitlang/async",
}

async fn main {
  @ears.serve(
    wire=@ears.stdio(),
    run=(ears, input) => {
      let outcome = ears.call("read", { "path": "README.md" })
      if outcome.is_error {
        fail("ears: read failed")
      }
      { "echo": input }
    },
  )
}
```

- Tool failures are **values** (`Outcome::Failure`); only transport loss
  raises. Branch on `is_error` / match the constructors.
- Capability decisions stay in the host: the invoke frame declares the
  allowed names, and `Ears::call` refuses anything outside it locally
  (`CapabilityDenied`) without touching the wire.
- `fail(...)` in the guest program becomes a failure result frame
  (`GuestFailed`), not a crash.

## Wire

Line-framed JSON over stdio, protocol 1: the guest sends
`hello`, `request`, `log`, and `result` frames; the host sends `invoke`
and `reply` frames. `Wire` is the transport seam; `stdio()` is the default.

## Examples

`examples/` holds small verified programs, one feature each — the same
patterns the system prompt teaches:

- `hello.mbtx` — smallest guest: serve one handler, echo the input.
- `branching.mbtx` — branch on the `Outcome`; `fail` becomes the failure result.
- `batched.mbtx` — the batching pattern: fan out, fold into one summary.

Each file type-checks against the published package (`moon run --build-only
--target wasm examples/hello.mbtx`); keep them compiling when the API moves.
