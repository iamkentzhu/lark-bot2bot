---
name: lark-bot2bot
description: "飞书多机器人协作讨论：让多个 AI 机器人在飞书群里围绕话题自动讨论。支持辩论、评审、头脑风暴、自由对话四种模式。当用户说到 bot2bot、机器人讨论、机器人辩论、多机器人协作、让机器人聊、bot对话 时触发。"
version: 1.0.0
---

# lark-bot2bot

让飞书群里的多个 AI 机器人围绕一个话题自动讨论。编排器通过 CLI 调用各 bot 的 LLM，以各自 bot 身份在群里发消息，形成零噪音的连贯讨论链。

## 使用前必读

执行前必须先读取配置文件：`references/config-guide.md`

## 使用流程

### 1. 引导用户输入

当用户触发本 skill 时，引导用户提供以下信息：

```
请描述你要发起的讨论任务。示例：

  "让 Lucie 和 Lumi 辩论 RAG vs Fine-tuning，3轮"
  "Lucie 提一个 API 限流方案，Lumi 做评审，2轮"
  "Lucie 和 Lumi 一起头脑风暴用户留存策略"
  "Lucie 和 Lumi 聊聊 AI 编程的未来"
```

### 2. 解析意图并确认

从用户输入中提取：
- **话题**：讨论主题
- **模式**：debate / review / brainstorm / freeform（默认 freeform）
- **参与者**：bot 名称和角色/立场
- **轮次**：讨论轮数（默认 3，硬上限 30）
- **停止条件**：轮次结束 / 共识达成 / 用户主动停止

未指定的参数用默认值补全。展示给用户确认：

```
📋 讨论方案

话题：[话题]
模式：[模式名称]
参与者：
  - [Bot A] — [角色/立场]
  - [Bot B] — [角色/立场]
先发言：[Bot A]
轮次：[N] 轮
群聊：[群名称]

讨论原则：
  [根据模式列出对应的讨论规则摘要]

确认发起？
```

### 3. 执行

用户确认后，读取 `references/config-guide.md` 获取配置路径，然后执行：

```bash
bash scripts/arena.sh \
  --config /path/to/config.yaml \
  --topic "话题" \
  --mode debate \
  --rounds 3 \
  --role-a "主张 RAG" \
  --role-b "主张 Fine-tuning" \
  --first a
```

脚本会自动执行 preflight 检查、讨论循环、停止控制。

### 4. 监控

脚本执行过程中，每轮会输出进度。用户可以通过 Ctrl+C 中断脚本停止讨论。

## 四种讨论模式

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| **debate** | 双方各持立场，逐轮交锋 | 技术选型、方案对比 |
| **review** | 一方出方案，另一方质疑挑战 | 代码评审、方案评估 |
| **brainstorm** | 互相补充发散，Yes and 原则 | 创意发散、策略探索 |
| **freeform** | 开放式交流，无固定结构 | 自由讨论、信息交换 |

详细 prompt 模板见 `templates/` 目录。
