# 03 — 端口配方

写扩展就是"实现端口"。本文给出每个公开端口的签名、最小实现和常见做法，
像菜谱一样直接套用，不需要先搞懂框架的执行细节。

## 1. Extension：把自己交给 Agent

每个扩展都实现 `Extension`，在 manifest 里列出自己贡献的端口。一个值可以同时
实现多个端口 trait，所以在多个字段里登记同一个 `self` 完全合法：

```moonbit
pub(all) struct EchoModel {}

pub impl @posoco.ModelPort for EchoModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion = @posoco.Completion(
    content=[@posoco.Content::Text("hello")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: messages.to_owned() }
}

pub impl @posoco.ModelPort for EchoModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("compaction is not supported")
}

pub impl @posoco.ModelPort for EchoModel with fn provider_config(
  _self,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

pub impl @posoco.Extension for EchoModel with fn extension_id(_self) -> String {
  "echo-model"
}

pub impl @posoco.Extension for EchoModel with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest::make(id="echo-model", models=[self])
}

pub extend EchoModel with @posoco.Extension::{extension_id, manifest}
```

- `extension_id` 用于组合诊断，保持稳定且唯一。
- `manifest` 的字段：`models`、`tools`、`sessions`、`observers`、`hooks`、
  `memory`、`lifecycle`、`commands`、`ui`、`prompt_contributors`。用
  `ExtensionManifest::make(id=...)` 构造，只列出你有的端口，省略的字段默认
  为空数组。
- 两个扩展注册了同名工具时，`Agent` 在构造时立即抛
  `CompositionError::ToolCollision`——不存在"后声明覆盖前声明"。

把扩展直接交给 `Agent` 即可。Agent 恰好需要一个模型和一个 session store；
工具、observer、hook、memory、UI、command、lifecycle 都是可选的：

```moonbit
let model = EchoModel::{  }
let store = MySessionStore()
let agent = @posoco.Agent(
  exts=[
    model as &@posoco.Extension,
    store as &@posoco.Extension,
  ],
  config={
    max_tool_rounds: Some(8),
    temperature: None,
    max_output_tokens: Some(2048),
    model_context_window: None,
    compact_threshold: None,
    system_prompt: None,
  },
)
```

## 2. ModelPort：接入任意大模型

### 签名

```moonbit
pub(open) trait ModelPort {
  async fn chat(
    Self,
    scope : InvocationScope,
    messages : ArrayView[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
    stream : StreamMode,
  ) -> ModelCallResult raise ModelError

  async fn compact(
    Self,
    scope : InvocationScope,
    messages : ArrayView[Message],
    options : ChatOptions,
    trigger : CompactTrigger,
  ) -> CompactResult raise ModelError

  fn provider_config(Self) -> ProviderConfig
}
```

`chat` 通过 `scope` 拿到这次调用服务于哪个 session/run（遥测、计费、按会话切换
策略都靠它）。`stream` 是 `NoStream` 或 `Stream(callback)`，流式细节见
[05 流式指南](./05-streaming-guide.md)。

返回值 `ModelCallResult` 包含权威的 `Completion` 和 `processed_messages`——
你真正发给 provider 的消息副本，Agent 会用这份数组替换当前记录。没做任何预处理
就原样返回收到的 messages 的副本。

### 最小实现

```moonbit
pub(all) struct FixedModel {}

pub impl @posoco.ModelPort for FixedModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion = @posoco.Completion(
    content=[@posoco.Content::Text("Hello from Posoco")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: messages.to_owned() }
}

pub impl @posoco.ModelPort for FixedModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("FixedModel does not implement compact")
}

pub impl @posoco.ModelPort for FixedModel with fn provider_config(
  _self,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
```

三个方法都要实现。不支持压缩就 `raise ModelError::ResponseParse`——把输入原样
返回伪装成压缩成功，会掩盖缺失的能力。provider 专属配置（各家特有的参数）放在
你扩展自己的配置 struct 里，`provider_config` 只声明你接受哪些共享设置
（`temperature`、`max_output_tokens`）。

### 返回工具调用

工具调用放在 `Completion` 上，没有第二份"响应 record"：

