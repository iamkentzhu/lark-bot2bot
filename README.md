# lark-bot2bot

让飞书群里的多个 AI 机器人围绕话题自动讨论。编排器通过 CLI 调用各 bot 的 LLM，以各自 bot 身份在群里发消息，形成零噪音的连贯讨论链。

## 效果

```
[Lucie]  RAG 更适合客服：知识库可实时更新，成本低...
  └─ [Lumi]  不同意，Fine-tuning 更适合：话术稳定...  _(1/3 · Lumi)_
       └─ [Lucie]  关于成本问题...  _(2/3 · Lucie)_
            └─ [Lumi]  综合来看...  _(2/3 · Lumi)_
[系统]  ⏹ 讨论结束
```

## 特性

- **零噪音**：群里只有 bot 的观点内容，没有中继消息
- **零侵入**：不修改任何 bot 框架代码
- **Reply 链**：消息自动引用上一条，形成连贯讨论
- **四种模式**：辩论、评审、头脑风暴、自由对话
- **自动停止**：轮次上限、共识检测、用户主动停止
- **跨框架**：支持 OpenClaw + Hermes、OpenClaw + OpenClaw、Hermes + Hermes

## 前置条件

- 两个 bot 框架在本地运行（OpenClaw / Hermes Agent）
- 两个 bot 的飞书 App ID + App Secret
- 两个 bot 在同一个飞书群
- Python 3 + PyYAML（`pip3 install pyyaml`）
- jq（`brew install jq`）

## 安装

```bash
git clone https://github.com/iamkentzhu/lark-bot2bot.git

# 作为 Claude Code skill
cp -r lark-bot2bot ~/.claude/skills/

# 或作为 OpenClaw skill
cp -r lark-bot2bot /path/to/openclaw-skills/
```

## 配置

创建 `~/.bot2bot/config.yaml`：

```yaml
chat_id: "oc_your_group_chat_id"

participants:
  - name: Lucie
    bot_app_id: "cli_xxx"
    bot_app_secret: "xxx"
    type: local-cli
    command: "openclaw agent --agent main --message '{message}' --json"
    parse: "jq -r '.result.payloads[0].text'"

  - name: Lumi
    bot_app_id: "cli_xxx"
    bot_app_secret: "xxx"
    type: local-cli
    command: "hermes chat -q '{message}' -Q"
    parse: "grep -v '^session_id:' | grep -v '^$'"

defaults:
  max_rounds: 3
  timeout_seconds: 90
  hard_limit: 30
```

## 使用

### 命令行

```bash
bash scripts/arena.sh \
  --topic "RAG vs Fine-tuning" \
  --mode debate \
  --rounds 3 \
  --role-a "主张 RAG" \
  --role-b "主张 Fine-tuning"
```

### 作为 Skill

在 Claude Code / OpenClaw / Hermes 中说：

> 使用 bot2bot 技能，让 Lucie 和 Lumi 辩论微服务 vs 单体，3 轮

### 参数

| 参数 | 说明 | 默认 |
|------|------|------|
| `--topic` | 讨论话题 | 必填 |
| `--mode` | debate / review / brainstorm / freeform | freeform |
| `--rounds` | 讨论轮数 | 3 |
| `--role-a` | Bot A 的角色/立场 | 参与者 |
| `--role-b` | Bot B 的角色/立场 | 参与者 |
| `--first` | 谁先发言：a / b | a |
| `--config` | 配置文件路径 | ~/.bot2bot/config.yaml |
| `--timeout` | 单次 CLI 调用超时（秒） | 90 |

## 讨论模式

| 模式 | 说明 |
|------|------|
| **debate** | 双方各持立场，逐轮交锋（主张→论据→回应→追问） |
| **review** | 一方出方案，另一方质疑（问题定义→评审→回应修订） |
| **brainstorm** | Yes, and 原则，互相延伸发散 |
| **freeform** | 开放式交流，无固定结构 |

自定义模式：在 `templates/` 目录下添加 Markdown 文件即可。

## 架构

```
arena.sh (编排器)
  ├── 调 openclaw agent CLI → 获取 Bot A 回复
  ├── 调 hermes chat CLI    → 获取 Bot B 回复
  └── 调飞书 API (curl)     → 以各自 bot token 发消息
```

编排器不依赖任何特定 AI 框架，核心是一个 shell 脚本。

## License

MIT
