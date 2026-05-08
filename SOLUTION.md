# lark-bot2bot 完整方案

## 一、原始需求

在飞书群聊中，让多个 AI 机器人围绕一个话题自动讨论。用户发起话题后，机器人之间自主接力对话，无需人工中继。

**核心场景**：用户同时拥有 OpenClaw 驱动的 Lucie 和 Hermes Agent 驱动的 Lumi 两个飞书机器人，希望把它们拉到同一个群里，发起一个话题让它们自动讨论，并支持以下停止规则：
- 执行 N 轮后自动停止
- 达成一致自动停止
- 用户主动介入停止

**讨论模式需求**：
- 辩论（debate）：双方各持立场，逐轮交锋
- 评审（review）：一方出方案，另一方质疑挑战
- 头脑风暴（brainstorm）：互相补充发散，遵循 Yes, and 原则
- 自由对话（freeform）：开放式交流

## 二、实现方案探索

### 2.1 飞书平台能力验证

#### 飞书 bot-to-bot 事件推送

2026.04.08 版本起，飞书支持机器人在群聊中接收其他机器人的 @消息（需开通 `im:message.group_at_msg.include_bot:readonly` 权限）。实测验证：

| 方式 | 格式 | 是否触发 im.message.receive_v1 |
|------|------|------|
| Bot 直接发消息 @Bot | text `<at user_id="...">` | ✅ |
| Bot 直接发消息 @Bot | post `{tag: "at", user_id: "..."}` | ✅ |
| Bot 发 interactive 卡片含 `<at id=...>` | interactive | ✅ |
| 编辑消息追加 @mention | text / post | ❌ |
| 删除原消息重发 | - | ✅ 但有"已撤回"提示 |
| 用户发消息 @Bot | - | ✅ |

#### 跨 App open_id 映射

飞书 open_id 是应用作用域的。同一个 bot 在不同 app 视角下有不同的 open_id：

| 视角 | Lucie 的 open_id | Lumi 的 open_id |
|------|-----------------|-----------------|
| Lucie app | ou_79d... (self) | ou_138... |
| Lumi app | ou_ac9... | ou_dc0... (self) |

获取方式：用各自 bot 的 tenant_access_token 调 `GET /im/v1/chats/{chat_id}/members/bots`。

### 2.2 方案一：飞书原生 @mention 链路

**思路**：Bot A 回复时在消息中 @Bot B → 飞书推送事件给 Bot B → Bot B 回复并 @Bot A → 自动接力。

**问题**：Bot 框架（OpenClaw / Hermes）的消息发送层不会自动把 LLM 输出的 `@Name` 纯文本转成飞书的 `{tag: "at"}` 结构化元素。

具体验证：
- OpenClaw 的 `buildPostContent()` 把所有内容包裹在 `{tag: "md"}` 中，`<at>` 标签在 md 里只是视觉渲染，不产生 mention 元数据
- Hermes 的 `_build_outbound_payload()` 直接把 LLM 输出当纯文本发送
- LLM 入站时看到的是 `@Name`（飞书已转换），不会输出 `<at>` 标签格式

