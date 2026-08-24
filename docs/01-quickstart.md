# 01 — 快速上手

十分钟之内，让一个最小的 Posoco Agent 跑起来：自己实现一个模型、一个会话存储，
把它们组装成 Agent，然后跑一轮对话。完整可运行示例在
[`examples/quickstart`](../examples/quickstart/)。

## 1. 先认识三个概念

Posoco 只有三个核心概念，后面所有内容都是围绕它们展开的：

- **端口（Port）**：一组由 Posoco 定义的能力接口（trait）。比如「接入一个大模型」
  是 `ModelPort`，「存取对话记录」是 `SessionStore`，「提供工具」是 `ToolProvider`。
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
  messages : Array[@posoco.Message],
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
  { completion, processed_messages: messages.copy() }
}

pub impl @posoco.ModelPort for FixedModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : Array[@posoco.Message],
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
  let manifest = @posoco.ExtensionManifest::empty(id="quickstart-model")
  { ..manifest, models: [self] }
}

pub extend FixedModel with @posoco.Extension::{extension_id, manifest}
```

逐段解释一下：

- **消息是 ADT，不是字典**。对话消息是 `@posoco.Message` 枚举
  （`UserMessage` / `AssistantMessage` / `SystemMessage` / `ToolMessage`），
  不是带 `role` 字段的 record。文本内容用 `Content::Text` 包装。
- **`chat` 返回两部分**：`completion` 是模型这次的回复
  （文本、工具调用、推理内容、结束原因、用量），`processed_messages` 是你真正
  发给 provider 的消息副本。Agent 会用这份副本替换对话记录——如果你没有做任何
  预处理，原样返回收到的 `messages` 的副本即可。
- **`InvocationScope` 是这次调用的身份**：里面记着这次调用服务于哪个 session、
  哪次 run。需要按会话区分行为（遥测、计费、按会话切换策略）时从它读取，
  不需要就忽略。把它当作只读的。
- **不支持的能力要大声失败**：`compact` 不支持就 raise `ModelError`，不要假装
  成功——那会掩盖真实的问题。
- **`manifest` 里登记自己**：`models: [self]` 意思是"我提供一个模型端口"。
  最后一行 `pub extend ...` 是 MoonBit 的语法糖，让 `extension_id` / `manifest`
  成为可直接调用的方法。

## 3. 第二步：实现一个会话存储

Agent 需要把对话记录存下来，跨 turn 保持连续性。这就是 `SessionStore`：两个方法，
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

pub impl @posoco.SessionStore for MemoryStore with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => copy_session(session)
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

pub impl @posoco.SessionStore for MemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = copy_session(session)
}
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
)

let input : @posoco.Message = @posoco.UserMessage(content=[
  @posoco.Content::Text("hello"),
])
let result = agent.run_turn(input, "quickstart-session")
```

- **`Agent(exts~, config~)` 只接受两个参数**：扩展数组和配置。配置目前有四个
  字段：`max_tool_rounds`（一轮对话里最多几波工具调用，`None` = 不设上限，
  推荐默认）、`temperature`、`max_output_tokens`、`model_context_window`
  （模型上下文窗口，Agent 据此判断何时需要压缩）。
- **组装是 fail-fast 的**。缺模型、缺存储、工具重名，都会在构造时立刻抛
  `CompositionError`，绝不带着残缺的配置运行：
  - 没有任何扩展提供模型 → `CompositionError::MissingModel`
  - 没有扩展提供会话存储 → `CompositionError::EmptyPort("SessionStore")`
  - 两个扩展注册了同名工具 → `CompositionError::ToolCollision`
    （没有"后声明覆盖前声明"的兜底）
- **`run_turn` 是 async 的**。调用它的函数或测试也应是 async。第二个参数是
  session id：同一个 id 会加载之前保存的记录，继续同一段对话。
- **一个 turn 最多产生一个结局**：成功返回 `TurnResult`（包含最终回复消息、
  工具结果列表、最终的 session id）；失败抛 `AgentError`。模型调用、会话读写、
  hook 中止等主路径失败都会以 `AgentError` 的形式传给你。

## 5. 验证

```bash
rtk moon check --output-json
rtk moon test --output-json -f 'quickstart_fixture*'
```

测试应显示 `1/1 passed`。这个 fixture 覆盖了：消息与 `Completion` 的构造、
`Agent(exts~, config~)` 的组合签名、`run_turn` 的调用与返回的 session id、
以及 session store 通过公开 trait 被注入。

## 6. 下一步

- 想知道 Posoco 为什么这样设计、turn 内部发生了什么 → [02 架构入门](./02-architecture.md)
- 想给 Agent 加工具、Observer、Hook 等更多端口 → [03 端口配方](./03-trait-recipes.md)
- 想把多个扩展组合成一个像样的产品 → [04 开发指南](./04-developer-guide.md)
- 想让模型回复流式输出，而不是等完整结果 → [05 流式指南](./05-streaming-guide.md)