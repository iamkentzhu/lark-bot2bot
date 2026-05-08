# 配置指南

## 配置文件位置

默认配置文件：`~/.bot2bot/config.yaml`

如果不存在，引导用户创建。

## 配置格式

```yaml
# 飞书群 ID
chat_id: "oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# 参与方
participants:
  - name: Lucie
    bot_app_id: "cli_xxxxxxxxxxxxxxxx"
    bot_app_secret: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    type: local-cli
    command: "openclaw agent --agent main --message '{message}' --json"
    parse: "jq -r '.result.payloads[0].text'"

  - name: Lumi
    bot_app_id: "cli_xxxxxxxxxxxxxxxx"
    bot_app_secret: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    type: local-cli
    command: "hermes chat -q '{message}' -Q"
    parse: "grep -v '^session_id:' | grep -v '^$'"

# 默认参数
defaults:
  max_rounds: 3
  timeout_seconds: 90
  hard_limit: 30
```

## 配置说明

### participants

每个参与方需要：

| 字段 | 说明 | 必须 |
|------|------|------|
| `name` | Bot 显示名称 | 是 |
| `bot_app_id` | 飞书应用 App ID | 是 |
| `bot_app_secret` | 飞书应用 App Secret | 是 |
| `type` | 调用方式：`local-cli`（v1）或 `http-api`（v2） | 是 |
| `command` | CLI 命令模板，`{message}` 为占位符 | local-cli 必须 |
| `parse` | 输出解析命令（管道） | local-cli 必须 |
| `endpoint` | HTTP API 地址 | http-api 必须 |
| `api_key` | API 鉴权密钥 | http-api 可选 |

### 支持的框架组合

**同机器（local-cli）**：

| Bot A | Bot B | 说明 |
|-------|-------|------|
| OpenClaw | Hermes | `openclaw agent ...` + `hermes chat ...` |
| OpenClaw | OpenClaw | 不同 agent ID |
| Hermes | Hermes | 不同 session |

**异地（http-api）**：

| Bot A (本地) | Bot B (远程) | 说明 |
|-------------|-------------|------|
| OpenClaw | Hermes | Bot B 启用 API server，本地通过 HTTP 调用 |
| Hermes | Hermes | 两台都启用 API server |
| OpenClaw | OpenClaw | ❌ OpenClaw 暂不支持 HTTP chat API |

**异地 Hermes 配置示例**（远程机器）：
```bash
# 在远程 Hermes 的 .env 中加：
API_SERVER_ENABLED=true
API_SERVER_KEY=your-secret-key
# 重启 hermes gateway
```

**本地 config.yaml 异地配置示例**：
```yaml
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
    type: http-api
    endpoint: "http://remote-host:8642/v1/chat/completions"
    api_key: "your-secret-key"
    model: "hermes-agent"
```

## 首次配置引导

如果用户没有配置文件，按以下步骤引导：

1. 确认用户有哪些 bot 框架（OpenClaw / Hermes / 其他）
2. 获取飞书群 ID（用户从飞书群设置中查看，或通过 `lark-cli im +chat-search` 搜索）
3. 获取两个 bot 的 app_id 和 app_secret（从飞书开放平台控制台）
4. 生成 config.yaml 并写入 `~/.bot2bot/config.yaml`
