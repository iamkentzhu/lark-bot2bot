# lark-debate-arena 设计方案

> 让飞书群里的多个 AI 机器人围绕一个话题自动互 @讨论，由脚本硬规则保障流程稳定，prompt 模板保障讨论质量。

## 前提条件

- 飞书 2026.04.08+ 版本支持 bot 在群聊中接收其他 bot 的 @消息（`im.message.receive_v1` 可推送 bot→bot 消息）
- OpenClaw 飞书插件 >= 2026.4.8
- Hermes Agent `FEISHU_ALLOW_BOTS=mentions` 或 `all`

## 核心定位

**Skill 是讨论保障层，不是编排器。**

- 帮用户生成高质量的发起消息
- 脚本硬规则保障 bot-to-bot @mention 链条不断裂
- 自动执行停止控制

## 两层控制机制

### 脚本层（硬规则）— 保障流程稳定

这些规则不依赖 LLM 理解，由脚本强制执行：

| 规则 | 实现方式 |
|------|---------|
| **@mention 格式构建** | bot 回复完成后，脚本通过飞书 API 编辑该消息，在末尾追加格式正确的 `<at>` 标签（待验证方案，见下文） |
| **轮次计数** | 按 sender_id 计数，达到用户设定轮次 → 发停止消息 |
| **硬上限兜底** | 无论用户设多少轮，不超过 30 轮 |
| **超时处理** | 从上一个 bot 最后一条完整消息开始计时，到下一个 bot 第一条消息出现。streaming 中间帧重置计时器。完全静默 90s → 催促一次；再 90s → 结束 |
| **用户介入检测** | 监听到 sender_id 不是任何参与 bot 的消息 → 暂停自动轮转 |
| **共识检测** | 回复中出现约定标记（`✅ 共识达成`）→ 结束 |
| **最后一轮提示** | 脚本在最后一轮的 @mention 消息中追加"这是最后一轮，请给出总结性观点" |

### Prompt 层（软规则）— 保障讨论质量

渲染到发起消息中，靠 bot 的 LLM 理解和遵循：

- 话题描述和讨论背景
- 各参与者的角色/立场设定
- 回复结构要求（按模式不同）
- 共识标记约定
- **在 prompt 中提供精确的 @mention 格式模板，让 bot 在回复末尾自行 @下一位**

## @mention 构建方案

### 验证结果（2026-05-08 实测）

| 方式 | 格式 | 结果 |
|------|------|------|
| Bot 直接发消息 @Bot | text `<at user_id="...">` | ✅ 触发 |
| Bot 直接发消息 @Bot | post `{tag: "at", user_id: "..."}` | ✅ 触发 |
| 编辑消息追加 @mention | text `<at user_id="...">` | ❌ 不触发 |
| 编辑消息追加 @mention | post `{tag: "at", user_id: "..."}` | ❌ 不触发 |
| 用户发消息 @Bot | - | ✅ 触发 |

**结论**：编辑消息方案彻底否决（无论格式），`im.message.receive_v1` 只在消息创建时触发。Bot 直接发消息 @Bot 是唯一可靠链路。

### 飞书工程坑汇总（来自实测 + 社区复盘）

#### 坑1：必须用 post 格式 + tag: "at"

虽然实测 text 格式的 `<at>` 标签也能触发事件（可能是 OpenClaw/Hermes 框架帮做了转换），但飞书官方行为是：**机器人只处理包含 `tag: "at"` 元素且 `user_id` 指向自己 `open_id` 的富文本 post 消息**。为可靠性起见，脚本兜底消息必须用 post 格式。

```python
content_lines = [
    {"tag": "text", "text": "请继续回应上面的观点"},
    {"tag": "text", "text": "\n"},
    {"tag": "at", "user_id": target_bot_open_id}
]
```

#### 坑2：跨 App open_id 映射

飞书 open_id 是**应用作用域的**。同一个 bot 在不同 app 视角下有不同的 open_id：

| 视角 | Lucie 的 open_id | Lumi 的 open_id |
|------|-----------------|-----------------|
| Lucie app | `ou_79d248658c237b29e13a58b9e0fb899d` (self) | `ou_13833e3c85e46b9cca89da9e431e361b` |
| Lumi app | `ou_ac9f4356a4c02dec236a59e930b0be54` | `ou_dc063e8d89967b0b1bbdfe90f5ff3798` (self) |

