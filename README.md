# lark-bot2bot

Multi-bot discussion orchestrator for Feishu/Lark. The orchestrator calls each bot's LLM via CLI, then posts messages under each bot's identity — zero noise, zero framework changes.

飞书多机器人协作讨论编排器。编排器通过 CLI 调用各 bot 的 LLM，以各自 bot 身份在群里发消息——零噪音、零侵入。

---

## Demo / 效果

```
[Lucie]  RAG is better for customer service: real-time KB updates, low cost...
         RAG 更适合客服：知识库可实时更新，成本低...
  └─ [Lumi]  Disagree, Fine-tuning is better: stable tone...  _(1/3 · Lumi)_
             不同意，Fine-tuning 更适合：话术稳定...
       └─ [Lucie]  On the cost issue...  _(2/3 · Lucie)_
                   关于成本问题...
            └─ [Lumi]  Overall...  _(2/3 · Lumi)_
                       综合来看...
[System / 系统]  ⏹ Discussion ended / 讨论结束
```

---

## Features / 特性

- **Zero noise / 零噪音** — only bot opinions appear in the chat, no relay messages / 群里只有 bot 的观点内容，没有中继消息
- **Zero invasion / 零侵入** — no bot framework code changes needed / 不修改任何 bot 框架代码
- **Reply chain / 回复链** — messages auto-reply to the previous one, forming a coherent thread / 消息自动引用上一条，形成连贯讨论
- **4 modes / 四种模式** — debate, review, brainstorm, freeform / 辩论、评审、头脑风暴、自由对话
- **Auto stop / 自动停止** — round limit, consensus detection (Ctrl+C to interrupt) / 轮次上限、共识检测（Ctrl+C 可手动中断）
- **Cross-framework / 跨框架** — OpenClaw + Hermes, OpenClaw + OpenClaw, Hermes + Hermes

---

## Supported Scenarios / 支持的场景组合

### Local (local-cli) / 同机器

Orchestrator and all bots run on the same machine.

编排器和所有参与 bot 在同一台机器上。

| Combination / 组合 | Supported / 支持 | Notes / 说明 |
|---------------------|-----------------|-------------|
| OpenClaw + Hermes | ✅ | Default scenario, two frameworks / 默认场景，两个不同框架 |
| OpenClaw + OpenClaw | ✅ | Use different agent IDs / 需使用不同的 agent ID |
| Hermes + Hermes | ✅ | Use different sessions / 需使用不同的 session |

### Remote (http-api) / 异地

Orchestrator runs locally, remote bot called via OpenAI-compatible HTTP API.

编排器在本地，远程 bot 通过 OpenAI 兼容 HTTP API 调用。

| Combination / 组合 | Supported / 支持 | Notes / 说明 |
|---------------------|-----------------|-------------|
| OpenClaw (local) + Hermes (remote) | ✅ | Local CLI + remote HTTP API |
| Hermes (local) + Hermes (remote) | ✅ | Local CLI + remote HTTP API |
| OpenClaw + OpenClaw remote | ❌ | OpenClaw does not support HTTP chat API yet / OpenClaw 暂不支持 HTTP chat API |

Remote Hermes requires API server enabled in `.env`:

异地场景需在远程 Hermes 的 `.env` 中启用 API server：

```bash
API_SERVER_ENABLED=true
API_SERVER_KEY=your-secret-key
```

---

## Prerequisites / 前置条件

- Bot frameworks running locally (OpenClaw / Hermes Agent) / 两个 bot 框架在本地运行
- Feishu App ID + App Secret for each bot / 两个 bot 的飞书 App ID + App Secret
- Both bots in the same Feishu group chat / 两个 bot 在同一个飞书群
- Python 3 + PyYAML (`pip3 install pyyaml`)
- jq (`brew install jq`)

---

## Installation / 安装

```bash
git clone https://github.com/iamkentzhu/lark-bot2bot.git

# As a Claude Code skill / 作为 Claude Code skill
cp -r lark-bot2bot ~/.claude/skills/

# Or as an OpenClaw skill / 或作为 OpenClaw skill
cp -r lark-bot2bot /path/to/openclaw-skills/
```

---

## Configuration / 配置

Create `~/.bot2bot/config.yaml`:

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

---

## Usage / 使用

### Command Line / 命令行

```bash
bash scripts/arena.sh \
  --topic "RAG vs Fine-tuning" \
  --mode debate \
  --rounds 3 \
  --role-a "Pro RAG" \
  --role-b "Pro Fine-tuning"
```

### As a Skill / 作为 Skill

In Claude Code / OpenClaw / Hermes, say:

在 Claude Code / OpenClaw / Hermes 中说：

> Use the bot2bot skill, have Lucie and Lumi debate microservices vs monolith, 3 rounds
>
> 使用 bot2bot 技能，让 Lucie 和 Lumi 辩论微服务 vs 单体，3 轮

### Parameters / 参数

| Parameter / 参数 | Description / 说明 | Default / 默认 |
|-----------------|-------------------|---------------|
| `--topic` | Discussion topic / 讨论话题 | Required / 必填 |
| `--mode` | debate / review / brainstorm / freeform | freeform |
| `--rounds` | Number of rounds / 讨论轮数 | 3 |
| `--role-a` | Bot A's role / Bot A 的角色 | Participant / 参与者 |
| `--role-b` | Bot B's role / Bot B 的角色 | Participant / 参与者 |
| `--first` | Who speaks first / 谁先发言: a / b | a |
| `--config` | Config file path / 配置文件路径 | ~/.bot2bot/config.yaml |
| `--timeout` | CLI call timeout (seconds) / 超时秒数 | 90 |

---

## Discussion Modes / 讨论模式

| Mode / 模式 | Description / 说明 |
|-------------|-------------------|
| **debate** | Each side holds a position, structured argumentation / 双方各持立场，结构化论证 |
| **review** | One proposes, the other challenges / 一方出方案，另一方质疑挑战 |
| **brainstorm** | "Yes, and..." principle, build on ideas / Yes, and 原则，互相延伸 |
| **freeform** | Open conversation, no fixed structure / 开放式交流，无固定结构 |

Custom modes: add a Markdown file to `templates/`.

自定义模式：在 `templates/` 目录下添加 Markdown 文件。

---

## Architecture / 架构

```
arena.sh (orchestrator / 编排器)
  ├── openclaw agent CLI  → Bot A reply / Bot A 回复
  ├── hermes chat CLI     → Bot B reply / Bot B 回复
  └── Feishu API (curl)   → Post as each bot's identity / 以各自 bot 身份发消息
```

The orchestrator is framework-agnostic — it's just a shell script.

编排器不依赖任何特定 AI 框架，核心是一个 shell 脚本。

---

## License

MIT
