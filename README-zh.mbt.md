# Posoco

一个 MoonBit LLM Agent 框架

核心拥有 agent loop 及其不变量，所有运行时能力——model、tool、session、observer、hook、UI、
command、prompt、memory、lifecycle——都通过开放的 port trait 注入。产品通过
`Agent(exts~, config~)` 唯一入口组合；核心不规定形态。

> **API 文档：** <https://mooncakes.io/docs/colmugx/posoco> · **English README:**
> [`README.mbt.md`](./README.mbt.md)
>
> **WARNING：** Posoco 处于实验阶段（0.x），公开 API 随时可能变动。

## 安装

```bash
moon add colmugx/posoco@0.24.0
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
| `UiPort` | 结构化 UI 意图 + 交互请求（Status / Notice / Widget / Input / Confirm / Select） |
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
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "session_1")
```

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
`TurnCompleted`，任何主路径失败为 `TurnFailed`。

## 强类型事件

Posoco 为每个 Agent 提供一套事件系统，核心通知与社区协议共用它。
协议包定义封闭的载荷 ADT，并为开放的 `@posoco.Event` 添加构造器；发布和接听
都直接使用类型化的值，不需要字符串 topic、JSON 编解码或向下转型。

- **扩展接入**：manifest 声明 `requires: [@posoco.Capability::Events]` 并登记
  `Lifecycle`；在 `on_compose` 中取得 `view.events()`，之后调用
  `events.publish(event)` 或 `events.subscribe(handler, namespace_=...)`。
- **宿主接入**：调用 `agent.subscribe_events(handler, namespace_=...)`，结束时对
  返回的 `Subscription` 调用 `cancel()`。无需创建总线或接触内部运行时。
- **命名空间**：发布身份绑定为 `Extension(manifest_id)`。`Posoco` 命名空间保留给
  `Core(TurnEvent)`；扩展不能发布 `Core`。接听可选择任意命名空间，`None` 表示全部。
- **边界**：回调同步且不可抛错，事件不重放，shutdown 后保留的能力返回关闭错误。
  `Observer` 仍然可用，是同一系统里只收核心通知的适配器；`Hook` 仍负责拦截。
  通知不代替需要等待完成的 journal/checkpoint 提交。

## 扩展库

[`colmugx/posoco-extension`](https://github.com/colmugx/posoco-extension) 维护了一套开箱即用的扩展，可直接接入 `Agent(exts~, config~)`。

## 延伸阅读 — Posoco 101

[`posoco-101/`](./posoco-101/) 是按章节递进的课程，从"什么是 agent loop"
一直到组装一个 mini coding agent。大纲与章节状态在
[`posoco-101/OUTLINE.md`](./posoco-101/OUTLINE.md)：

| # | 章节 | 状态 |
|---|---|---|
| 01 | Agent Loop 原理：怎么自己写一个 Agent | ✅ |
| 02 | 用 Posoco 写你的第一个 Agent（10 行） | ✅ |

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