**不要从后台抄 ID**，必须通过 API 动态查询（群 bot 列表或从事件数据中提取）。

获取方式：
```bash
# 用 bot 的 tenant_access_token 查群内 bot 列表
curl -s "https://open.feishu.cn/open-apis/im/v1/chats/{chat_id}/members/bots" \
  -H "Authorization: Bearer {tenant_access_token}"
```

注意：需要 `im:chat:readonly` 权限。Lumi (Hermes) 当前缺少此权限，需开通。

#### 坑3：`FEISHU_ALLOW_BOTS` 默认 `none` 且静默失败

消息被丢弃但没有任何报错。Hermes 默认值是 `none`，必须显式配置为 `mentions`。这个必须在 preflight 检查中重点提示。

#### 坑4：必须用 `tenant_access_token`

跨应用 @mention 场景下只有 `tenant_access_token` 有效。`app_access_token` 发消息 API 返回成功但事件不触发。token 有效期 2 小时，需缓存并刷新。

### 确定方案：Prompt 引导 @mention + 脚本兜底

Bot 直接 @Bot 可以工作，最佳策略是让 bot 自己在回复末尾写 @mention：

1. **Prompt 引导**：在发起消息中提供精确的 @mention 格式模板（含正确的 open_id），让 bot 在回复末尾自行 @下一位
2. **脚本监控兜底**：监听每条 bot 回复，检测是否包含正确的 @mention
   - 包含 → 链条自然继续，群里无噪音
   - 缺失 → 脚本用 post 格式发一条兜底消息（`tag: "at"`），保证链条不断
3. **停止控制**：脚本跟踪轮次，最后一轮通过 prompt 告知 bot "这是最后一轮，不需要 @对方"；或 bot 主动不带 @mention 则链路自然终止

**群里效果（正常情况，无噪音）**：
```
[用户]    📋 讨论话题... @Lucie 请先发言
[Lucie]   我认为 RAG 更适合，理由是... @Lumi
[Lumi]    我不同意，Fine-tuning 在这个场景下... @Lucie
[Lucie]   关于成本问题... @Lumi
[Lumi]    综合来看... （最后一轮，不带@，链路终止）
```

**群里效果（LLM 漏了 @mention 时，脚本兜底）**：
```
[Lucie]   关于成本问题...（漏了 @mention）
[脚本]    @Lumi ↑ (2/3)                        ← post 格式兜底消息
[Lumi]    ...
```

### Prompt 中的 @mention 模板

```
⚠️ 重要：每次回复结束时，你必须在最后一行单独 @下一位参与者。

具体格式（不可修改，复制使用）：
- 如果你是 Lucie，回复末尾写：<at user_id="{{lumi_id_in_lucie_scope}}">Lumi</at>
- 如果你是 Lumi，回复末尾写：<at user_id="{{lucie_id_in_lumi_scope}}">Lucie</at>

这是让对方收到你消息的唯一方式。如果漏掉，对方不会看到你的回复，讨论会中断。
最后一轮请不要 @任何人，表示讨论结束。
```

### open_id 动态注入流程

Skill 在 preflight 阶段：
1. 用各 bot 的 `tenant_access_token` 调 `GET /im/v1/chats/{chat_id}/members/bots`
2. 获取对方 bot 在自己视角下的 open_id
3. 填入 prompt 模板中的 `{{xxx_id}}` 占位符

## 执行流程

```
用户: "让 Lucie 和 Lumi 辩论 RAG vs Fine-tuning，3轮"
  │
  ├─ ① LLM 识别意图 → 匹配模式 → 补全参数 → 渲染发起消息
  │   展示给用户确认：
  │     话题、模式、参与者、轮次、讨论原则
  │
  ├─ ② 用户确认 "可以"
  │   → preflight 检查（最小范围）
  │   → 通过后发起
  │
  ├─ ③ Skill 将发起消息发到群里 @第一个 bot
  │
  ├─ ④ 监控脚本启动
  │   loop:
  │     监听群消息（event consume）
  │     检测 bot 回复完成（streaming 结束 / 消息间隔）
  │     ↓
  │     脚本构建 @mention → 编辑消息 / 发中继（取决于验证结果）
  │     ↓
  │     轮次计数 → 检查停止条件
  │     ↓
  │     未达停止条件 → 继续 loop
  │     达到停止条件 → 发停止消息
  │
  └─ ⑤ 生成讨论摘要返回给用户
```

## 四个讨论模式

