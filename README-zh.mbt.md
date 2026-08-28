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
moon add colmugx/posoco@0.13.1
```

## Port

Port 是 Posoco 核心与 agent 所用能力之间唯一的接缝。

| Port | 作用 |
|---|---|
| `ModelPort` | 模型调用 + 上下文压缩（`chat`、`compact`、`provider_config`） |
| `ToolProvider` | 工具发现与执行 |
| `SessionStore` | 会话加载 / 保存 |
| `Observer` | 只读 turn 事件观察 |
| `Hook` | 单 trait 带默认方法的管线拦截：模型前改写消息或中止（`before_model`）、工具前审批/推迟/拒绝（`before_tool`）、每个效果后只读（`on_post_event`） |
| `MemoryPort` | 长期记忆存储与检索 |
| `Lifecycle` | 关闭时的 async 资源清理 |
| `CommandPort` | 用户侧 slash 命令枚举与调用 |
| `UiPort` | 结构化 UI 意图 + 交互请求（Status / Notice / Widget / Input / Confirm / Select） |
| `SystemPromptContributor` | 声明 system prompt 段落（拼装并在模型调用前注入） |
| `Extension` | 自报家门协议：`extension_id` + `manifest` 声明本扩展贡献哪些 port |
| `ProviderConfig` | 模型侧 provider 配置（伴随类型，非运行时 port） |

## 创建一个扩展

扩展是一个 struct，它实现一个或多个 port trait，**并且**实现
`@posoco.Extension`。同一个 `self` 引用放进 manifest 中该 struct 实现的每个
port 槽位；`id` 字符串只用于组合诊断（工具冲突消息、observer 归因），不参与
路由或持久化。

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
///    其余保持空数组。
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_read",
    models: [],
    tools: [self],
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
/// 3. 暴露 Extension 方法，使点号调用可用，并让 `&ReadTools` 能在
///    `Array[&@posoco.Extension]` 中隐式转换为 `&@posoco.Extension`。
pub extend ReadTools with @posoco.Extension::{extension_id, manifest}

///|
/// 4. 可选工厂：供用默认值构造的宿主使用。
pub fn read_extension() -> ReadTools {
  ReadTools::ReadTools()
}
```

如果是 `ModelPort` 扩展，把 `self` 放到 `models: [self]`，`tools` 留空

## 组合一个 agent

agent 开发者导入扩展包，把扩展实例接进一个 `Agent`。`exts` 是自报家门扩展
的数组——与顺序无关；Agent 聚合它们的 manifest。

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
- `EmptyPort("SessionStore")`——没有扩展贡献必需的 port

已发布 `TurnStarted` 的 turn 恰好发布一个 terminal event：成功为
`TurnCompleted`，任何主路径失败为 `TurnFailed`。

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
moon check
moon test
moon fmt
moon info
```

## 为什么叫 Posoco？

"Posoco" 取自 **persocom**。来自 CLAMP 漫画《人形电脑天使心》（Chobits）里的人形电脑（persocom）。因为 Posoco 项目是从 Elyra 的架构指导思想里拆出来的 agent runtime，所以取谐音 Posoco。

## License

Apache-2.0。
