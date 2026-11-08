# Posoco

一个 MoonBit LLM Agent 框架

核心拥有 agent loop 及其不变量，所有运行时能力——model、tool、session、observer、hook、UI、
command、prompt、memory、lifecycle——都通过开放的 port trait 注入。产品通过
`Agent(exts~, config~, events~)` 唯一入口组合；核心不规定形态。

> **API 文档：** <https://mooncakes.io/docs/colmugx/posoco> · **English README:**
> [`README.mbt.md`](./README.mbt.md)
>
> **WARNING：** Posoco 处于实验阶段（0.x），公开 API 随时可能变动。

## 安装

```bash
moon add colmugx/posoco@0.24.2
```

## Port

Port 是 Posoco 核心与 agent 所用能力之间唯一的接缝。

| Port | 作用 |
|---|---|
| `ModelPort` | 模型调用 + 上下文压缩（`chat`、`compact`、`provider_config`） |
| `DecisionPort` | provider-neutral 的结构化语义判断 |
| `ToolProvider` | 工具发现与执行 |
| `LogPort` | 结构化应用日志，调用方选择持久化强度 |
| `SessionPort` | 会话加载 / 保存 |
| `Observer` | 只读 turn 事件观察 |
| `Hook` | 单 trait 带默认方法的管线拦截：模型前改写消息或中止（`before_model`）、工具前审批/推迟/拒绝（`before_tool`）、每个效果后只读（`on_post_event`） |
| `MemoryPort` | 长期记忆存储与检索 |
| `Lifecycle` | 组合期能力接线、一次性 async 启动、关闭清理 |
| `CommandPort` | 用户侧 slash 命令枚举与调用 |
| `UiPort` | 结构化 UI 意图 + 交互请求（Status / Notice / Widget / Input / Confirm / Select）——旧适配层，见 [UI 协议](#ui-协议) |
| `SystemPromptContributor` | 声明 system prompt 段落（拼装并在模型调用前注入） |
| `Extension` | 自报家门协议：`extension_id` + `manifest` 声明本扩展贡献哪些 port |
| `ProviderConfig` | 模型侧 provider 配置（伴随类型，非运行时 port） |

## 创建一个扩展

扩展是一个 struct，它实现一个或多个 port trait，**并且**实现
`@posoco.Extension`。同一个 `self` 引用放进 manifest 中该 struct 实现的每个
port 槽位。manifest 的 `id` 用于组合诊断，也绑定本扩展的事件发布命名空间；
声明 `Events` 能力的扩展，其 id 必须在 Agent 内唯一。

最小形态：两个方法加一行 `pub extend`：

```moonbit nocheck
// 1. 实现你的扩展要贡献的 port trait。
//    （此处展示 ToolProvider；实现体省略。）

///|
pub impl @posoco.Extension for ReadTools with fn extension_id(_self) -> String {
  "posoco_ext_read"
}

///|
/// 2. 声明 ReadTools 贡献哪些 port。同一个 `self` 放进它实现的每个槽位，
///    省略的槽位默认为空数组。
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_read", tools=[self])
}

///|
/// 3. 暴露 Extension 方法，使点号调用可用，并让 `&ReadTools` 能在
///    `Array[&@posoco.Extension]` 中隐式转换为 `&@posoco.Extension`。
pub extend ReadTools with @posoco.Extension::{extension_id, manifest}

///|
/// 4. 可选工厂：供用默认值构造的宿主使用。
pub fn read_extension() -> ReadTools {
  ReadTools::ReadTools()
}
```

如果是 `ModelPort` 扩展，把 `self` 放到 `models: [self]`：
`ExtensionManifest(id=..., models=[self])`。

## 组合一个 agent

agent 开发者导入扩展包，把扩展实例接进一个 `Agent`。`exts` 是自报家门扩展
的数组；Agent 聚合它们的 manifest。扩展顺序决定 hook、observer、lifecycle 的
注册顺序，但不提供工具重名时的「后声明覆盖前声明」。

```moonbit nocheck
// 宿主为每个 Agent 持有一个事件资源。先创建它：ports 和普通对象可能在 Agent
// 存在之前就需要自己的 owner-bound `Events`。
let system = @posoco.EventSystem()

let agent = @posoco.Agent(
  exts=[
    model_ext,   // 贡献 ModelPort 的扩展
    read_ext,    // 上面构造的 ReadTools 扩展，贡献 ToolProvider
  ],
  config={
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  },
  events=system,
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "session_1")
```

`events~` 是必填参数：Posoco 不再隐式创建事件资源。组合会独占接管该值，
一个 `EventSystem` 只服务一个 Agent。

`AgentConfig` 有四个字段：`max_tool_rounds`（`Int?`，`None` 为无界、是推荐默认；
`Some(n)` 放行 n 个完整工具轮）、`temperature`、`max_output_tokens`、`model_context_window`。`run_turn(message, session_id)`
是 async 方法，会 raise `AgentError`。组合是 fail-fast 的，raise
`CompositionError`：

- `MissingModel`——没有任何扩展贡献 `ModelPort`
- `MultipleModels`——多个扩展直接贡献 `ModelPort`（多 model 路由应由
  meta-ext 如 `posoco-ext-llm` 在内部解决，而非核心）
- `ToolCollision`——两个扩展注册了同名工具（没有 last-wins）
- `SessionPort` 是可选的；未提供时 Agent 以 ephemeral 模式运行，不做持久化 session 写入

已发布 `TurnStarted` 的 turn 恰好发布一个 terminal event：成功为
`TurnCompleted`，任何主路径失败为 `TurnFailed`，被取消（软 abort、硬取消、
Agent shutdown、取消的 resume）为 `TurnCancelled`。取消不会被伪装成失败：
调用方拿到的仍是 typed `AgentError::Cancelled`，operation 结算为 `cancelled`。
取消 compact 不会发布任何 turn 事件——compact 是 operation，不是 turn。

## 强类型事件

Posoco 为每个 Agent 提供一套事件资源，核心通知与社区协议共用它。
协议包定义封闭的载荷 ADT，并为开放的 `@posoco.Event` 添加构造器；发布和接听
都直接使用类型化的值，不需要字符串 topic、JSON 编解码或向下转型。资源是实时的：
组合之前、之中、之后都能授权能力和投递通知，但它从不重放历史。

```moonbit nocheck
let system = @posoco.EventSystem()

// 普通对象（没有 Lifecycle 字段，也不持有 Agent）发布到 Extension("status_bar")。
// 该授权在 Agent 接管之后依然有效。
let granted = system.publisher(owner="status_bar") // Result[Events, EventError]

// 宿主可以在 Agent 存在之前接听。
let subscription = system.subscribe(
  envelope => handle(envelope),
  namespace_=Some(@posoco.EventNamespace::Extension("status_bar")),
)
```

- **宿主资源**：在 ports 之前创建 `EventSystem()`，把同一个值传给唯一一个
  `Agent(..., events=system)`。构造会独占接管；第二个 Agent 复用同一资源会被
  拒绝，且不影响第一个 Agent。
- **普通对象**：`system.publisher(owner~)` 授予绑定 `Extension(owner)` 的 `Events`，
  不需要 `Lifecycle`，也不需要 Agent。owner 由宿主指定，可以不是 manifest id。
- **宿主接入**：组合前用 `system.subscribe(handler, namespace_=...)`，组合后用
  `agent.subscribe_events(handler, namespace_=...)`；结束时 `cancel()`。
- **扩展接入**：manifest 声明 `requires: [@posoco.Capability::Events]` 并登记
  `Lifecycle`；在 `on_compose` 中取得 `view.events()`，之后调用
  `events.publish(event)` 或 `events.subscribe(handler, namespace_=...)`。
- **命名空间**：`Posoco` 命名空间保留给 `Core(TurnEvent)`；owner-bound 能力不能
  发布 `Core`。接听可选择任意命名空间，`None` 表示全部。
- **生命周期**：turn 失败或取消不关闭资源；接管之后的任何构造失败会关闭资源并
  撤销已发出的能力；`shutdown()` 关闭它。此后授权、发布、订阅返回 `Err(Closed)`，
  `cancel()` 仍幂等。直接关闭已接管的资源、或重复接管，都是 typed error，不会
  静默重开。
- **边界**：回调同步且不可抛错，按注册顺序投递并每批取快照，事件不重放。
  `Observer` 是同一系统里只收核心通知的适配器；`Hook` 仍负责拦截。通知不代替
  需要等待完成的 journal/checkpoint 提交。

端到端可运行示例（Agent 之前的普通 publisher、提前接听、typed 投递、
shutdown 后 `Closed`）见 [`examples/quickstart`](./examples/quickstart/README.md)；
完整资源契约与迁移步骤见 [`src/events/MIGRATION.md`](./src/events/MIGRATION.md)。

## UI 协议

`UiPort` 仍是旧的渲染 / 阻塞式 `request` 适配层。与它并列，Agent 还带一套状态
协议：扩展发布资源、发起结构化提问，宿主观察并作答。

- **扩展侧**：声明 `requires: [@posoco.Capability::Ui]`，在 `on_compose` 取
  `view.ui_resources()` / `view.ui_interactions()`。资源是 owner 绑定的
  （manifest id + 本地 key + 运行时 generation），发布即整块替换、revision 单调
  递增，更新用 `replace(expected=...)`，撤销要显式调用。`resources.operation()`
  返回绑定当前 admitted operation 的句柄，它发布的 `OperationBound` 资源会在该
  turn / compact 结算时自动回收。
- **宿主侧**：用 `agent.ui_host()`。一次 `snapshot()` 是同一切点上的 live 资源、
  pending 提问与两条游标；随后用 `changes_since` / `interactions_since` 拉取，
  或用 `subscribe` 收按提交顺序的推送。`dispatch` 把当前声明过的动作送回 owner
  扩展，回执只代表"受理"——结果状态走 change feed。`connect` 声明宿主能渲染和
  回答什么；没有匹配连接时阻塞提问立刻 `HostUnavailable`。
- **边界**：全部在进程内——游标、pending 提问与重放窗口都不跨 Agent 重启，没有
  跨进程恢复。`UiPort` 语义不变，也**不会**获得这些新保证。动作和答案都不带来
  tool/model/session 权限。

教程：[`posoco-101/13-ui-observe-and-ask.mbt.md`](./posoco-101/13-ui-observe-and-ask.mbt.md)；
契约：[`docs/ui-protocol.md`](./docs/ui-protocol.md)。

## 扩展库

[`colmugx/posoco-extension`](https://github.com/colmugx/posoco-extension) 维护了一套开箱即用的扩展，可直接接入 `Agent(exts~, config~, events~)`。

## 延伸阅读 — Posoco 101

[`posoco-101/`](./posoco-101/) 是按章节递进的课程，从"什么是 agent loop"
一直到组装一个 mini coding agent。大纲与章节状态在
[`posoco-101/OUTLINE.md`](./posoco-101/OUTLINE.md)：

| # | 章节 | 状态 |
|---|---|---|
| 01 | Agent Loop 原理：怎么自己写一个 Agent | ✅ |
| 02 | 用 Posoco 写你的第一个 Agent（10 行） | ✅ |
| 03–12 | 扩展组合、Tool Use、Routing、Reflection、Parallelization、Planning、Memory、Observer、typed error、capstone | 计划中 |
| 13 | 让 Agent 的界面可被宿主观察：UI 资源、push 观察、结构化提问 | ✅ |
| 14 | 流式事件的身份：scope、丢失提示与最终响应 | ✅ |
| 15 | 多宿主与无人应答：能力协商和阻塞式快速失败 | ✅ |
| 16 | 取消不是失败：turn 的三种终态 | ✅ |

## 开发与验证

```bash
moon check --output-json
moon test --output-json
moon fmt
moon info
```

## 为什么叫 Posoco？

"Posoco" 取自 **persocom**。来自 CLAMP 漫画《人形电脑天使心》（Chobits）里的人形电脑（persocom）。因为 Posoco 项目是从 Elyra 的架构指导思想里拆出来的 agent runtime，所以取谐音 Posoco。

## License

Apache-2.0。
