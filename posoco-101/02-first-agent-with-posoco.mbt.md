---
moonbit:
  backend:
    native
---

# 如何用 Posoco 完成第一个简单 Agent

> 课题：用最少的端口实现，组装一个能跑完一轮 turn 的 Agent。
>
> 本文是可执行的 MoonBit 文档（`.mbt.md`）。所有代码块按顺序声明、
> `moon test` 直接运行。本文依赖 Posoco——`@posoco.*` 是它的公开 API。

## 1. 你需要提供什么

Posoco 是一个 ports-and-adapters 框架。组装一个最小 Agent 只需要实现
**两个端口**，再加**一个 trait**把它们报告给 Agent：

| 角色 | 你要做什么 | 为什么必须实现 |
|------|-----------|---------------|
| `ModelPort` | 返回一个固定回复 | Agent 需要一个"模型"来产生响应 |
| `SessionStore` | 在内存里存取对话 | Agent 需要记住这个 session 的消息 |
| `Extension` | 自报告你贡献了哪些端口 | Agent 靠 manifest 聚合扩展，不靠位置参数 |

`ToolProvider`、`Observer`、各种 Hook、`MemoryPort`、`Lifecycle`、
`CommandPort`、`UiPort` 都可以留空——它们是可选的扩展点。

> **为什么是 Extension，而不是 `model=…, tools=…`？**
> 这是 Posoco 的核心组合模型：每个扩展**自我报告**它贡献了哪些端口，
> Agent 通过聚合 manifest 发现所有贡献。好处是顺序无关、可组合、
> 重名工具 fail-fast。第 03 篇会深入讲透。

## 2. 最小 ModelPort：固定回复

`ModelPort` 有三个方法：`chat`（对话）、`compact`（压缩上下文）、
`provider_config`（声明这个 provider 支持哪些能力）。

第一个 Agent 只关心 `chat`——返回一个固定回复。后两个方法用占位实现：

```moonbit check
///|
/// 一个总是回复固定字符串的 ModelPort。永不失败。
pub(all) struct FixedModel {}

///|
/// chat 是 ModelPort 的核心：接收身份、消息、工具定义、选项和流模式，
/// 返回一个 Completion。我们返回固定文本 + finish_reason::Stop，
/// 告诉 Agent "模型回答完毕，不需要工具"。
pub impl @posoco.ModelPort for FixedModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text("你好，我是固定回复模型")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
/// compact 在后续讲上下文压缩的章节才会真正实现。
/// 固定模型不压缩，直接拒绝——这是诚实的占位，不是空成功。
pub impl @posoco.ModelPort for FixedModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("FixedModel 不支持 compact")
}

///|
/// provider_config 声明这个 provider 支持哪些 reasoning_effort 值。
/// 固定模型不挑，返回空配置。
pub impl @posoco.ModelPort for FixedModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
```

四个关键点：

1. **`chat` 的第一个参数是 `InvocationScope`**。它回答"这次调用为哪个
   session / 哪个 run 服务"：`{ session_id, run_id, effect_id }`。它是
   **身份归因**，不是业务参数——适配器可以拿它做遥测、按会话计费，
   不关心的（比如 FixedModel）直接忽略。`effect_id` 在 `chat` 里总是
   `Some`（内核分配的这次模型调用），在 `compact` 里总是 `None`。
2. **`chat` 返回 `ModelCallResult`，不是裸 `Completion`**。结构是
   `{ completion, processed_messages }`——后者让真实模型有机会预处理
   消息（如缓存、改写）；固定模型返回空数组，Agent 会自动用原始输入填充。
3. **`finish_reason::Stop`** 告诉 Agent "本轮结束"。如果是 `ToolCalls`，
   Agent 会进入工具循环——但我们的固定模型不调用工具。
4. **`compact` raise 而不是返回空结果**。这是 Posoco 的失败透明原则：
   不支持的能力要明确拒绝，不能伪装成"压缩成功了但什么都没做"。

## 3. 把 FixedModel 变成一个 Extension

光实现 `ModelPort` 还不够——Agent 不知道 `FixedModel` 存在。你需要再实现
`Extension` trait，**自我报告**这个扩展贡献了哪些端口：

