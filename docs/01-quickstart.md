# 01 — 快速上手

十分钟之内，让一个最小的 Posoco Agent 跑起来：自己实现一个模型、一个会话存储，
把它们组装成 Agent，然后跑一轮对话。完整可运行示例在
[`examples/quickstart`](../examples/quickstart/)。

## 1. 先认识三个概念

Posoco 只有三个核心概念，后面所有内容都是围绕它们展开的：

- **端口（Port）**：一组由 Posoco 定义的能力接口（trait）。比如「接入一个大模型」
  是 `ModelPort`，「存取对话记录」是 `SessionPort`，「提供工具」是 `ToolProvider`。
  端口只规定"要做什么"，不规定"怎么做"。
- **扩展（Extension）**：实现了一个或多个端口的组件。你写的模型适配器、工具集合、
  存储后端，都是一个扩展。
- **Agent**：组合根。你把扩展交给 Agent，它负责把一切组装起来并运行——加载历史、
  调用模型、执行工具、保存记录，这些都不用你操心。

扩展通过 `Extension` trait 向 Agent **自我声明**自己提供了哪些端口，这个声明叫做
**manifest**。Agent 构造时把所有人的声明汇总，然后组装。这就是全部了。

## 2. 第一步：实现一个模型端口

先写一个最简单的模型：不管用户说什么，都固定回一句"Hello from Posoco"。

`ModelPort` 有三个方法，最小实现关心其中两个：

- `chat` —— 真正的对话调用，返回模型的回复；
- `compact` —— 对话压缩（下文 02 会细讲），不支持就直接抛错；
- `provider_config` —— 声明自己接受哪些共享配置，不需要就返回空配置。

```moonbit
struct FixedModel {}

pub impl @posoco.ModelPort for FixedModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion : @posoco.Completion = @posoco.Completion(
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
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "FixedModel does not implement compact",
  )
}

pub impl @posoco.ModelPort for FixedModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

pub impl @posoco.Extension for FixedModel with fn extension_id(_self) -> String {
  "quickstart-model"
}

pub impl @posoco.Extension for FixedModel with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="quickstart-model", models=[self])
}

pub extend FixedModel with @posoco.Extension::{extension_id, manifest}
```

逐段解释一下：

- **消息是 ADT，不是字典**。对话消息是 `@posoco.Message` 枚举
  （`UserMessage` / `AssistantMessage` / `SystemMessage` / `ToolMessage`），
  不是带 `role` 字段的 record。文本内容用 `Content::Text` 包装。
- **`chat` 返回两部分**：`completion` 是模型这次的回复
  （文本、工具调用、推理内容、结束原因、用量），`processed_messages` 是你真正
  发给 provider 的消息副本。Agent 会用这份副本替换对话记录。`messages` 参数是
  `ArrayView` 借用，不要持有它越过这次调用；如果没有做任何预处理，用
  `messages.to_owned()` 返回一份拥有的副本即可。
- **`InvocationScope` 是这次调用的身份**：里面记着这次调用服务于哪个 session、
  哪次 run。需要按会话区分行为（遥测、计费、按会话切换策略）时从它读取，
  不需要就忽略。把它当作只读的。
- **不支持的能力要大声失败**：`compact` 不支持就 raise `ModelError`，不要假装
  成功——那会掩盖真实的问题。
- **`manifest` 里登记自己**：`models: [self]` 意思是"我提供一个模型端口"。
  最后一行 `pub extend ...` 是 MoonBit 的语法糖，让 `extension_id` / `manifest`
  成为可直接调用的方法。

## 3. 第二步：实现一个会话存储

Agent 需要把对话记录存下来，跨 turn 保持连续性。这就是 `SessionPort`：两个方法，
`load` 读、`save` 写。

```moonbit
pub(all) struct MemoryStore {
  sessions : Map[String, @posoco.Session]
}

fn copy_session(session : @posoco.Session) -> @posoco.Session {
  {
    messages: session.messages.copy(),
    metadata: session.metadata.copy(),
  }
}

pub impl @posoco.SessionPort for MemoryStore with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => copy_session(session)
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

pub impl @posoco.SessionPort for MemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = copy_session(session)
}

pub impl @posoco.Extension for MemoryStore with fn extension_id(_self) -> String {
  "quickstart-store"
}

pub impl @posoco.Extension for MemoryStore with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="quickstart-store", sessions=[self])
}

pub extend MemoryStore with @posoco.Extension::{extension_id, manifest}
```

三个要点：

- **查不到的 session 返回空 session，不是报错**。这是约定：一段新对话的第一次
  turn，store 里还没有它。"找不到"和"出错了"是两回事——文件损坏、权限错误、
  网络失败才应该 raise `SessionError::Load` / `SessionError::Save`。
- **在边界复制数据**。`messages` 和 `metadata` 是可变数组和 Map。如果你把内部
  引用直接交出去，调用方就可能通过共享引用污染已保存的记录。进出都复制一份，
  各管各的。
- **`load` / `save` 是 async 方法**，但用普通同步函数体实现也没问题——MoonBit
  允许同步函数满足 async 的 trait 槽位。

## 4. 第三步：组装 Agent 并跑起来

把上面两个扩展交给 `Agent`，配置好参数，然后调用 `run_turn`：