### 🔴 辩论 (debate)

双方各持立场，逐轮交锋。

**用户输入示例**：
```
让 Lucie 和 Lumi 辩论微服务 vs 单体，Lucie 主张微服务，Lumi 主张单体，3轮
```

**Bot prompt**：
```
你正在参与一场结构化辩论。

你的立场：{{role}}

每轮回复请遵循以下结构：
1. 【核心主张】一句话表明你的观点
2. 【论据】2-3 个具体理由，用数据/案例/逻辑推演支撑
3. 【回应对方】针对对方上一轮的具体论点：同意什么、反驳什么、为什么
4. 【追问】向对方提一个具体问题，推动讨论深入

规则：
- 不允许空洞附和，每轮必须有新论据或新角度
- 反驳必须针对对方的具体论点，不能稻草人谬误
- 如果被说服了，诚实承认，说明是哪个论据改变了你的想法，标注「✅ 共识达成：...」
- 只输出你的观点内容，不需要 @任何人，系统会自动安排下一位发言
```

### 🟢 评审 (review)

一方出方案，另一方质疑挑战。

**用户输入示例**：
```
Lucie 提一个 API 限流方案，Lumi 做评审，2轮
```

**提案者 prompt**：
```
你正在向一位严格的评审者展示你的方案。

首轮回复结构：
1. 【问题定义】要解决什么问题，为什么重要
2. 【方案描述】具体怎么做，关键技术选型
3. 【选型理由】为什么选这个方案而不是其他
4. 【已知风险】你预见到的风险和缓解措施

被质疑后的回复结构：
1. 【逐条回应】对每个质疑点明确回应：接受 / 拒绝 / 部分接受，附理由
2. 【方案修订】如果接受了质疑，具体如何调整方案
3. 【遗留问题】还有哪些问题需要进一步讨论

只输出你的观点内容，不需要 @任何人，系统会自动安排下一位发言
```

**评审者 prompt**：
```
你正在评审一个技术方案，职责是发现问题、提高方案质量。

回复结构：
1. 【总体评价】一句话概括你对方案的判断
2. 【具体问题】按维度逐条列出：
   - 每条格式：问题描述 → 风险等级（高/中/低）→ 改进建议
   - 覆盖维度：可行性 / 完整性 / 性能 / 安全 / 可维护性
3. 【亮点】方案中做得好的 1-2 个点
4. 【核心追问】最需要提案者回答的 1 个问题

规则：
- 质疑必须具体，不能说"有风险"，要说"在 XX 条件下会出现 YY 问题"
- 给建议而不是只挑刺
- 只输出你的观点内容，不需要 @任何人
```

### 🔵 头脑风暴 (brainstorm)

互相补充发散，遵循 "Yes, and..." 原则。

**用户输入示例**：
```
Lucie 和 Lumi 一起想想用户留存怎么提升，多发散
```

**Bot prompt**：
```
你正在参与一场头脑风暴，目标是尽可能多地产出有价值的想法。

遵循 "Yes, and..." 原则：先肯定，再延伸。不否定、不批评、不说"但是"。

每轮回复结构：
1. 【共鸣点】对方的哪个想法触发了你的灵感，为什么它有潜力
2. 【延伸】在这个想法基础上往前推一步，或组合前面的想法产生新东西
3. 【新方向】至少 1 个完全不同角度的新想法
4. 【探索问题】提一个"如果...会怎样？"的问题，打开新的探索空间

规则：
- 想法可以大胆，不需要当场验证可行性
- 鼓励跨领域联想（其他行业怎么做的？能不能反过来？极端情况呢？）
- 量大于质，先发散后收敛
- 只输出你的观点内容，不需要 @任何人
```

### ⚪ 自由对话 (freeform)

开放式交流，无固定结构。

**用户输入示例**：
```
Lucie 和 Lumi 聊聊 AI 编程的未来
```

**Bot prompt**：
```
你正在参与一场开放式对话。

没有固定结构要求，但请注意：
- 围绕主题展开，可以自然延伸到相关子话题
- 对对方有趣的观点进行追问或深入探讨
- 分享你独特的视角和知识，避免泛泛而谈
- 有不同看法直接说，并解释为什么
- 只输出你的观点内容，不需要 @任何人
```

## 用户确认流程

用户自然语言输入 → LLM 识别意图 → 匹配模式 → 补全默认参数 → 展示确认：