```moonbit check
///|
/// Extension::extension_id 是这个扩展的唯一标识，
/// 用于组合诊断（如工具重名时归因到哪个扩展）。
pub impl @posoco.Extension for FixedModel with fn extension_id(_self) -> String {
  "fixed_model"
}

///|
/// manifest 是自报告核心：列出你贡献的所有端口。
/// FixedModel 只贡献 model，其余字段全空。
pub impl @posoco.Extension for FixedModel with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "fixed_model",
    models: [self], // ← 关键：把自己放进 models 数组
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// 让 &FixedModel 能自动转型成 &Extension（放进 exts 数组）。
pub extend FixedModel with @posoco.Extension::{extension_id, manifest}
```

`manifest` 是一个 12 字段的结构体。除 `id` 外每个字段对应一种端口槽位：
`models` / `tools` / `sessions` / `observers` / `hooks` / `memory` /
`lifecycle` / `commands` / `ui` / `prompt_contributors`，最后的 `requires`
声明这个扩展想**消费**哪些组合能力（第 03 篇展开）。
`FixedModel` 只填 `models: [self]`，其余全空。这种"自报告"模型让 Agent
聚合时不用关心参数顺序——只要每个扩展诚实报告自己贡献什么。

## 4. 最小 SessionStore：内存字典

`SessionStore` 有两个 async 方法：`load` 和 `save`。Agent 在 turn 开始时
`load`，结束时 `save`。同样，它也要 impl `Extension` 才能被 Agent 发现：

```moonbit check
///|
/// 内存 SessionStore：用 Map 存所有 session。
pub(all) struct InMemoryStore {
  sessions : Map[String, @posoco.Session]
}

///|
/// 深拷贝 metadata，避免失败 turn 通过共享引用污染已保存 session。
fn copy_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let copied : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    copied[key] = metadata[key]
  }
  copied
}

///|
/// 深拷贝 session（messages + metadata）。
fn copy_session(session : @posoco.Session) -> @posoco.Session {
  {
    messages: session.messages.copy(),
    metadata: copy_metadata(session.metadata),
  }
}

///|
/// load 未知 id 时返回**空 session**，而不是 raise。
/// 这是 Posoco 约定：新对话第一次 turn 时 store 里还没有它。
pub impl @posoco.SessionStore for InMemoryStore with fn load(self, id : String) -> @posoco.Session raise @posoco.SessionError {
  match self.sessions.get(id) {
    Some(s) => copy_session(s)
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

///|
/// save 把整个 session 存回去。Agent 在 turn 结束时调用。
pub impl @posoco.SessionStore for InMemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.sessions[id] = copy_session(session)
}

///|
/// 同样要 impl Extension，报告自己贡献了 sessions 槽位。
pub impl @posoco.Extension for InMemoryStore with fn extension_id(_self) -> String {
  "in_memory_store"
}

///|
pub impl @posoco.Extension for InMemoryStore with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "in_memory_store",
    models: [],
    tools: [],
    sessions: [self], // ← 贡献 SessionStore
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend InMemoryStore with @posoco.Extension::{extension_id, manifest}
```

关键点：

- **`load` 未知 id 返回空 session，不返回 `Err`**。新对话的第一轮，
  store 里还没有它——这不是错误，是正常状态。
- **`save` 深拷贝**。如果不拷贝，失败 turn 可能通过共享引用污染
  已保存的 session（M0 数据保真不变量）。
- **`Extension` 把自己放进 `sessions: [self]`**。和 `FixedModel` 一样，
  自报告是 Agent 发现你的唯一方式。

## 5. 组装并运行 Agent

现在把两个扩展连起来。`Agent` 的构造器只接受两个参数：扩展数组 + 配置。

```moonbit check
///|
/// 组装并运行第一个 Agent：用户说你好，模型回复。
async test "first_agent_runs_one_turn" {
  let model = FixedModel::{  }
  let store = InMemoryStore::{ sessions: Map::from_array([]) }
  let agent = @posoco.Agent(
    exts=[model, store], // 两个自报告扩展，顺序无关
    config={
      max_tool_rounds: Some(10),
      compact_threshold: None,
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
    },
  )

  // 构造用户消息。Message 是 ADT，不是 record——每种角色一个构造器。
  // 构造器要带类型前缀：@posoco.Message::UserMessage。
  let user_message : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("你好"),
  ])

  // run_turn 是 async，返回 TurnResult。
  let result = agent.run_turn(user_message, "my-first-session")

  // TurnResult 有三个字段：message、tool_results、final_session_id。
  assert_eq(result.final_session_id, "my-first-session")
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      assert_eq(content, [
        @posoco.Content::Text("你好，我是固定回复模型"),
      ])
    _ => fail("expected AssistantMessage")
  }
}
```