```moonbit
let model = FixedModel::{  }
let store = MemoryStore::{ sessions: Map::from_array([]) }
// 每个 Agent 一个事件资源，先由宿主创建，再交给 Agent 独占接管。
let events = @posoco.EventSystem()

let agent = @posoco.Agent(
  exts=[
    model as &@posoco.Extension,
    store as &@posoco.Extension,
  ],
  config={
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  },
  events=events,
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "quickstart-session")
```

- **`Agent(exts~, config~, events~)` 接受三个参数**：扩展数组、配置和事件资源。
  `events` 必填，没有默认值或隐式创建；同一个 `EventSystem` 只能被一个 Agent
  接管。配置目前有四个字段：`max_tool_rounds`（一轮对话里最多几波工具调用，
  `None` = 不设上限，推荐默认）、`temperature`、`max_output_tokens`、
  `model_context_window`（模型上下文窗口，Agent 据此判断何时需要压缩）。
- **组装对真正必需的能力 fail-fast**。缺模型、工具重名会在构造时立刻抛
  `CompositionError`；会话存储是可选能力：
  - 没有任何扩展提供模型 → `CompositionError::MissingModel`
  - 没有 `SessionPort` → Agent 仍可运行，但 session 仅存在于当前 turn 的执行上下文，不做跨 turn 持久化
  - 两个扩展注册了同名工具 → `CompositionError::ToolCollision`
    （没有"后声明覆盖前声明"的兜底）
- **`run_turn` 是 async 的**。调用它的函数或测试也应是 async。第二个参数是
  session id：同一个 id 会加载之前保存的记录，继续同一段对话。
- **一个 turn 最多产生一个结局**：成功返回 `TurnResult`（包含最终回复消息、
  工具结果列表、最终的 session id）；失败抛 `AgentError`。模型调用、会话读写、
  hook 中止等主路径失败都会以 `AgentError` 的形式传给你。

## 5. 验证

从仓库根目录运行独立的离线示例：

```bash
moon -C examples/quickstart check --target native --deny-warn --output-json .
moon -C examples/quickstart test --target native --deny-warn --output-json .
moon -C examples/quickstart run --target native .
```

可执行程序输出 `Hello from the Posoco quickstart.`。测试同时检查 user + assistant
完整历史已保存，以及下面的事件接入行为；不需要模型 API key 或网络请求。

## 6. 再加一个强类型事件

完整示例还演示了普通对象、扩展与宿主之间的通知，不需要自己创建 EventBus：

0. `main` 先创建 `let system = @posoco.EventSystem()`。这个资源在没有 Agent 时就能
   授权、接听和发布，是宿主唯一需要管理的对象。
1. [`events.mbt`](../examples/quickstart/events.mbt) 定义封闭的 `QuickstartProgress`
   ADT，再为开放的 `@posoco.Event` 添加 `QuickstartChanged(QuickstartProgress)`。
2. 普通对象用 `system.publisher(owner="quickstart_reporter")` 取得自己的 `Events`：
   它不实现 `Lifecycle`，也不持有 Agent，发布身份固定为
   `Extension("quickstart_reporter")`。这份能力在 Agent 接管资源后仍然有效。
3. 扩展的 manifest 声明 `requires: [@posoco.Capability::Events]` 和
   `lifecycle: [self]`，在 `Lifecycle::on_compose` 取得 `view.events()`——扩展入口不变。
4. 宿主在组合之前用 `system.subscribe(...)` 接听，组合之后也可以用
   `agent.subscribe_events(...)`；两者共享同一资源。示例用
   `namespace_=Some(@posoco.EventNamespace::Extension("quickstart"))` 接听该扩展。
5. 扩展在 `Lifecycle::on_start` 发布 `QuickstartChanged(Started)`，宿主直接匹配 ADT；
   Agent 把来源绑定到 manifest id。核心另有保留的 `Posoco` 命名空间，但共用同一系统。
6. 用返回的 `Subscription::cancel()` 取消接听；`agent.shutdown()` 关闭资源，之后
   获取 publisher、发布、订阅都返回 `Err(Closed)`。事件没有重放，回调同步、不可抛错，
   因此应先订阅后发布，社区载荷使用不可变值。

资源规则（完整契约见 [`src/events/MIGRATION.md`](../src/events/MIGRATION.md)）：
接管之前的 `publisher` / `subscribe` / `publish` 都可用；接管是独占的，第二个 Agent
复用同一资源会被拒绝（`CompositionError::EventSystemAlreadyOwned`），且不影响第一个
Agent；接管之后的任何构造失败会关闭资源并撤销已发出的能力；turn 失败或取消不关闭；
宿主不能直接关闭已接管的系统（`Err(Owned)`），只能经 `Agent::shutdown` 关闭。

这不是改写模型调用或审批工具的机制：拦截仍用 `Hook`；原有 `Observer` 仍只收核心通知。
扩展间接听使用同一个 `events.subscribe`。完整说明见
[quickstart README](../examples/quickstart/README.md) 和
[开发指南的 Events 一节](./04-developer-guide.md#41-社区协议与宿主接听events)。

## 7. 下一步

- 想知道 Posoco 为什么这样设计、turn 内部发生了什么 → [02 架构入门](./02-architecture.md)
- 想给 Agent 加工具、Observer、Hook 等更多端口 → [03 端口配方](./03-trait-recipes.md)
- 想把多个扩展组合成一个像样的产品 → [04 开发指南](./04-developer-guide.md)
- 想让模型回复流式输出，而不是等完整结果 → [05 流式指南](./05-streaming-guide.md)