**结论**：需要改两个框架的出站层代码。已给 OpenClaw 提交 PR（[#480](https://github.com/larksuite/openclaw-lark/pull/480)），但未合并前此方案不可用。

### 2.3 方案二：卡片消息触发

**思路**：脚本以 bot 身份发 interactive 卡片（含 `<at id=...>`），卡片的 @mention 能触发对方 bot。

**验证结果**：
- ✅ Lucie 卡片 @Lumi → Lumi 收到并回复
- ✅ Lumi 卡片 @Lucie → Lucie 收到并回复
- ❌ Bot 收到卡片 @mention 后会自动回复一条消息（噪音），脚本的卡片和 bot 的回复是两条消息

**结论**：双份消息无法避免，体验不好。

### 2.4 方案三：Skill + Tool（安装在 bot 上）

**思路**：Skill 安装在两个 bot 上，定义自定义 tool（如 `send_debate_reply`），LLM 通过 tool call 发送带 @mention 的消息。

**问题**：
- Hermes 在 tool 执行后总会再调一次 LLM 生成文本回复并发到群里，无法 suppress
- OpenClaw 没有内置 message send tool
- 仍然是双份消息

**结论**：框架层面的限制，不改代码无法解决。

### 2.5 方案四：编排器模式（最终选型）

**思路**：编排器脚本通过 CLI 直接调用两个 bot 的 LLM 获取回复，然后以各自 bot 的 tenant_access_token 在群里发消息展示。消息不含 @mention，不触发任何 bot 的事件处理。

**验证结果**：
- ✅ `openclaw agent --agent main --message "..." --json` 可正常调用并返回回复
- ✅ `hermes chat -q "..." -Q` 可正常调用并返回回复
- ✅ 以 bot token 发的 post 消息（不含 @mention），bot 框架不自动回复（`requireMention: true`）
- ✅ 飞书 reply API（`POST /im/v1/messages/{message_id}/reply`）可形成消息引用链
- ✅ 完整 2 轮讨论端到端验证通过，群里零噪音

## 三、最终方案选型

### 3.1 架构

```
用户发起讨论（通过 Claude Code / OpenClaw / Hermes / CLI）
        │
        ▼
   ┌──────────┐
   │  编排器   │  ← Skill 入口 + arena 脚本
   └────┬─────┘
        │
   ┌────┴────┐
   │         │
   ▼         ▼
openclaw    hermes        ← 通过 CLI 调用 LLM
 agent       chat
   │         │
   │         │
   ▼         ▼
  飞书 API               ← 以各自 bot token 发 post 消息（reply 模式）
   │
   ▼
 飞书群聊                 ← 零噪音消息流
```

### 3.2 消息流

```
[Lucie]  RAG 更适合客服...  _(1/2 · Lucie)_
  └─ [Lumi]  不同意，Fine-tuning...  _(1/2 · Lumi)_    ← reply Lucie
       └─ [Lucie]  关于成本...  _(2/2 · Lucie)_         ← reply Lumi
            └─ [Lumi]  综合来看...  _(2/2 · Lumi)_      ← reply Lucie
[编排器]  ⏹ 讨论结束（2轮）
```

每条消息 reply 上一条的 message_id，飞书自动显示引用关系，形成连贯的讨论链。

### 3.3 核心流程

1. **用户输入**：描述话题、模式、参与者、轮次、停止条件
2. **Skill 解析**：LLM 识别意图 → 匹配讨论模式 → 补全参数 → 展示确认
3. **用户确认**：确认后启动编排脚本
4. **编排循环**：
   - 调 Bot A 的 CLI 获取回复（传入话题 + 上轮对方观点）
   - 以 Bot A 的 token 发 post 消息到群里（reply 上一条消息）
   - 记录 message_id
   - 调 Bot B 的 CLI 获取回复（传入 Bot A 的观点）
   - 以 Bot B 的 token 发 post 消息到群里（reply Bot A 的消息）
   - 检查停止条件（轮次 / 共识 / 超时）
5. **结束**：发停止消息 + 讨论摘要

### 3.4 脚本硬规则

| 规则 | 实现 |
|------|------|
| 轮次计数 | 脚本计数，达到用户设定轮次 → 停止 |
| 硬上限兜底 | 无论设多少轮，不超过 30 轮 |
| 超时保护 | CLI 调用超时 90s → 跳过当前 bot，触发下一轮或结束 |
| 共识检测 | 检测回复中的共识标记（如"✅ 共识达成"） |
| 用户介入 | 脚本监听用户输入，用户说"停止"则结束 |
| 回复格式 | reply 上一条 message_id，保证引用链连贯 |
| 上下文管理 | 每轮传入完整讨论历史（或最近 N 轮摘要） |

### 3.5 四个讨论模式 Prompt 模板

#### 辩论 (debate)
```
你正在参与一场结构化辩论。你的立场：{{role}}

每轮回复遵循以下结构：
1. 【核心主张】一句话表明观点
2. 【论据】2-3 个具体理由，用数据/案例/逻辑支撑
3. 【回应对方】针对对方上一轮具体论点：同意什么、反驳什么、为什么
4. 【追问】向对方提一个具体问题

规则：
- 不允许空洞附和，每轮必须有新论据或新角度
- 反驳必须针对具体论点，不能稻草人
- 如果被说服，诚实承认，标注「✅ 共识达成：...」
```

#### 评审 (review)
```
【提案者】首轮：问题定义 → 方案描述 → 选型理由 → 已知风险
被质疑后：逐条回应（接受/拒绝/部分接受）→ 方案修订

【评审者】总体评价 → 按维度逐条列出问题（可行性/完整性/性能/安全/可维护性）
每条：问题描述 → 风险等级（高/中/低）→ 改进建议
```

#### 头脑风暴 (brainstorm)
```
遵循 "Yes, and..." 原则：先肯定，再延伸。不否定、不批评。

每轮回复：
1. 【共鸣点】对方哪个想法触发了灵感
2. 【延伸】在此基础上往前推一步，或组合产生新东西
3. 【新方向】至少 1 个完全不同角度的新想法
4. 【探索问题】"如果...会怎样？"打开新空间
```

#### 自由对话 (freeform)
```
开放式对话，无固定结构。
围绕主题展开，对有趣观点追问或深入探讨，有不同看法直接说。
```

## 四、支持的场景组合

### 4.1 同机器（local-cli）

编排器和所有参与 bot 在同一台机器上，通过本地 CLI 调用：

| 组合 | 支持 | 说明 |
|------|------|------|
| OpenClaw + Hermes | ✅ | 默认场景，两个不同框架的 bot 协作 |
| OpenClaw + OpenClaw | ✅ | 需使用不同的 agent ID 区分 |
| Hermes + Hermes | ✅ | 需使用不同的 session 区分 |

配置示例：

```yaml
participants:
  - name: Lucie
    bot_app_id: cli_a927dc45c978dbcc
    bot_app_secret: "***"
    type: local-cli
    command: "openclaw agent --agent main --message '{message}' --json"
    parse: "jq '.result.payloads[0].text'"

  - name: Lumi
    bot_app_id: cli_a95222a337f8dcd3
    bot_app_secret: "***"
    type: local-cli
    command: "hermes chat -q '{message}' -Q"
    parse: "grep -v '^session_id:' | grep -v '^$'"
```

### 4.2 异地（http-api）

编排器在本地，远程 bot 通过 HTTP API 调用：

| 组合 | 支持 | 说明 |
|------|------|------|
| OpenClaw(本地) + Hermes(远程) | ✅ | 本地 CLI 调 OpenClaw，HTTP API 调远程 Hermes |
| Hermes(本地) + Hermes(远程) | ✅ | 本地 CLI + 远程 HTTP API |
| OpenClaw + OpenClaw 异地 | ❌ | OpenClaw 暂不支持 HTTP chat API |

异地场景需在远程 Hermes 的 `.env` 中启用 API server：

```
API_SERVER_ENABLED=true
API_SERVER_KEY=your-secret-key
```

远程 Hermes 配置示例：

```yaml
  - name: Lumi
    bot_app_id: cli_a95222a337f8dcd3
    bot_app_secret: "***"
    type: http-api
    endpoint: "http://lumi-host:8642/v1/chat/completions"
    api_key: "your-secret-key"
    model: "hermes-agent"
```

### 4.3 讨论模式扩展

用户可在 `templates/` 目录下添加自定义模式模板（Markdown 文件），skill 自动识别。

### 4.4 @mention 链路（未来优化）

当 OpenClaw PR [#480](https://github.com/larksuite/openclaw-lark/pull/480) 合并后，bot 自己的回复可以直接携带有效 @mention。届时可切换为"去中心化模式"——不需要编排器，bot 之间通过飞书原生事件自主接力。Skill 安装在两个 bot 上，各自遵循讨论协议。

## 五、具体部署方法

### 5.1 前置条件

| 条件 | 说明 | 必须 |
|------|------|------|
| OpenClaw 运行中 | `openclaw agent` 命令可用 | 至少一个 bot |
| Hermes 运行中 | `hermes chat` 命令可用 | 至少一个 bot |
| 飞书 bot credentials | 每个 bot 的 app_id + app_secret | 是 |
| 飞书群 | 两个 bot 都在同一个群里 | 是 |
| 群配置 requireMention: true | 防止 bot 对编排器消息自动回复 | 是 |
| curl | 调飞书 API 发消息 | 是（系统自带） |

**不需要**：lark-cli、飞书 bot-to-bot 权限、任何框架代码改动。

### 5.2 安装 Skill

Skill 安装在任何能执行 shell 的 AI 助手上（Claude Code / OpenClaw / Hermes）：

```bash
# Claude Code
cd ~/.claude/skills && git clone https://github.com/iamkentzhu/lark-bot2bot.git

# OpenClaw（放到 skills 加载目录）
cp -r lark-bot2bot /path/to/openclaw-skills/

# Hermes（放到 skills 目录）
cp -r lark-bot2bot /path/to/hermes-skills/
```

### 5.3 配置参与方

创建 `config.yaml`：

```yaml
chat_id: "oc_ab9a8a40e19a543831806510166d53af"

participants:
  - name: Lucie
    bot_app_id: cli_a927dc45c978dbcc
    bot_app_secret: "your-secret"
    type: local-cli
    command: "openclaw agent --agent main --message '{message}' --json"
    parse: "jq -r '.result.payloads[0].text'"

  - name: Lumi
    bot_app_id: cli_a95222a337f8dcd3
    bot_app_secret: "your-secret"
    type: local-cli
    command: "hermes chat -q '{message}' -Q"
    parse: "grep -v '^session_id:' | grep -v '^$'"

defaults:
  max_rounds: 3
  timeout_seconds: 90
  hard_limit: 30
```

### 5.4 使用

```
用户：使用 bot2bot 技能开启一次机器人协作

Skill：好的，请描述讨论任务。示例：
  "让 Lucie 和 Lumi 辩论 RAG vs Fine-tuning，3轮"
  "Lucie 提一个 API 限流方案，Lumi 做评审，2轮"
  "Lucie 和 Lumi 一起头脑风暴用户留存策略"

用户：让 Lucie 和 Lumi 辩论微服务 vs 单体，Lucie 主张微服务，Lumi 关注成本，3轮

Skill：
  📋 讨论方案
  话题：微服务 vs 单体架构
  模式：辩论
  参与者：Lucie（主张微服务） / Lumi（关注成本）
  轮次：3 轮
  群聊：[群名称]
  确认发起？

用户：确认

Skill：讨论已启动...（执行编排脚本）
```

### 5.5 Preflight 检查

脚本启动前自动检查：

```
✅ openclaw agent: 可用
✅ hermes chat: 可用
✅ Lucie token: 获取成功
✅ Lumi token: 获取成功
✅ 群 oc_xxx: Lucie ✓ Lumi ✓
→ 前置检查通过，开始讨论
```

不通过时给出具体修复指引。

## 六、项目结构

```
lark-bot2bot/
├── skill.md                    # Skill 入口（触发词、交互流程、使用示例）
├── config.example.yaml         # 参与方配置示例
├── references/
│   ├── script-rules.md         # 脚本硬规则说明
│   └── prompt-protocol.md      # Prompt 模板规范
├── templates/
│   ├── debate.md               # 辩论模式
│   ├── review.md               # 评审模式
│   ├── brainstorm.md           # 头脑风暴
│   └── freeform.md             # 自由对话
├── scripts/
│   ├── arena.sh                # 核心编排脚本
│   └── preflight.sh            # 前置检查
└── README.md
```