构造器会做几道 fail-fast 检查（在组装时就 raise，不是等到运行）：

- **至少一个 SessionStore**：没有 store 的 Agent 无法持久化，直接拒绝组装。
- **恰好一个 ModelPort**：一个没有（`MissingModel`）或声明了两个
  （`MultipleModels`）都拒绝——多模型路由必须收进一个 meta 扩展里做，
  第 05 篇讲 Routing 时会看到为什么。

`run_turn` 返回 `TurnResult`，里面有：

- `message`：模型的最终回复（`FixedModel` 返回的那条 `AssistantMessage`）。
- `tool_results`：本轮执行的工具结果（这里是空，因为没有工具调用）。
- `final_session_id`：这轮写入的 session id。

## 6. 观察失败：Agent 如何暴露错误

Posoco 的核心原则是**失败透明**：错误必须以 typed error 的形式返回，
不能伪装成空结果或成功。

### 6.1 模型失败会终止 turn

如果你的 `ModelPort` raise 了 `ModelError`，Agent 会：

1. 发出 `TurnFailed` 事件给所有 Observer。
2. raise `AgentError::Model(...)` 向上传播。
3. **不**发出 `TurnCompleted`（一轮只有一个终止事件）。

```moonbit check
///|
/// 一个总是失败的 ModelPort，演示失败透明。
/// 注意：必须实现全部三个方法，否则不满足 ModelPort trait。
pub(all) struct FailingModel {}

///|
pub impl @posoco.ModelPort for FailingModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport("network unreachable")
}

///|
pub impl @posoco.ModelPort for FailingModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("FailingModel 不支持 compact")
}

///|
pub impl @posoco.ModelPort for FailingModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
pub impl @posoco.Extension for FailingModel with fn extension_id(_self) -> String {
  "failing_model"
}

///|
pub impl @posoco.Extension for FailingModel with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "failing_model",
    models: [self],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend FailingModel with @posoco.Extension::{extension_id, manifest}

///|
/// 验证：模型失败时 run_turn raises AgentError::Model，不返回 TurnCompleted。
async test "first_agent_model_failure_is_typed" {
  let model = FailingModel::{  }
  let store = InMemoryStore::{ sessions: Map::from_array([]) }
  let agent = @posoco.Agent(exts=[model, store], config={
    max_tool_rounds: Some(10),
    compact_threshold: None,
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  })
  let user_message : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("你好"),
  ])
  // 标准 expected-failure pattern：try 调用，catch 期望的错误，noraise 兜底。
  try {
    let _ = agent.run_turn(user_message, "fail-session")
    fail("expected AgentError::Model")
  } catch {
    @posoco.AgentError::Model(_) => () // 期望的错误
    _ => fail("expected AgentError::Model, got something else")
  }
}
```

### 6.2 工具失败不会终止 turn

工具执行（`ToolProvider::execute`）如果 raise `RuntimeError`，Agent 把它
当成一条**业务级失败消息**喂给模型，让模型决定下一步。这是 non-fatal 的。
事件 `ToolCallResult` 的 `is_error` 会是 `true`，turn 继续运行。

### 6.3 流式 JSON 损坏会 raise

如果模型的流式响应里工具调用参数 JSON 是坏的，`StreamAccumulator` 会
raise `ModelError::ResponseParse`，而不是静默变成 `{}`。

## 7. 小结

| 概念 | 在第一个 Agent 里的角色 |
|------|----------------------|
| `ModelPort` | 你实现的"模型"——固定回复（3 个方法） |
| `SessionStore` | 你实现的"记忆"——内存字典（load + save） |
| `Extension` | 自报告——告诉 Agent 你贡献了哪些端口 |
| `Agent(exts=, config=)` | 组装入口，扩展数组 + 配置 |
| `run_turn` | 运行一轮，返回 TurnResult raise AgentError |
| `Message` ADT | 每种角色一个构造器（UserMessage/AssistantMessage/…） |

第一个 Agent 不连真实模型、不调用工具、不做压缩。但它展示了 Posoco 的核心契约：

> **金句**：你提供端口实现 + 自报告 manifest，Agent 提供循环。

后续文章会展示：如何用 `tk_ext` 免去手写 Extension（第 03 篇）、
如何声明工具（第 04 篇 Tool Use）、如何用 Hook 控制流程（第 06 篇 Reflection）。

---

> **运行本文**：`moon test --target native`（本文是 `.mbt.md` doc-test，
> 代码块会被当作可执行测试）。
