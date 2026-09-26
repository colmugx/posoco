# Changelog

## 0.16.2

### Fixed: task timeout classification survives adapter cancellation masking

`AgentTaskRuntime::execute` now wraps each task's `run` in a
cancellation-masking guard: `@async.pause()` on both the raise and the return
path of the runner (the same dual-guard pattern the extension-side background
runners already carry). An adapter that catches the incoming cancellation and
raises a typed error can no longer overwrite the task group's recorded
`TimeoutError` — TimedOut no longer degrades to Failed — and an adapter that
swallows the cancellation into a returned value no longer records a
completed-with-garbage task. Genuine business errors and normal completion are
unchanged: without a pending cancellation the pause is a no-op yield. Pinned by
`src/agent_task_wbtest.mbt` (`managed_tasks/timeout_survives_masked_raise`,
`managed_tasks/timeout_survives_masked_return`,
`managed_tasks/business_error_survives_cancel_guard`,
`managed_tasks/plain_completion_unaffected_by_guard`).

### Notes

- Removed the unused `colmugx/fuwaroid` dependency declaration from `moon.mod`
  (0.16.1 consumers pulled it into their dependency graph without linking it).

## Unreleased

### Agent 受管任务能力和结构化生命周期

Core 新增 Capability::Tasks、CompositionView::tasks()、TaskSpec、
TaskMode、Tasks、TaskHandle、TaskReceipt、TaskOutcome、TaskStatus 和
TaskSubmitError，并新增泛型 Agent::run_scoped(body : async (Agent) -> X)。
TaskSpec.run 返回 @kernel.Message；任务由 Agent scope 持有，Foreground 绑定
当前 operation，Background 绑定 Agent/session scope。Background outcome 在
同一 session 的下一次普通 run_turn 中投递；没有自动唤醒、自动 model turn
或 durable execution replay。

这是未发布变更，版本号不变。Capability 是可穷举的 pub(all) enum；新增
Tasks 变体会使下游对 Capability 的穷举 match 需要增加 Tasks 分支。下游若
直接构造 CompositionView::resolve，可继续使用其默认的 tasks? 参数；需要
任务能力的 Lifecycle contributor 必须在 manifest.requires 声明 Tasks，并在
on_compose 捕获 view.tasks()。旧 kit-actor 的 raw TaskGroup、bind_parent、
flush 和独立 pending registry 没有兼容保证，迁移说明见
docs/kit-actor/core-runtime-handoff.md。

**Retroactive note (appended in 0.16.2):** this section shipped as 0.16.0.
Adding the `Tasks` variant to the exhaustively matchable `pub(all) enum
Capability` is itself a breaking surface for downstream exhaustive matches (a
0.x minor-version breakage): every downstream `match` over `Capability` needs
a `Tasks` arm.

## 0.14.5

### `StreamAccumulator::tool_calls()` read accessor

Add `StreamAccumulator::tool_calls()` returning immutable `ToolCallSnapshot`
values (`id` / `name` / `arguments_json`; a fresh array per call) — restores
the read path closed by 0.14.4's field privatization while the write path
stays closed.

## 0.14.4

### Breaking: the pre_tool hook chain finalizes BEFORE authorization — rewrites are catalog-validated, consent binds to the exact call, and `call_id` is never rewriteable (2026-09-04)

Old order in `AwaitingTools`: parallel waves were scheduled from the model's
original calls first (owner, execution policy, barriers), then hooks ran
per-wave and could rewrite the call — so a rewritten tool executed with the
original tool's owner and wave policy, and a call that had already earned user
consent could be rewritten afterwards and still execute on that grant.