```moonbit
let call : @posoco.ToolCall = {
  call_id: @posoco.CallId::unchecked("call_1"),
  name: @posoco.ToolName::unchecked("echo"),
  arguments: Json::object(Map::from_array([
    ("text", Json::string("hello")),
  ])),
}
let completion = @posoco.Completion(
  content=[],
  tool_calls=[call],
  reasoning=None,
  finish_reason=@posoco.FinishReason::ToolCalls,
  usage=None,
)
let result : @posoco.ModelCallResult = {
  completion,
  processed_messages: [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("hello"),
    ]),
  ],
}
```

下一轮模型调用会收到 Agent 生成的 `ToolMessage`（工具结果）。适配器必须保留
call id 和合法的 JSON arguments；解析到坏数据时抛 typed `ModelError`，不要
捏造一个空对象糊弄过去。

## 3. ToolProvider：给 Agent 一双"手"

一个统一的端口：`list_tools` 声明（同步），`execute` 执行（async）。执行结果用
`ToolOutcome` 表达，不需要第二个布尔状态字段。

### 签名与工具定义

```moonbit
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[ToolDef]
  async fn execute(
    Self,
    name : String,
    call : ToolCall,
  ) -> ToolOutcome raise RuntimeError
}
```

`ToolDef` 携带名字、描述、JSON 输入 schema 和归属身份。路由归属由 Agent 在
组装期构建，保证每个调用都精确送到声明该工具的 provider：

```moonbit
fn echo_def() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("echo"),
    description: "Return the supplied text",
    input_schema: Json::object(Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(Map::from_array([
        ("text", Json::object(Map::from_array([
          ("type", Json::string("string")),
        ]))),
      ]))),
      ("required", Json::array([Json::string("text")])),
    ])),
    owner: @posoco.OwnerId::unchecked("echo-extension"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("echo-extension"),
  }
}
```

### 最小实现

```moonbit
pub(all) struct EchoTools {}

pub impl @posoco.ToolProvider for EchoTools with fn list_tools(
  _self,
) -> Array[@posoco.ToolDef] {
  [echo_def()]
}

pub impl @posoco.ToolProvider for EchoTools with fn execute(
  _self,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "echo" {
    raise @posoco.RuntimeError::UnknownTool("unknown tool: " + name)
  }
  match call.arguments {
    Json::Object(fields) if fields.contains("text") =>
      match fields["text"] {
        Json::String(text) => @posoco.ToolOutcome::Success(
          content=text,
          structured=None,
        )
        _ => @posoco.ToolOutcome::ToolReportedError(
          content="text must be a string",
          structured=None,
        )
      }
    _ => @posoco.ToolOutcome::ToolReportedError(
      content="arguments must contain string field 'text'",
      structured=None,
    )
  }
}
```

### 选哪个 outcome？

| 变体 | 含义 | 模型会看到什么 |
|------|------|---------------|
| `Success` | 工具正常返回 | 结果内容 |
| `ToolReportedError` | 工具跑了，但业务上失败（参数不对、被拒绝） | 错误内容，模型可以据此重试 |
| `RuntimeFailure` | 适配器没跑成（网络挂了、异常了） | 错误内容；provider 抛出的 `RuntimeError` 也会被转成它 |
| `NotExecuted` | 组合/校验没放行（工具不存在、schema 不匹配） | 原始 call id 和原因 |

工具失败会成为模型上下文里的一条消息，**本身不会中止 turn**。但你的适配器仍要
在边界大声失败：不要吞掉基础设施异常再返回一个"成功"的空字符串。

### 动态注册：ToolRegistry

工具集合会变？用 `ToolRegistry`：

```moonbit
let registry = @posoco.ToolRegistry::ToolRegistry()
registry.register(
  echo_def(),
  fn(call : @posoco.ToolCall) -> @posoco.ToolOutcome {
    @posoco.ToolOutcome::Success(content="registered", structured=None)
  },
)
registry.unregister("echo")
```

`register` 表示有意的热替换；想重名时报错就用 `register_strict`（抛
`RuntimeError::ToolAlreadyRegistered`）。

## 4. SessionStore：对话的记事本

### 签名

```moonbit
pub(open) trait SessionStore {
  async fn load(Self, id : String) -> Session raise SessionError
  async fn save(Self, id : String, session : Session) -> Unit raise SessionError
}
```

`Session` 是 `{ messages, metadata }`。约定：**查不到的 id 返回空 session**——
这就是一段新对话的开始。真实存储必须在每个边界复制可变 Array/Map，并把存储
失败映射为 `SessionError::Load` 或 `SessionError::Save`：