```
📋 讨论方案

话题：RAG vs Fine-tuning，哪个更适合客服场景
模式：辩论
参与者：
  - Lucie — 主张 RAG，关注工程落地成本
  - Lumi — 主张 Fine-tuning，关注效果上限
先发言：Lucie
轮次：3 轮
群聊：AI讨论群

讨论原则：
  ① 每轮须包含：核心主张 → 论据 → 回应对方 → 追问
  ② 不允许空洞附和，每轮须有新论据
  ③ 被说服时诚实承认并标注共识
  ④ 系统自动安排轮转，bot 不需要手动 @对方

确认发起？
```

默认值（用户未指定时）：mode=freeform, rounds=3, timeout=90s

## 前置检查（最小范围）

只检查不通过就一定跑不了的项：

| 检查项 | 检测方式 | 不通过时的修复指引 |
|--------|---------|------------------|
| OpenClaw 飞书插件 >= 2026.4.8 | 读 `~/.openclaw/plugins/installs.json` 中 `@openclaw/feishu` 的 version | `npx -y @larksuite/openclaw-lark install` |
| Hermes `FEISHU_ALLOW_BOTS` != none | 读 `~/.hermes/.env` | 编辑 `.env` 设 `FEISHU_ALLOW_BOTS=mentions` 并重启 |
| 两个 bot 都在目标群里 | 飞书 API 查群成员 | 提示用户在飞书中将 bot 添加到群聊 |

输出格式：
```
✅ OpenClaw 飞书插件: 2026.5.6 (>= 2026.4.8)
✅ Hermes FEISHU_ALLOW_BOTS: mentions
✅ 群成员: Lucie ✓ Lumi ✓
→ 前置检查通过
```

或：
```
❌ Hermes FEISHU_ALLOW_BOTS: none

修复：
  vim ~/.hermes/.env
  # 找到 FEISHU_ALLOW_BOTS，改为：
  FEISHU_ALLOW_BOTS=mentions
  # 重启 Hermes

修复后告诉我，我会重新检查。
```

## 项目结构

```
repos/lark-debate-arena/
├── DESIGN.md                   # 本文件 — 完整设计方案
├── skill.md                    # Skill 入口定义（触发词、使用示例、流程）
├── references/
│   ├── preflight.md            # 前置检查详细流程
│   ├── script-rules.md         # 脚本硬规则完整说明
│   └── prompt-protocol.md      # prompt 模板规范
├── templates/
│   ├── debate.md               # 辩论模式 prompt 模板
│   ├── review.md               # 评审模式
│   ├── brainstorm.md           # 头脑风暴
│   └── freeform.md             # 自由对话
├── scripts/
│   ├── preflight.sh            # 前置检查
│   ├── arena.sh                # 核心监控循环
│   └── verify-edit-mention.sh  # @mention 编辑方案验证脚本
└── README.md                   # 开源用户使用说明
```

## 已验证项（2026-05-08）

1. ✅ **Bot 直接发消息 @Bot（text 格式）正常触发** — Lucie→Lumi 验证通过
2. ✅ **Bot 直接发消息 @Bot（post 格式 tag:"at"）正常触发** — Lucie→Lumi 验证通过
3. ❌ **编辑消息追加 @mention（text 格式）不触发事件**
4. ❌ **编辑消息追加 @mention（post 格式 tag:"at"）不触发事件**
5. ✅ **用户发消息 @Bot 正常触发**
6. ✅ **跨 App open_id 映射确认** — 两个 bot 互相的 open_id 均已获取

## 待验证项

1. **Lumi→Lucie 反向链路** — 验证 Lumi 回复中 @Lucie 是否也能触发 Lucie 响应（Lumi app 缺 `im:chat:readonly` 权限，需开通后验证）
2. **streaming 模式下如何判断 bot 回复完成** — OpenClaw/Hermes 的 streaming 消息结束标记
3. **LLM 遵循 @mention 格式的成功率** — 实际讨论中观察 prompt 模板效果
4. **Lumi app 权限补全** — 需开通 `im:chat:readonly` 以支持查询群 bot 列表（获取 open_id 映射）

## 开源考量

- 零侵入：不修改任何 bot 框架代码
- 可配置：参与者、模式、轮次、停止规则均通过 YAML/用户自然语言指定
- 框架无关：只依赖飞书 API 能力，OpenClaw/Hermes/其他框架均可
- 模板可扩展：用户可添加自定义讨论模式模板