New order, per pending call: every hook runs first, each over its own deep
snapshot of the call (a hook that retains or mutates its input can no longer
reach the reducer's pending effect or an earlier consent snapshot); the whole
chain finishes; then catalog membership and argument-schema validation run on
the FINAL call, the owner is re-resolved for the final tool name, and the
reducer's pending effect payload is replaced with the finalized call — so
correlation checks, the transcript, and completion events all carry the
canonical request. Only then are waves scheduled and executed. Hook
rejections, `UnknownTool`, and `SchemaMismatch` (now checked against the
rewritten call) fold through the normal reducer path before any side effect
launches.

- A hook that changes `call_id` rejects the whole run (`HookRejected`:
  `"pre_tool_hook changed call_id for a pending tool call"`) — the call id is
  the reducer's correlation identity, never a rewriteable part of the request.
- `ApproveAfterConsent` authorizes exactly the call it carries. A later
  consent may intentionally authorize a new call; a later plain `Approve` that
  changes the call after consent invalidates the grant — the call resolves as
  `NotExecuted(RejectedByHook("tool call changed after consent; authorization
  was not reused"))`.
- `Reject` still does not short-circuit (a later consent outranks it), and
  `Defer` keeps its frozen terminal-reject wording until M5.

### Observers see the canonical executed call on completion events

`KernelEvent::ToolCompleted` carries the full post-rewrite `ToolCall` instead
of a bare `call_id`; the agent projection no longer looks the model's original
pending call back up. Pending/batch-start events still report the model's
original request, while completion events (`tool_call_result`) report the call
that actually reached the host — including `NotExecuted` outcomes, which carry
the finalized name and arguments. Durable diagnostic payloads intentionally
exclude call arguments, and `NotExecuted(RejectedByHook)` summaries no longer
expand the full reason text.

### Breaking: provider stream chunks are validated before they reach any sink

- `Usage::validate` (kernel) is the single canonical usage invariant: every
  field is optional because providers omit different dimensions, but a
  reported count must be non-negative. `StreamChunk::validate` (types) applies
  it to `Usage` chunks and rejects negative tool-call indexes.
- `StreamAccumulator` fields are private (it was `pub(all)` — any package
  could mutate the live buffers mid-stream), `push` now raises
  `ModelError::ResponseParse` on invalid chunks and on sparse tool-call
  indexes (a new index must be exactly the next contiguous 0-based index;
  existing indexes may be revisited), and `to_completion` validates the
  accumulated usage even when `total_tokens` is absent (the old projection
  silently discarded a negative field).
- The executor wraps the host chunk callback with the same checks: an invalid
  chunk, and every chunk after it, is never forwarded to the Posoco
  sink/observer/accumulator/reducer; when the provider call returns, the
  effect completes as `ModelFailed(Parse("stream chunk validation failed:
  ..."))`. `HostChunkCallback` is a non-raising ABI, so a malformed chunk
  cannot interrupt provider-owned work. A host raise (transport error,
  cancellation) still classifies as an execution error — a malformed callback
  observed before the raise never reclassifies it.
- `reduce_model_completed` re-validates usage on its direct-input path, so a
  caller bypassing the host runtime cannot make `observed_total_tokens` move
  backwards.

**Migration (breaking):** SSE-style model adapters that call
`StreamAccumulator::push` directly (posoco-ext-openai, posoco-ext-zai) must
now handle `ModelError::ResponseParse`; struct-literal construction or field
access on `StreamAccumulator` no longer compiles.

### Breaking: `Agent::control()` returns the root-package `AgentControl`; `RuntimeControl` is deleted

The old `@runtime.RuntimeControl` exposed a borrowed internal
`puppetry.Mailbox` in its public shape — an internals leak across the product
boundary. The handle now lives in the root package with a private constructor:
hosts obtain it only from `Agent::control()` and see the same surface
(`active_run_id` / `active_turn_id` / `enqueue_follow_up` / `abort_active` /
`pending_follow_ups`); `take_follow_up` was framework-only and is now private
(the Agent drains follow-ups inside `run_turn`). The `runtime` package no
longer imports `internal/puppetry`.

`EnqueueOutcome` gains `RejectedQueueFailure(reason~ : String)`: a closed or
failing follow-up queue is no longer misreported as `RejectedQueueFull`; the
reason carries the sanitized queue error.

**Migration (breaking):** replace `@runtime.RuntimeControl` references with
`AgentControl` obtained from `Agent::control()`, and add a
`RejectedQueueFailure` arm to every `EnqueueOutcome` match.

### `run_turn` is re-entrancy guarded; transcript-save failures are observable

A second concurrent `run_turn` on one Agent raises
`Runtime(InvocationFailed("agent turn busy"))` — the synchronous guard is
acquired before the first await and covers the initial turn plus every
follow-up drained by that call, and is released when the call leaves with a
result or an error. Terminal-transcript save failures are no longer silently
swallowed on the failed-turn path: the existing `secondary_failure` observer
event fires (`hook_point="failed_turn_transcript_save"`) with the sanitized
session label, the operation (`final_append` / `final_save`), and the error
category; the original raise still propagates unchanged.

## 0.14.3

### Breaking: `MemoryPort` inbound redesign — `briefing` becomes `inbound(session_id, request)`, `MemoryEntry`/`MemoryQuery` deleted, injection gated on an empty transcript, and core auto-registers `memory_search`/`memory_add` (2026-09-01)

The port's inbound slot no longer takes only a session id: `inbound` now also
receives the user's first request text, so a provider can recall memory that is
relevant to what the session is actually about instead of returning a static
brief. The storage surface simplifies accordingly — `MemoryEntry` and
`MemoryQuery` are gone; `store` takes `content` + `metadata` and returns the
provider id or ticket, `search` takes a free-text `query` + `top_k` and returns
the provider-rendered text (`None` = no hits), and `MemoryError` gains an
`Inbound(String)` variant.

```moonbit
pub(open) trait MemoryPort {
  async fn inbound(Self, session_id~ : String, request~ : String) -> String? raise @error.MemoryError
  async fn store(Self, content~ : String, metadata~ : Map[String, Json]) -> String raise @error.MemoryError
  async fn search(Self, query~ : String, top_k? : Int) -> String? raise @error.MemoryError
  async fn delete(Self, id : String) -> Unit raise @error.MemoryError
}
```

Injection semantics changed with it. `MEMORY_BRIEFING_LEAD` is replaced by
`MEMORY_INBOUND_LEAD`, and the old marker-line gate is gone: core calls
`inbound` at most once per session per process, ONLY when the loaded transcript
is empty (the session's first turn), passing the session id and the user's
first request. All providers empty/failed → no message at all; any content →
ONE user message (`MEMORY_INBOUND_LEAD` + provider bodies joined verbatim in
registration order) inserted before the real first user input, frozen into the
persisted transcript — never rewritten, never re-read on resume; an empty or
failed result still spends the attempt. Provider failures and per-provider
timeouts surface as `Custom(source="posoco.core", label="secondary_failure")`
observer events (hook points `memory_inbound` / `memory_search`) and never fail
the turn. The internal `MemoryBriefingHook` is deleted — injection is an
Agent-internal pre-pump step, and no marker-string matching remains in core.
New `AgentConfig.memory_inbound_timeout_ms : Int?` bounds each provider call
(`None` = no core budget; the provider self-limits).

When any extension contributes a `MemoryPort`, core auto-registers two builtin
agent tools: `memory_search` (fans out over all providers, results appended in
registration order, all-empty → "No matching memory.") and `memory_add`
(`content` + optional `source` = manifest id; omitted source saves to every
connected provider; receipt lines `<source>: <id|ticket>`). They go through the
same fail-fast `ToolCollision` as extension tools — an extension that also
declares a tool named `memory_search` or `memory_add` fails composition, so
providers should drop their generic memory tools and keep specialized ones.
There is no `memory_delete` tool; `delete` stays a passive port slot for
product-side logic.

**Migration (breaking):**

- `MemoryPort` implementors: rename `briefing` → `inbound` (now also receives
  the first request text), switch `store`/`search` to the new signatures, and
  render your own `search` output — core no longer formats entries.
- Extensions that shipped their own generic `memory_search`/`memory_add`
  tools: drop them (core now provides both) or rename them.
- Anything matching on `@posoco.MEMORY_BRIEFING_LEAD` has nothing to match
  anymore — the injected message is never rewritten or re-derived, so no
  marker is needed.

**Testkit**: `ScriptedMemoryPort` plays `inbounds : Array[String?]` in call
order (exhausted → `None`) and records `call_count` / `received_sessions` /
`received_requests` / `received_stores` (content+metadata pairs) /
`received_searches` ((query, top_k) pairs) / `received_deletes`; store tickets
are `"scripted-N"` and `search_script` plays search output in order.

### Breaking: `InvocationScope` gains a context-pressure advisory — struct literals must add `pressure`

Posoco already resolves the effective `context_window` / `compact_threshold`
per turn (host config > provider report > 0.88 default) and tracks the
latest verified occupancy (`last_context_tokens`). `Puppet::handle_compact`
now attaches all three to the compact `InvocationScope`, so modelports size
their compact strategy from real numbers instead of re-estimating from
characters. The chat effect path attaches `None`.

```moonbit
pub(all) struct ContextPressure {
  window_tokens : Int?      // resolved ceiling; None = unknown
  occupancy_tokens : Int?   // latest model step's verified total; None = no reading
  compact_threshold : Double
}
```

Migration: every `InvocationScope` struct literal must add the field
(`pressure: None` where no reading applies); `tk_scope` gained an optional
`pressure?` parameter. The advisory is read-only input —
`ModelPort::chat` / `ModelPort::compact` signatures are unchanged, and
modelports that ignore it behave exactly as before.

## 0.14.0

### Breaking: `MemoryPort` is now the long-term-memory storage & retrieval port — original `store`/`search`/`delete` restored, plus one new inbound slot (`briefing`) injected once per session by core

The old `MemoryPort` kept the durable surface (`store`/`search`/`delete`) but
coupled core to a per-call retrieval model that had no correct consumer: the
built-in `MemoryRetrievalHook` re-searched on every turn and rewrote the
injected system message in place — a resumed session got a *different* memory
section under history that was derived under the old one (dangling
references), and the rewrite poisoned the provider prefix cache for the whole
conversation.

The redesigned port keeps the domain intact and adds exactly one slot for
getting memory INTO the conversation:

```moonbit
pub(open) trait MemoryPort {
  async fn briefing(Self, session_id : String) -> String? raise MemoryError
  async fn store(Self, entry : MemoryEntry) -> String raise MemoryError
  async fn search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  async fn delete(Self, id : String) -> Unit raise MemoryError
}
```

`store`/`search`/`delete` are the durable record surface — the provider's own
tools, products, and future generic tooling all route through them, so the
operation lands in whichever memory system is plugged in (nowledge-mem today,
any other scheme tomorrow) without the caller knowing which one. When a write
becomes durable is the provider's business: a provider may hand back a
pending ticket and defer.

`briefing` is the inbound slot. The provider owns ALL of its content —
format, envelope, provenance markup (devkit's `context_envelope` renders
XML-style envelopes for those who want them); core never touches the returned
text. Core owns timing, placement, and stability:

- Declaring `memory` in an extension manifest is all a host does. Core's
  internal `MemoryBriefingHook` (replaces the public `MemoryRetrievalHook`)
  injects the briefings as ONE **user-role** message directly after the
  leading system prompt (at the front without one), opened by core's fixed
  lead line — the one sentence of memory-specific text core ever produces
  (`pub const MEMORY_BRIEFING_LEAD`,
  `"The following is memory about the current work:"`). Provider bodies
  follow verbatim, in registration order: no escaping, no wrapping.
- **Once per session lifetime, frozen into the transcript.** Later turns,
  tool rounds, and resumed processes all see the same message
  byte-for-byte: the lead line in the persisted transcript is the durable
  half of the gate (and the format-neutral marker extensions can match on),
  a per-session attempted set the in-process half (empty and failed reads
  spend the attempt — a resumed process retries once). The Agent hands the
  hook the running session id each turn, so the gate cannot mis-order
  against the pump.
- **Prefix-cache safe**: with the briefing message already present the hook
  returns the same array instance (no rewrite, no journal noise).
- `briefing` runs concurrently across providers (`@async.all`); a raise is
  swallowed into the existing `secondary_failure` observer event
  (`hook_point="memory_briefing"`), never aborting the turn.

**Migration (breaking):**

- `MemoryPort` implementors: keep your `store`/`search`/`delete`
  implementations (same signatures as 0.13.x) and add the `briefing` slot
  returning the complete message body you want the model to see at session
  open. `source_name` is gone — self-describe inside your briefing body
  instead.
- `MemoryQuery` is restored unchanged (`query`/`top_k`/`threshold`/`filter`);
  `MemoryRetrievalHook` and `NoopMemoryPort` stay removed. The injected
  memory moved from a `## Any Memory About This Work` system section to the
  lead-lined user message described above; extensions that need to recognize
  the injected message match on `@posoco.MEMORY_BRIEFING_LEAD`.
- Extensions pinned to `colmugx/posoco@0.13.x` keep compiling unchanged.

**posoco-ext-nowledge-mem** now implements the port in full:

- `manifest.memory = [self]` again; `briefing` returns the extension's own
  `<nmem-context type="memory" trust="false">` envelope around the
  working-memory snapshot (one 5s read, failures recorded on
  `mem.last_error`) — core owns position, idempotency, and resume stability.
- `store`/`delete` are the D8 write-after queue (the public
  `queue_memory_add`/`queue_memory_delete` methods fold into the slots), and
  `memory_add`/`memory_delete` route through the port. `delete` of a
  `pending:` ticket now drops the queued add locally — the old direct-call
  `memory_delete` tool would have sent the ticket id to the server.
- `search` is real retrieval against the server's `memory_search` surface
  (`top_k` → `limit`, `filter` carries `mode`/`labels`), and the
  `memory_search` tool fronts it: entries render one line each with the
  parsed array on the `structured` channel.

**Testkit**: `ScriptedMemoryPort(briefings~, search_results? = [])` fake
(`call_count`/`received_sessions`/`received_stores`/`received_searches`/
`received_deletes`) for agent-level tests of the whole port contract.

## Unreleased

### Breaking: openai-compatible speaks the standard wire; opencode-zen self-hosts its GLM flavor (2026-09-03)

Vendor-defined request fields now live in the vendor extensions that define
them. `posoco-ext-openai-compatible` emits only standard OpenAI Chat
Completions fields (the sole reasoning surface is the top-level
`reasoning_effort` string); the GLM-flavored `thinking` object and the
`reasoning_content` assistant echo moved into `posoco-ext-opencode-zen`, whose
upstream gateway requires them. Zen users' request bytes are unchanged; strict
standard endpoints (AMD Radeon Cloud 400s on `thinking`) now work through the
generic adapter.

**posoco-ext-openai-compatible** (0.1.1 → 0.2.0)

- Requests never send `thinking` (not a standard parameter) and assistant
  messages never echo `reasoning_content` (standard messages carry no
  reasoning back; this also keeps prompts prefix-cache friendly).
- `reasoning_effort` is sent verbatim when a level is selected and omitted
  otherwise; omission means "endpoint default", which is also what "off" and
  the legacy "on" settings word now map to (the standard has no force-on
  field).
- `OpenAICompatibleConfig` drops the `thinking : Bool` field; setups without
  declared levels no longer advertise an off/on picker — declare
  `reasoning_effort(s)` levels to expose one.
- Known limitations (README): servers returning reasoning text under the
  OpenRouter/Radeon `reasoning` spelling get no reasoning display (vendor
  spelling, vendor extension's job); gateways that silently drop unknown
  parameters (Radeon) may not report streaming usage.

**posoco-ext-opencode-zen** (0.1.1 → 0.2.0)

- Self-hosts the full chat wire (encode, decode, HTTP/SSE loop, error
  classification, wire log) previously reused from
  `posoco-ext-openai-compatible`; the dependency is replaced by
  `posoco-kit-chat-completions`.
- New public types `OpenCodeZenConfig` and `OpenCodeZenModelPort`
  (`zen_static_catalog`/`zen_model_catalog` now take the local config type).
- Error-message prefixes changed from `openai-…` to `opencode-zen …`; the
  retry matcher substrings (`SSE truncated`, `stage=read_stream`,
  `status=503`) are unchanged.

**Migration (breaking):**

- Pin both packages at `0.2.0` (cetas-core updated in this change).
- Drop `thinking~` from direct `OpenAICompatibleConfig` constructions; code
  that needs the GLM thinking object or the reasoning echo must use
  `posoco-ext-opencode-zen`.
- Custom providers through the generic adapter lose the off/on reasoning
  toggle unless they declare effort levels.

### Bounded, pruned file tools: grep output modes + caps, glob limit + mtime sort, shared ignore infrastructure

The file tools (`grep`, `glob`) no longer emit unbounded output and both prune
hidden entries and common ignore directories, so the worst-case turn cost is
capped and everyday searches stop pulling in `.git`, `node_modules`, `_build`,
and build-artifact duplicates.

**posoco-ext-grep**

- New optional arguments: `output_mode` (`content` (default) |
  `files_with_matches` | `count`), `case_insensitive` (bool), `max_matches`
  (entry cap, default 100). Content mode now groups matches by file
  (`Found N matches in M files:` + `  L<n>: <line>` entries) instead of
  repeating `path:` on every line. Any cut result ends with a
  `… N more …` footer; the structured payload gains `truncated`.
- Lines longer than 2000 characters are truncated with a marker (matching
  read), and the body is additionally capped at 100 KB.
- Literal matching is now explicit cross-target: native always was
  `contains`-based; js pins rg with `-F` instead of rg's regex default, so
  patterns like `foo(` behave the same everywhere. Empty patterns are
  rejected loudly.
- Hidden entries and ignore directories are pruned on both engines; binary
  files (by extension, NUL sniff, or failed decode) and unreadable files are
  skipped instead of aborting the whole search.
- js engine ladder: ripgrep first — PATH via `Bun.which` plus the common
  Homebrew prefixes, each candidate validated via `rg --version` (rejects a
  grep shim masquerading as `rg`); when no real rg is found, an in-process
  `node:fs` walker with the same semantics takes over. rg output is parsed
  NUL-separated (`--null`), safe against `:` in filenames.
- `GrepTools::GrepTools` gains an optional `ignores` parameter (default
  `@devkit.default_ignore_patterns()`).

**posoco-ext-glob**

- Returns file paths only (never directories), sorted by modification time
  newest-first (path ascending breaks mtime ties). Hidden entries and ignore
  directories are pruned on both engines.
- New optional `limit` argument (default 100); truncated listings end with a
  `… N more files` footer and the structured payload gains `truncated`.
- `GlobTools::GlobTools` gains an optional `ignores` parameter.

**posoco-ext-read**

- A file that is not valid UTF-8 now fails with
  `read: '<path>' is not valid UTF-8 (binary file); use grep or bash to
  inspect it` instead of the generic `decode failed` message.

**posoco-devkit**

- New shared traversal helpers used by the file tools:
  `default_ignore_patterns`, `matches_ignore`, `has_hidden_segment`,
  `glob_match` (`*` per segment, `**` recursive), `relative_to_base`,
  `strip_dot_prefix`, `truncate_chars`.

The grep/glob output format changes are model-visible; hosts that snapshot
tool output or prompt against the old `path:line:content` flat format need to
re-baseline.


## 0.13.0

### Breaking: system prompt assembly is lazy, stable, and short-circuits on empty

`SystemPromptHook` now assembles the system prompt once per Agent lifetime, on
the first `before_model` of the first turn, and caches the result for reuse. The
assembled bytes are stable so LLM provider prefix caches remain valid.

When assembly produces an empty result, the hook now returns the original
messages unchanged instead of injecting an empty `SystemMessage`. Previously an
empty result would replace any existing system message at index 0, so an idle
extension could wipe the host's system prompt.

The assembled prompt has the form: the base text from the new
`AgentConfig.system_prompt` field, followed by contributor sections in
registration order, each formatted as `{id}:\n{text}`, separated by blank lines
(`\n\n`), emitted as a single `SystemMessage`. Index-0 handling is now
self-healing: if the existing message at index 0 is a `SystemMessage` with
identical text it is kept; if the text differs it is replaced; otherwise the new
system message is inserted at the front.

`AgentConfig` gains a new field `system_prompt : String?` with no default. Hosts
that construct `AgentConfig` with struct literals must add `system_prompt: None`
(or a base prompt string).

`SystemPromptContributor` contracts are tightened: returned text must be
byte-stable across calls. Dynamic mode indicators (such as plan mode) must now
be injected per turn as a user message via `PipelineHook.before_model`, not
through `SystemPromptContributor`. Migrations for external extensions
(`posoco-ext-plan`, `posoco-ext-goal`, `posoco-ext-permission`, etc.) will
follow separately; this CHANGELOG entry covers core only.

## 0.12.0

### Breaking: streaming protocol and ModelPort message borrowing

`@posoco.StreamMode::Stream((StreamChunk) -> Unit)` now receives the canonical
`@posoco.StreamChunk` type directly; the old `(Json) -> Unit` callback contract
is removed. `HostChunkCallback` is typed likewise. This eliminates the
same-process JSON encode/parse/allocate cycle that ran for every chunk with zero
wire benefit.

`ModelPort::chat` and `ModelPort::compact` now receive
`messages : ArrayView[@kernel.Message]` (a borrow valid only for the duration of
the call; adapters must not retain it). The same change applies to the internal
`HostRuntime::call_model`/`compact` correspondence and to the public advanced
`Runtime` seam. Adapters that need to keep the messages beyond the call should
use `.to_owned()`; adapters that only read once can iterate the view in place.

`StreamAccumulator` internals switched to `StringBuilder`; the `text`,
`reasoning`, and `ToolCallBuilder.arguments_json` fields are now private. Use
the getters `acc.text()`, `acc.reasoning()`, and `tc.arguments_json()`.

A new `@posoco.TurnEvent` variant `StreamChunksDropped(count~ : Int)` is emitted
when the chunk telemetry queue overflows under backpressure. It is non-terminal
and telemetry-only, but exhaustive matches over `TurnEvent` must add the new
arm. See `docs/migrations/2026-08-stream-protocol.md` for the full migration
guide.

### Performance: streaming, reducer, hook, and memory retrieval

Headline numbers, measured on native release on the same machine before and
after this release (full table and methodology:
`docs/perf/2026-08-25-ultraspeed-baseline.md`):

- **StreamAccumulator StringBuilder rewrite — ~500x on accumulation hot
  paths.** 100k × 4-char streamed text deltas: ~498 ms → ~1 ms; tool-call
  argument accumulation at the same volume: ~488 ms → ~1 ms. Both paths were
  quadratic in accumulated length; they are now amortized O(1).
- **Bounded chunk telemetry — ~6x wall time and ~50x observer-event volume
  under chunk floods.** A 50k-chunk streaming turn went from ~6 ms / 50,003
  observer events to ~1 ms / 1,028 events. Per-turn capacity 1024 with
  drop-oldest and a drain task that flushes chunks before committed/terminal
  events; slow observers no longer throttle the provider read loop. Under
  overload the telemetry stream is intentionally lossy (signalled via
  `StreamChunksDropped`).
- **Reducer commits tool results once per wave** — one O(N) transcript
  commit per wave in source order, instead of K O(K·N) rebuilds per wave.
  Journal boundary semantics and the BASELINE counters (2/4/7) are unchanged.
- **`before_model` hook fast path** — the chain skips the O(N) array
  comparison when a hook returned the physically same array
  (physical-equal short-circuit).
- **`MemoryRetrievalHook::search_all` now queries memory ports concurrently**
  via `@async.all`; results are merged in registration order and per-port
  failures are reported through `on_failure`.
- **Session persistence scales with bytes appended, not history size** —
  pure-append turns save through `SessionStore::append_messages` (below)
  instead of a full load + save of the whole transcript.

### Added: `SessionStore::append_messages` and selective append saves

`SessionStore` gains `append_messages(id, from_index, messages :
ArrayView[@kernel.Message])` with a default load-concat-save fallback. The Agent
now calls `append_messages` when a turn was a pure append (a per-session
persisted cursor tracks the boundary), and falls back to a full `save` after
compact/fork/rewrite. Multi-store writes are now executed in parallel via
`@async.all`.

### Core: memory injection renders a plain provenance-tagged section; `MemoryPort` gains `source_name`

The built-in `MemoryRetrievalHook` replaces the legacy `[MEMORY]` line-list
format with a system-prompt-style section: a `## Any Memory About This Work`
header, a provenance line `from {source}. For Your Information.` (recalled
memory may be stale and must not override live instructions), then one
`- {content}` line per entry. `MemoryPort` gains `source_name` (default
`"memory"`) — protocol-level self-description, so the provenance line names
each contributing port without any branding in core. Idempotent
replace-in-place detection now matches the section header prefix. Envelope
rendering leaves core entirely: `render_context` and
`AgentConfig.context_namespace` are removed (breaking — drop the
`context_namespace` config field; the host owns its envelope).

### Core: `Hook::on_turn_end` — async turn-end slot (public API)

`Hook` gains a defaulted `async fn on_turn_end(Self, outcome : TurnEndOutcome)
-> Unit`. The Agent awaits it once per `run_turn`, after the terminal
observer projection (`TurnCompleted` / `TurnFailed`) and before the call
returns — on both the completed and the failed path — making it the slot for
side effects that must land by turn end, such as committing buffered writes
to an external system. `TurnEndOutcome` (`Completed` / `Failed(reason~)`)
labels the terminal state; the reason is the sanitized category label the
observers already saw in `TurnFailed`. A raise is a secondary failure —
reported to observers as `secondary_failure(hook_point="on_turn_end")`,
never replacing the turn's primary outcome — and cancellation is not a
defect. Non-breaking: the default implementation is a no-op, existing hooks
are unaffected.

### Model context window crosses the ModelPort seam; auto-compact is occupancy-based

`ProviderConfig` (a modelport's self-description) gains two optional fields:
`context_window : Int?` and `compact_threshold : Double?`. The Agent now reads
the active modelport's `provider_config()` **per turn** and sizes auto-compact
from it — precedence is defined exactly once: host `AgentConfig` override >
provider report > core default. `AgentConfig` gains `compact_threshold` in
(0, 1]; the previously hardcoded 0.9 default becomes **0.88**. `/model`
switching takes effect on the next turn without recomposing the Agent.

Auto-compact semantics (`Puppet::check_auto_compact`) now compare the
**latest verified context occupancy** — the most recent model step's
`total_tokens` (else `input + output` when both are reported) — instead of the
run-wide cumulative total, so several large-but-far-from-full calls can no
longer sum into a false trigger (`max_total_tokens` keeps policing the
cumulative account). After a compact rewrite the occupancy is unknown until
the next reliable reading, and each run gets at most ONE auto-compact
attempt. An auto-triggered compact that fails (e.g. a modelport that does not
implement compact, or a transport hiccup) no longer kills the turn: the skip
is recorded and surfaces to observers as a
`secondary_failure(hook_point="auto_compact")` event; manual `/compact`
failures still fail loudly.

### Hook lattice: every hook votes; user consent beats gates

`ToolHookDecision` gains `ApproveAfterConsent(call~, consent_scope~ : String)`.
The pump no longer short-circuits on the first non-Approve decision: every
registered `before_tool` hook is evaluated and the decisions merge —

1. a hook raising stays terminal (`HookRejected` → `AgentError::HookAborted`);
2. `Defer` still terminal-rejects until M5;
3. any `ApproveAfterConsent` executes the call even if other hooks returned
   `Reject` — an explicit user decision outranks a gate's veto, so plan mode
   cannot block a call the user just allowed at a permission ask (and
   registration order no longer decides life or death);
4. otherwise any `Reject` skips the call and feeds the **joined** reasons
   back to the model as `NotExecuted(RejectedByHook)`.

Policy pre-approvals (permission read class, Yolo) intentionally stay plain
`Approve` and do NOT count as consent — under Yolo, plan-mode rules still
apply while planning, with the plan auto-accepted at exit.

### `before_tool` Reject is steering, not a run failure

A `ToolHookDecision::Reject` no longer aborts the run. The rejected call is
never dispatched to the executor; instead the pump resolves the pending
`ExecuteTool` effect with a `ToolOutcome::NotExecuted` result carrying the new
`NotExecutedReason::RejectedByHook(reason)` payload. The reason flows back to
the model as a normal tool message and the run continues on the next model
step.

- Composition gates (plan mode, permission) now redirect the model instead of
  killing the turn: e.g. in plan mode a rejected `bash` call comes back as
  feedback and the model steers to read-only tools — previously the whole turn
  died with `AgentError::HookAborted`.
- Terminal semantics are unchanged for the other paths: raising from
  `before_tool` still aborts as `HookRejected` → `AgentError::HookAborted`, and
  `Defer` still terminal-rejects until M5 lands real suspension.
- Public API: `NotExecutedReason` gains the `RejectedByHook(reason~ : String)`
  variant (additive; exhaustive matches on the enum must handle it).
- The `Hook::before_tool` doc contract now states this explicitly — extensions
  should treat `Reject` as model-facing steering text.

### Capability completion: declared consumption + three-phase Lifecycle

The manifest gains a consumption direction. Extensions no longer need
host-specific constructor injection to reach the composed model or UI (the
pattern previously hand-wired by `posoco-ext-askquestion`,
`posoco-ext-statusbar`, `posoco-ext-permission`, and `cetas-core`).

```moonbit
pub(open) trait Lifecycle {
  fn on_compose(Self, ctx : CompositionView) -> Unit raise @error.CompositionError = _
  async fn on_start(Self) -> Unit = _
  async fn on_shutdown(Self) -> Unit
}
```

- `ExtensionManifest.requires : Array[Capability]` (`Capability::Model |
  Capability::Ui`) declares which composed capabilities an extension
  consumes. `Lifecycle::on_compose` delivers a curated `CompositionView`
  after every composition gate has passed, gated on the declaration —
  undeclared capabilities read `None`; raise
  `CompositionError::ExtensionComposeFailed` (new variant) to fail the
  composition loudly with no partial Agent. `on_compose` is sync by design:
  async port calls are impossible there, so the type system enforces
  "wire, don't act".
- `Lifecycle::on_start` fires once per Agent lifetime inside the first
  `run_turn`, before the first `TurnStarted` — the legitimate birth point
  for persisted-state reload and background loops (construction has no async
  root). Both new methods have defaults; existing `on_shutdown`-only
  implementations are unaffected, and shutdown still drains in reverse
  registration order.
- The `CompositionView` is curated, not a service locator: it will never
  expose tool invocation (would bypass `Hook::before_tool`), session stores
  (state ownership), or observer-event emission (core-owned).
- **Breaking (narrow)**: `ExtensionManifest` gains the `requires` field.
  `ExtensionManifest::empty(...)` + struct-update syntax is unaffected; full
  struct literals must add `requires: []`. In-repo callers (READMEs,
  `external/extension/*` manifests, `cetas-core` tests, testkit `tk_ext`)
  are updated.
- Extensions calling the composed model outside a business run must mint a
  synthetic `InvocationScope` in their own namespace (`effect_id=None`,
  never a business session/run identity) — scope is the cost/telemetry
  attribution key. See `docs/EXTENSIONS.md` "Consuming composed
  capabilities".

### Capability completion: scoped observation (`EventScope`)

Observer and post-event hook dispatches now carry run attribution, so
extensions can correlate telemetry, cost, and diagnostics to the exact
session/run/turn that produced them — no re-parsing, no heuristics.

```moonbit
pub(all) struct EventScope {
  session_id : SessionId
  run_id : RunId
  turn_id : TurnId
}

pub(open) trait Observer {
  fn on_event(Self, event : TurnEvent) -> Unit = _
  fn on_event_at(Self, scope : EventScope?, event : TurnEvent) -> Unit = _
}

pub(open) trait Hook {
  // ... before_model / before_tool unchanged ...
  fn on_post_event(Self, stage : HookStage) -> Unit = _
  fn on_post_event_at(Self, scope : EventScope?, stage : HookStage) -> Unit = _
}
```

- The core dispatches ONLY the scoped variants; their defaults delegate to
  the legacy unscoped methods, so existing `Observer`/`Hook`
  implementations keep working unchanged (non-breaking).
- Scope guarantees: turn-lifecycle events (`TurnStarted`/`TurnCompleted`/
  `TurnFailed`), envelope-projected events (`ModelResponseReceived`,
  `ToolCallPending`, `ToolCallResult`, `SessionRedirect`), and post-event
  hook stages always carry `Some(scope)` — minted by the Agent before
  `TurnStarted`, so even the first event is attributable. Out-of-run
  diagnostics (`StreamChunkReceived`, `Custom` secondary failures) carry
  `None`.
- Pinned by `src/scope_projection_wbtest.mbt` (`scope_projection/*`).

### Kernel: declared `ExecutionPolicy` is honored

`build_agent_catalog` no longer pins every provider tool to `Parallel`; the
provider's declared policy flows into the catalog as M1-T06 always intended.
No behavior change for existing tools (they all declare `Parallel`); it lets
mutation tools opt into `Exclusive` so they never share a tool wave. Pinned
by a new catalog test.

### Tool-loop limit: unbounded by default, opt-in budget

The tool-loop limit moves to the posture used by peer coding agents:
**unbounded by default, opt-in budget**. Previously
`AgentConfig.max_tool_rounds` was a required `Int` — and an internal
mis-conversion (`max_iterations = rounds + 1` while the pump burns 2
iterations per round) silently halved the effective limit, so a "20-round"
budget killed turns after ~10 tool rounds. The kernel budget is now the sole
semantic gate; the pump iteration cap is a derived livelock backstop that
always lets the budget fire first.

### Breaking: `AgentConfig.max_tool_rounds` is `Int?`

`None` is unbounded (the recommended product default — the human abort and
compaction govern loop length); `Some(n)` allows n full tool rounds and
rejects the (n+1)-th batch atomically; `Some(0)` still forbids tool
execution. All literals need wrapping:

```moonbit
// before
{ max_tool_rounds: 10, .. }
// after
{ max_tool_rounds: Some(10), .. }
```

The budget check is now exclusive (`>` instead of `>=`), so `Some(n)` really
means n full rounds — previously the n-th batch was already rejected.

### Breaking: `AgentError::ToolLoopExceeded` carries `consumed~, limit~`

The variant now reports the round count at rejection and the configured
limit, and its message tells the caller how to raise the ceiling
(kimi-code style). Pattern matches need `ToolLoopExceeded(..)`. A pump
livelock backstop trip no longer masquerades as `ToolLoopExceeded` — it
surfaces as `AgentError::Runtime(InvocationFailed(..))`.

### Breaking: model-side calls take an `InvocationScope`

`ModelPort::chat`/`compact` and their `Runtime` correspondences
(`call_model`/`compact`) now receive the identity of the session/run they
serve as the first parameter after `Self`:

```moonbit
pub(all) struct InvocationScope {
  session_id : SessionId
  run_id : RunId
  effect_id : EffectId? // Some = CallModel effect; None = compact
}
```

This is the canonical answer to "which session is this call serving" for
adapters that key behaviour on session identity — continuity, telemetry, cost
attribution, per-session policy. `effect_id` is always `Some` for
`chat`/`call_model` (the reducer-allocated effect identity; hosts that
propagate cancellation key in-flight model calls by it, mirroring
`EffectContext.effect_id` on the tool side) and always `None` for `compact`
(host-driven, not an effect). Scope-agnostic adapters simply ignore the new
parameter; forwarding adapters (routers) must forward it unchanged.

Migration: add `scope : @posoco.InvocationScope` (or `_scope`) as the first
parameter of your `chat`/`compact` implementations, and of
`call_model`/`compact` for custom `Runtime` hosts. Testkit gains
`ScopeRecordingModel` (records per-call scopes) and `tk_scope()` for driving
a port directly in tests. The `posoco-101` tutorial pins the last published
release and will be bumped when this change ships.

## 0.10.0

This release makes the `Hook::before_tool` interception point `async`, so
hooks can suspend for real host interaction — an approval prompt over
`UiPort::request`, a sandbox round-trip, a worker hop — instead of having to
decide synchronously. Under MoonBit's colorless-coroutine model this is an
extension, not a rewrite: an existing synchronous `fn before_tool(...)` impl
still satisfies the now-`async` slot, so existing hook implementations keep
compiling. The Puppet pump is the part that gained real behavior: it now
catches errors from `before_tool` and keeps the existing
cancellation/error classification intact — a cancellation raised inside the
hook (e.g. the host aborts an approval prompt) stays a cancellation, not a
hook defect.

The second user-visible change is a `raw : Json?` field on the canonical
`@kernel.Reasoning` type, carrying a provider-defined replay payload for the
OpenAI Responses API reasoning items that must be replayed verbatim when a
host manages conversation state itself. The Kernel never interprets it;
adapters that replay plain `content` text (DeepSeek, Kimi, OpenAI-compatible)
leave it `None`. This is a struct-shape break (see below).

### Breaking: `Reasoning` gains a `raw : Json?` field

`@kernel.Reasoning` now has `raw : Json?` alongside `content`. Anywhere that
constructs a `Reasoning` literal must add the field:

```moonbit
// before
Reasoning::{ content: text }
// after
Reasoning::{ content: text, raw: None }
```

`StreamAccumulator::to_completion` and the in-tree adapters are updated; the
field defaults to `None` at every site that does not carry a replay payload.

### Changed: `Hook::before_tool` is `async`

```moonbit
pub(open) trait Hook {
  fn before_model(Self, Array[@kernel.Message]) -> Array[@kernel.Message] raise HookAbort = _
  async fn before_tool(Self, @kernel.ToolCall) -> ToolHookDecision = _   // ← now async
  fn on_post_event(Self, HookStage) -> Unit = _
}
```

- **Existing implementors need no change:** a plain `fn before_tool(...)` body
  satisfies the `async` slot under MoonBit's colorless-coroutine model. This
  only *enables* suspending hooks; it does not *require* them.
- **New capability:** a hook that needs host interaction — `UiPort::request`
  for an approval prompt, a sandbox/worker round-trip — implements
  `before_tool` as an `async fn` and suspends inside it.
- **Error classification preserved by the pump:** errors raised from
  `before_tool` are caught. A cancellation (e.g. the host aborts an approval
  prompt mid-suspend) rejects the run as `EffectExecutionCancelled(phase:
  "AwaitingTools")`; any other raise rejects it as a terminal `HookRejected`
  carrying the message — cancellation stays cancellation, not a hook defect.
  (Pinned by new cases in `src/posoco_wbtest.mbt`.)

### Added

- `Reasoning::raw : Json?` — opaque provider replay payload; see breaking note
  above.
- First-class CI/CD for the project:
  - `check.yml` and `coverage.yml` pipelines restructured with **JS backend
    support** (native remains the primary gate); a `moon update` step runs
    before every job so the toolchain is fresh.
  - `publish.yml` — on GitHub release, runs the full `moon check` / `moon
    info` (with `git diff --exit-code`) / `moon test` / `moon fmt` gate and
    then `moon publish` to mooncakes using `MOONCAKES_TOKEN`.
  - `--deny-warn` removed from the `moon check` step in `check.yml` and
    `publish.yml` so the gate fails on errors, not on pending warnings.

### Fixed

- `control_test.mbt` uses `repr(...)` instead of the removed `Repr(...)`,
  matching the current MoonBit builtin.

### Notes

- Removed the unused `xlog` dependency from `moon.mod`.
- The runtime seam and `Agent(exts, config)` defaults from 0.9.0 are
  unchanged; suspending hooks compose with both.

## 0.9.0

This release opens the **runtime seam**: a supported, public way for
advanced hosts to control how effects execute — cancellation propagation,
dynamic tool catalogs, and host-initiated follow-ups — without importing
anything under `internal/`. It exists for host builders (tool protocol
bridges, remote or sandboxed executors, browser/worker runtimes), not for
extension authors: **the Ports API and `Agent(exts, config)` are unchanged
and remain the recommended default.** No breaking changes this time;
everything below is additive.

The seam is deliberately 1:1 with the internal effect-execution boundary, so
the Kernel/Puppet state machine stays the single owner of phases, journals,
run/turn identity, terminal events, and session commits.

### Added: experimental runtime seam (`colmugx/posoco/runtime`)

- `Agent::with_runtime(exts~, config~, runtime~, ui_projection?, catalog_source?)` —
  same Agent, same assembly as the default constructor, but the caller
  supplies the effect-execution runtime. Typical shape: wrap `PortRuntime`
  and override only the methods you need (e.g. `execute_tool` +
  `cancel_effects` for cancellation propagation).
- `Runtime` — the public effect-execution contract: `call_model`,
  `execute_tool(EffectContext)`, `cancel_effects(effect_ids, reason)`,
  `compact(...)`. `execute_tool` receives the reducer-allocated `effect_id` —
  the same id later passed to `cancel_effects` — which is the correlation
  key for cancellation (e.g. `EffectId → AbortController`) and incremental
  progress. `cancel_effects` is best-effort, idempotent per effect id, and
  reports `Propagated` / `NotPropagated` / `AlreadySettled`.
- `PortRuntime` — the default `Runtime` over your `ModelPort` +
  `ToolProvider`s; this is what `Agent(exts, config)` now builds internally.
  Both constructors share one assembly path.
- `Agent::control() -> RuntimeControl` — available on **every** Agent,
  custom runtime or not:
  - `enqueue_follow_up(message)` — a background task can ask the Agent to
    continue. Queued follow-ups drain FIFO at turn boundaries, each driving
    a full turn on the same session (real `TurnStarted`/`TurnCompleted` and
    session commits); `run_turn` returns the last drained turn's
    `TurnResult`. Identity-guarded: no active run → `RejectedStale`; queue
    full (64) → `RejectedQueueFull`.
  - `abort_active(detail)` — idempotent per active run; in-flight effects
    receive a best-effort `cancel_effects` at the loop's next safe point.
  - `active_run_id()` / `active_turn_id()` / `pending_follow_ups()`.
- `CatalogSource` — host-owned, versioned tool catalog for `with_runtime`.
  Posoco reads it at construction and re-reads it at each prompt boundary
  where `revision()` changed. One rebuild attempt per revision: invalid
  definitions keep the previous snapshot and surface a `secondary_failure`
  observer event; in-flight runs always keep their pinned snapshot.
  Definitions are taken verbatim — `owner` and `policy` respected, unlike
  port-declared tools (which stay pinned to `Parallel`).
- Canonical wire types promoted to `@kernel`: `RunId`, `TurnId`,
  `SessionId`, `EffectId`, `CatalogVersion`, `CancelReason`,
  `CancelDisposition` — the public seam references them without internal
  imports.
- `docs/RUNTIME.md` — the host-facing contract: when you need the seam,
  the mental model, MUSTs pinned by named tests, an assembly guide
  (L0–L2), anti-patterns, and the stability policy.

### Notes

- The runtime seam is **experimental**: it may evolve with the active Lean
  Puppetry milestone, and any change lands here with migration notes. The
  contracts are pinned by `src/runtime_seam_wbtest.mbt` and
  `src/runtime/control_test.mbt`, which run in the required native gate.
- `Agent::run_turn` now drains queued follow-ups at turn boundaries (cap 64
  per call). This is observable only when a host submits follow-ups through
  `control()`; the default turn flow is unchanged.

## 0.8.0

This release fixes places where posoco violated its own design principles —
most visibly, three parallel hook traits where one was promised. We broke
your manifests to do it; we're sorry for the churn, and we chose to cut once
at 0.8.0 rather than keep two registration channels alive (a dual track
would defeat the point of unifying). Every break below is mechanical, and
each has a before/after migration.

### Breaking: three hook traits merged into one `Hook`

`PreModelHook`, `PreToolHook` and `PostEventHook` are deleted. There is now a
single `pub(open) trait Hook` whose three methods all have default
implementations — implementors override only the interception points they
care about:

```moonbit
pub(open) trait Hook {
  fn before_model(Self, Array[@kernel.Message]) -> Array[@kernel.Message] raise HookAbort = _
  fn before_tool(Self, @kernel.ToolCall) -> ToolHookDecision = _
  fn on_post_event(Self, HookStage) -> Unit = _
}
```

What was unified is registration, not signatures: each point keeps its
precise contract (can-abort / can-rewrite / read-only). Adding a new
interception point is now non-breaking — one defaulted method plus one call
site in the pump.

- **Implementors:** change `impl PreModelHook for X with fn before_model(...)`
  to `impl Hook for X with fn before_model(...)` (same for `before_tool` /
  `on_post_event`). A type that implemented several old traits now has
  several `impl Hook for X with fn ...` blocks, one per method.
- **Manifests:** the three manifest fields `pre_model_hooks` /
  `pre_tool_hooks` / `post_event_hooks` are replaced by one
  `hooks : Array[&Hook]`. Merge your arrays in the order
  pre_model → pre_tool → post_event.
- **Testkit:** `tk_ext(..., pre_model_hooks=..., pre_tool_hooks=..., post_event_hooks=...)`
  becomes `tk_ext(..., hooks=[...])`.
- **Trigger semantics (documented, unchanged behavior):** `before_model`
  fires at prompt start on the initial messages and after each Resume —
  *not* before every model call inside a tool round-trip. `before_tool`
  fires per `ExecuteTool` effect; `on_post_event` fires after every effect.
- **`PostStage` renamed to `HookStage`.** The old name collided with
  `KernelEvent` variant names while carrying different payload shapes;
  `HookStage` makes the hook-facing projection unmistakable. Mechanical
  rename, variants unchanged.
- **Testkit:** `HookRecord2` renamed to `HookRecord` (the transitional
  suffix is gone).

### Breaking: `Observer::on_kernel_event` deleted

`Observer` keeps only `on_event(TurnEvent)`. If you overrode
`on_kernel_event` for per-step kernel notifications, move that logic to
`Hook.on_post_event(HookStage)` and register the type as a hook.

### Breaking: built-in adapters moved out of the port package

`src/port` now contains only extension contracts. The concrete adapters
`SystemPromptHook`, `SystemPromptSection`, `MemoryRetrievalHook`,
`UiRenderHook`, `NoopUiPort` and `CompositeUiPort` moved to the root
package. Root paths (`@posoco.SystemPromptHook`, …) are unchanged; any
direct `@port.X` reference to these structs must become `@posoco.X`.

### Breaking: `UiRenderHook` projection is opt-in

`Agent` no longer auto-installs the built-in UI render policy. To restore
the previous behavior, pass the new optional constructor flag:

```moonbit
Agent(exts=..., config=..., ui_projection=true)
```

Hosts with their own UI policy should leave it off (default) and register
their own `Hook` instead — this is what cetas-js was already doing by
fighting the auto-injection.

Why a constructor flag rather than "just register `UiRenderHook` yourself":
the flag wires the hook to the **aggregated** `UiPort` (the Composite fan-out
across every manifest's `ui=[...]` contribution), which a hand-registered
hook cannot reach. Registering manually still works for a single host-owned
UI.

### Behavior change: hook/observer secondary failures are non-fatal

A failing hook (`on_post_event`) or observer no longer jeopardizes the run:
the failure is emitted as exactly one
`Custom(source="posoco.core", label="secondary_failure")` event with a
sanitized payload, and the turn continues. `MemoryRetrievalHook` search
failures take the same channel via its new optional `on_failure?` callback
(wired by `Agent` automatically). This finally matches what the docs always
promised.

### Breaking: internal machinery sealed

`@kernel` now exports only the canonical protocol types (the set already
re-exported at the root). The execution machinery — reducer, state, effect,
event, input, error, run context, scheduler, catalog, schema validation,
host runtime — moved to `colmugx/posoco/internal/kernel_exec`, and the whole
`puppetry` package moved to `colmugx/posoco/internal/puppetry`. MoonBit
enforces `internal/` visibility, so these can no longer be imported from
outside. The supported runtime entry point is, as documented, `Agent`;
nothing in `external/` referenced these packages.

Speculative M2 machinery that no production path used was removed outright:
the `PuppetLifecycleNode` startup/rollback executor (Agent drives the public
`Lifecycle` port itself) and the shipped `scripted_driver` (it survives only
as a test-scope fixture for the reducer golden suite).

### Added

- `ToolRegistry::register_strict` — raises on name collision. `register`
  keeps its hot-replace semantics and now says so in its docstring.
- `Hook` default-method pass-through and single-impl-all-points conformance
  tests; `ui_projection` opt-in/out regression tests.

### Fixed

- The reducer is again the sole transcript writer: same-length pre-model
  rewrites and compact results route through kernel inputs instead of the
  pump mutating run state directly.
- System-prompt section headers now name their source: the assembled prompt
  uses the contributing extension's manifest id instead of the meaningless
  synthetic `section_0`, `section_1`, …
- Assorted documentation drift: `docs/02-architecture.md`,
  `docs/04-developer-guide.md`, `docs/EXTENSIONS.md` and the README
  quickstart now show the real, compiling API.