```moonbit
pub(all) struct InMemoryStore {
  sessions : Map[String, @posoco.Session]
}

pub fn InMemoryStore::InMemoryStore() -> InMemoryStore {
  { sessions: Map::from_array([]) }
}

fn snapshot_session(session : @posoco.Session) -> @posoco.Session {
  {
    messages: session.messages.copy(),
    metadata: session.metadata.copy(),
  }
}

pub impl @posoco.SessionStore for InMemoryStore with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => snapshot_session(session)
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

pub impl @posoco.SessionStore for InMemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = snapshot_session(session)
}
```

文件或数据库存储遵循同一套约定："找不到"是空 session；数据损坏、权限错误、
传输失败才是 typed 的 load/save 错误。注册了多个 store 时，Agent **从第一个
加载、向所有 store 写入**（write-all / read-first）——这不是事务，需要原子复制的
产品请自己实现一个事务型适配器。

## 5. Observer：只读旁观者

`Observer::on_event` 只读、同步、带默认空实现。事件载荷用权威的 `Message`、
`ToolCall`、`ToolOutcome` 值；`ToolCallResult` 上的 `is_error` 直接从 outcome
派生，不要再从字符串里推第二份状态：

```moonbit
pub(all) struct ConsoleObserver {}

pub impl @posoco.Observer for ConsoleObserver with fn on_event(
  _self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => println("turn started")
    @posoco.TurnEvent::ToolCallPending(call) =>
      println("calling " + call.name.to_string())
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
      println(
        "tool " + call.name.to_string() +
        " failed=" + is_error.to_string() +
        " outcome=" + result.summary(),
      )
    @posoco.TurnEvent::ModelResponseReceived(..) => ()
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) => println(token)
        _ => ()
      }
    @posoco.TurnEvent::StreamChunksDropped(count~) =>
      println("dropped " + count.to_string() + " telemetry chunks")
    @posoco.TurnEvent::TurnCompleted => println("turn completed")
    @posoco.TurnEvent::TurnFailed(reason) => println("turn failed: " + reason)
    _ => ()
  }
}
```

Observer 的失败不会被静默吞掉：违反 `Unit` 合同的运行时失败保持 loud，让宿主
能发现。每个 observer 收到的都是事件数据的独立快照，改它不影响别人。

需要把事件归因到具体 run 时（成本核算、按代际聚合、遥测关联），改覆盖
`Observer::on_event_at(scope, event)`：核心只分发这个带 `EventScope?`
（`session_id`/`run_id`/`turn_id`）的变体，上面这种只覆盖 `on_event` 的写法由
默认委托继续工作。scope 保证：turn 生命周期事件、envelope 投影事件
（`ModelResponseReceived`/`ToolCallPending`/`ToolCallResult`/`SessionRedirect`）
恒为 `Some`；`StreamChunkReceived` 与 `Custom` secondary failure 这类 run 外诊断
为 `None`。

## 6. PipelineHook：插手流程

一个 `PipelineHook` trait 装多种拦截点，每个方法都有默认实现，你只覆盖需要的
那几个。`before_model` / `before_tool` 可以改写或中止；`on_post_event*` 是只读通知；
`on_turn_begin` / `on_turn_end` 在 turn 边界执行副作用：

```moonbit
pub(open) trait PipelineHook {
  /// 在模型调用前改写 messages；可 raise HookAbort 中止 turn。
  async fn before_model(
    Self,
    messages : Array[Message],
  ) -> Array[Message] raise HookAbort = _
  /// 在每次工具执行前审批、改写或拒绝。
  async fn before_tool(Self, call : ToolCall) -> ToolDecision = _
  /// 效果完成后的只读通知，不能失败。
  async fn on_post_event(Self, stage : HookStage) -> Unit noraise = _
  /// 带归因 scope 的变体；核心只分发它，默认委托回 on_post_event。
  async fn on_post_event_at(Self, scope : EventScope?, stage : HookStage) -> Unit noraise = _
  /// turn 开始： lifecycle on_start 之后、第一个 before_model 之前。
  async fn on_turn_begin(Self) -> Unit = _
  /// turn 结束：终端事件投影之后。
  async fn on_turn_end(Self) -> Unit = _
}
```

### 审批与改写

`before_tool` 用普通同步函数写就行——槽位声明为 async 是为了让审批 hook 在
宿主提供 `UiPort` 时能发起交互（比如弹一个确认框）。多个 hook 按注册顺序执行，
第一个非 `Approve` 的决定胜出。`Defer` 目前按终止性拒绝处理（挂起/恢复尚未
实现），别依赖它：

```moonbit
pub(all) struct ApprovalHook {}

pub impl @posoco.PipelineHook for ApprovalHook with fn before_tool(
  _self,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  if call.name.to_string() == "delete" {
    @posoco.ToolDecision::Reject(
      reason="delete requires explicit approval",
    )
  } else {
    @posoco.ToolDecision::Approve(call~)
  }
}
```

`before_model` 可以改写消息。注意：稳定的 system prompt 应该通过
`SystemPromptContributor` 注入并被核心缓存；只有**每 turn 变化的动态信号**
（如 plan mode）才需要手动在 `before_model` 里追加 `UserMessage`：

```moonbit
pub(all) struct PromptHook {
  prompt : String
}

pub impl @posoco.PipelineHook for PromptHook with fn before_model(
  self,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  let system = @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text(self.prompt),
  ])
  let rewritten : Array[@posoco.Message] = [system]
  for message in messages {
    rewritten.push(message)
  }
  rewritten
}
```

`before_model` 可以 `raise HookAbort::Aborted(reason=...)` 主动中止 turn；Agent
把它显式暴露为 `AgentError::PipelineAborted`。`on_post_event` 收到 `ModelCompleted`、
`ModelFailed`、`ToolCompleted`、`ToolFailed`，是效果完成后的只读通知，不用于
中止流程。

### 注册进 manifest

```moonbit
pub impl @posoco.Extension for ApprovalHook with fn extension_id(_self) -> String {
  "approval"
}

pub impl @posoco.Extension for ApprovalHook with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest::make(id="approval", hooks=[self])
}

pub extend ApprovalHook with @posoco.Extension::{extension_id, manifest}
```

hooks 数组的顺序就是执行顺序。

## 7. MemoryPort：长期记忆存储与检索

记忆是可选的，但端口表达的是完整的领域——一条入站召回通道（`inbound`）
加存取面（`store`/`search`/`delete`）：

```moonbit
pub(open) trait MemoryPort {
  /// inbound：session 首轮的召回正文——provider 自己渲染格式，返回
  /// `None` 表示没有可注入的内容。core 只在加载的 transcript 为空
  ///（即该 session 的第一个 turn）时调用，至多每 session 每进程一次。
  async fn inbound(Self, session_id~ : String, request~ : String) -> String? raise @error.MemoryError
  /// 存取面：写入返回 provider id 或票据；检索返回 provider 自渲染的
  /// 文本（`None` = 无命中）；删除按 id。
  async fn store(Self, content~ : String, metadata~ : Map[String, Json]) -> String raise @error.MemoryError
  async fn search(Self, query~ : String, top_k? : Int) -> String? raise @error.MemoryError
  async fn delete(Self, id : String) -> Unit raise @error.MemoryError
}
```

`MemoryEntry`/`MemoryQuery` 已删除：`store` 直接收正文 + 元数据（无元数据
传空 map），`search` 收自由文本查询（`top_k` 可选，省略即条数由 provider
自定）。失败统一 raise
`MemoryError`（新增 `Inbound(String)` 变体）。写入何时落盘归 provider
（可以只入队发票据）。

**inbound 注入契约**：core 在该 session 的第一个 turn、pump 之前调用每个
provider 的 `inbound`（传 session id 与用户首条请求原文；至多每 session
每进程一次）。全部为空/失败 → 不注入任何消息；有任何正文 → 在真正的
首条用户输入**之前**插入一条 user 消息：固定引导句
`MEMORY_INBOUND_LEAD` + 各 provider 正文按注册序原样拼接（core 不加
任何标注）。消息随 transcript 持久化——resume 后原样保留，绝不重读、
绝不改写；空/失败结果同样耗掉本次尝试（进程内闸门）。provider 失败与
超时走 `secondary_failure` observer 事件（hook point `memory_inbound`），
从不弄断 turn。core 的每 provider 预算由
`AgentConfig.memory_inbound_timeout_ms` 控制（`None` = 不设核心预算，
provider 自限）。旧的 `MemoryBriefingHook` 已删除——注入是 Agent 内部
的 pre-pump 步骤，core 里不再有任何记忆相关的 hook，也没有任何标记串
匹配。

**内置工具**：只要有扩展贡献了 `MemoryPort`，core 自动注册两个内置
agent 工具——`memory_search`（对全部 provider 扇出检索，结果按注册序
拼接、不加标注；全部为空返回 "No matching memory."；失败静默跳过 +
`secondary_failure`）和 `memory_add`（参数 `content` + 可选 `source` =
manifest id；省略 `source` 写入所有已连接 provider；未知 `source` 报
工具错误并列出合法来源；回执为 `<source>: <id|票据>` 行，失败行
`<source>: failed (…)`）。它们与扩展工具走同一套 `ToolCollision`
快速失败——扩展再声明同名 `memory_search`/`memory_add` 工具会让组合
失败，这是刻意的：provider 应当丢掉自己的通用记忆工具，只保留专门
工具。没有 `memory_delete` 内置工具——`delete` 保持为被动端口槽，留给
产品侧逻辑（例如 observer 检测到陈旧记忆后清理）。

**实现一个 memory provider**：

1. 实现四个槽；`inbound` 按 `request` 召回并渲染正文（要 XML 信封可用
   devkit 的 `context_envelope`），无内容返回 `None`；
2. `search` 自己渲染输出格式——core 原样拼接，不加标注；
3. manifest 里 `memory: [self]`；manifest 的 `id` 就是 `memory_add` 的
   合法 `source`；
4. 不要再声明通用的 `memory_search`/`memory_add` 工具（见上面的冲突
   规则），core 已经提供。

## 8. Lifecycle：装配、启动、清理三段

`Lifecycle` 是扩展面向 Agent 生命周期的三个挂点，全部带默认实现，按需覆写：

- **`on_compose(ctx)`**（同步）：组合的所有门通过之后、Agent 就绪之前，按注册序
  调用恰好一次。这是接收组合能力的时点——manifest 里 `requires` 声明了什么，
  `ctx.model()` / `ctx.ui()` 就读到什么（未声明读 `None`）。同步是刻意的：
  `chat`/`request` 都是 async，装配期只能接线不能动作。需要的能力缺失时 raise
  `@posoco.CompositionError::ExtensionComposeFailed`，组合整体失败，无半成品 Agent。
- **`on_start()`**（async）：首个 `run_turn` 内、第一个 `TurnStarted` 投影之前，
  每 Agent 生命周期恰好一次。加载持久状态、spawn 后台循环的合法出生点（构造期
  没有异步根）。抛错会被响亮包装，首个 turn 在任何终端事件之前失败。
- **`on_shutdown()`**（async）：Agent shutdown 时按注册**逆序**逐个调用；清理失败
  响亮传播，重试会从失败的那个扩展继续而不是跳过。

```moonbit
pub(all) struct ManagedConnection {
  connection : Connection
}

pub impl @posoco.Lifecycle for ManagedConnection with fn on_shutdown(
  self,
) -> Unit {
  self.connection.close()
}
```

在 manifest 的 `lifecycle` 字段注册它，宿主结束时调用 `agent.shutdown()`。
清理失败就交给宿主决定重试还是终止——扩展自身尽量让清理可重试、幂等。

## 9. 其他小端口

- **CommandPort**：宿主主动触发的命令（斜杠命令、面板按钮），`commands()`
  声明、`invoke(id, args)` 执行。和 ToolProvider 的区别：工具是模型发起的，
  结果回填进对话；命令是用户/宿主发起的。
- **UiPort**：宿主交互能力，`UiPort::request` 可以弹审批框、选单等。审批类
  hook 通过它实现人工确认。
- **SystemPromptContributor**：给聚合 system prompt 加一段**逐字节稳定**的
  静态内容。核心只读一次并缓存，空字符串会被跳过。详见下一节。

## 10. SystemPromptContributor：静态 system prompt 段落

`SystemPromptContributor` 只负责返回**逐字节稳定**的字符串段落。Posoco 在每个
Agent 生命周期中只读取一次——首个 turn 的第一次 `before_model`——并把
`AgentConfig.system_prompt` 与各 contributor 的返回组装成一条 SystemMessage 缓存
下来。空字符串会被跳过；contributor 绝不能返回动态内容（如 plan mode 开关、
时间戳、随机 ID），否则会破坏 prefix cache 与 transcript 稳定性。

### 签名与契约

```moonbit
pub(open) trait SystemPromptContributor {
  /// 返回一段 system prompt 文本。空字符串表示"无内容"。
  /// 稳定性契约：同一个 Agent 生命周期内，返回值必须逐字节相同。
  fn system_prompt(Self) -> String
}
```

### 最小实现

```moonbit
pub(all) struct RuleContributor {
  text : String
}

pub impl @posoco.SystemPromptContributor for RuleContributor with fn system_prompt(
  self : RuleContributor,
) -> String {
  self.text
}

pub impl @posoco.Extension for RuleContributor with fn extension_id(_self) -> String {
  "rule-contributor"
}

pub impl @posoco.Extension for RuleContributor with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest::make(id="rule-contributor", prompt_contributors=[self])
}

pub extend RuleContributor with @posoco.Extension::{extension_id, manifest}
```

### 组装语义

当 `AgentConfig.system_prompt` 非空，或任一扩展登记了 `SystemPromptContributor`
时，Posoco 自动注入内置 `SystemPromptHook`：

1. 以 `AgentConfig.system_prompt` 为 base（若有且非空）；
2. 依次追加每个 contributor 的 section，格式为 `{extension_id}:\n{text}`；
3. section 之间以空行 `\n\n` 分隔；
4. 若 base 与所有 contributor 都为空，直接返回原 `messages`，不注入空 system
   消息；
5. 否则合成一条 `SystemMessage`，置于 index 0：原 0 号位文本相同则原样返回数组
   （避免 transcript 重写），不同则替换，无 system 消息则 prepend。

### 动态模式指示：用 PipelineHook.before_model 注入 UserMessage

需要按 turn 变化的信号（plan mode、当前时间、会话状态等）不要走
`SystemPromptContributor`，否则缓存后的静态文本无法反映变化。应实现
`PipelineHook.before_model`，向 messages 末尾追加（或替换已有）一条带 envelope 的
`UserMessage`。envelope 格式可参考 `posoco-devkit` 的 `context_envelope`：

```moonbit
pub(all) struct ModeIndicatorHook {
  mode : String  // e.g. "plan" | "act"
}

fn make_envelope(mode : String) -> String {
  // 实际项目可用 @devkit.context_envelope(...)
  "<cetas-context type=\"mode\" trust=\"true\">\nCurrent mode: " + mode + "\n</cetas-context>"
}

pub impl @posoco.PipelineHook for ModeIndicatorHook with fn before_model(
  self : ModeIndicatorHook,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  let envelope = make_envelope(self.mode)
  // 幂等：如果最后一条 UserMessage 已经携带完全相同的 envelope，则原样返回
  let mut i = messages.length() - 1
  let mut last_user_idx = -1
  while i >= 0 {
    match messages[i] {
      @posoco.Message::UserMessage(content~) => {
        last_user_idx = i
        break
      }
      _ => ()
    }
    i = i - 1
  }
  if last_user_idx >= 0 {
    match messages[last_user_idx] {
      @posoco.Message::UserMessage(content=[@posoco.Content::Text(existing), ..]) =>
        if existing == envelope { return messages }
      _ => ()
    }
  }
  let out : Array[@posoco.Message] = []
  for m in messages { out.push(m) }
  out.push(@posoco.Message::UserMessage(content=[@posoco.Content::Text(envelope)]))
  out
}
```

幂等要点：

- 比较前先检查最后一条 `UserMessage` 的文本是否已等于目标 envelope；
- 内容相同时**必须**返回同一个数组实例（或内容相同的副本），避免核心把"无变化"
  误判为消息改动而触发 transcript 重写；
- envelope 中不要嵌入时间戳、随机 ID 等每 turn 都会变的字段，否则每次都不同，
  幂等失效。

## 11. 端口速查

| 端口 | 必需？ | 主要职责 |
|------|-------|----------|
| `ModelPort` | 是（恰好一个） | 调用模型：chat、compact、provider config |
| `SessionStore` | 是（至少一个） | 对话记录与元数据持久化 |
| `ToolProvider` | 否 | 工具声明与执行 |
| `Observer` | 否 | 只读 turn 事件 |
| `PipelineHook` | 否 | 改写消息、审批工具、效果后通知、turn 边界副作用 |
| `MemoryPort` | 否 | 长期记忆：`inbound` 首轮召回注入 + 存取面；core 自动注册 `memory_search`/`memory_add` |
| `CommandPort` | 否 | 宿主发起的命令 |
| `UiPort` | 否 | 宿主交互（审批、选单） |
| `SystemPromptContributor` | 否 | 向 system prompt 追加**逐字节稳定**的静态段落 |
| `Lifecycle` | 否 | 装配接线（on_compose）、启动（on_start）、资源清理（on_shutdown） |
| `Extension` | 每个贡献者 | 声明自己的端口清单 |