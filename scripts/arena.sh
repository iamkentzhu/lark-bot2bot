#!/usr/bin/env bash
set -euo pipefail

# macOS 兼容的 timeout 实现
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  # 用 perl 实现 timeout
  run_with_timeout() {
    local secs=$1; shift
    perl -e "alarm $secs; exec @ARGV" -- "$@"
  }
  TIMEOUT_CMD="run_with_timeout"
fi

# lark-bot2bot arena — 核心编排脚本
# Usage: bash arena.sh --config config.yaml --topic "..." --mode debate --rounds 3 \
#        --role-a "主张RAG" --role-b "主张Fine-tuning" --first a

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- 参数解析 ---
CONFIG_FILE="$HOME/.bot2bot/config.yaml"
TOPIC=""
MODE="freeform"
ROUNDS=3
ROLE_A=""
ROLE_B=""
FIRST="a"
HARD_LIMIT=30
TIMEOUT=90

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --role-a) ROLE_A="$2"; shift 2 ;;
    --role-b) ROLE_B="$2"; shift 2 ;;
    --first) FIRST="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "❌ --topic 必须指定"
  exit 1
fi

# 强制硬上限
if [[ "$ROUNDS" -gt "$HARD_LIMIT" ]]; then
  ROUNDS=$HARD_LIMIT
  echo "⚠️ 轮次已限制为硬上限 $HARD_LIMIT"
fi

# --- Preflight ---
echo "=== 前置检查 ==="
bash "$SCRIPT_DIR/preflight.sh" --config "$CONFIG_FILE" || exit 1
echo ""

# --- 解析配置 ---
CONFIG_JSON=$(python3 -c "
import yaml, json
with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)
print(json.dumps(cfg))
")

CHAT_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['chat_id'])")

# 参与方信息
get_participant() {
  local idx=$1
  local field=$2
  echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$idx];print(p.get('$field',''))"
}

NAME_A=$(get_participant 0 name)
NAME_B=$(get_participant 1 name)
APP_ID_A=$(get_participant 0 bot_app_id)
APP_SECRET_A=$(get_participant 0 bot_app_secret)
APP_ID_B=$(get_participant 1 bot_app_id)
APP_SECRET_B=$(get_participant 1 bot_app_secret)
TYPE_A=$(get_participant 0 type)
TYPE_B=$(get_participant 1 type)
CMD_A=$(get_participant 0 command)
CMD_B=$(get_participant 1 command)
PARSE_A=$(get_participant 0 parse)
PARSE_B=$(get_participant 1 parse)

if [[ -z "$ROLE_A" ]]; then ROLE_A="参与者"; fi
if [[ -z "$ROLE_B" ]]; then ROLE_B="参与者"; fi

# --- 获取 token ---
get_token() {
  local app_id=$1
  local app_secret=$2
  curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$app_id\",\"app_secret\":\"$app_secret\"}" | \
    python3 -c "import sys,json;print(json.load(sys.stdin)['tenant_access_token'])"
}

TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A")
TOKEN_B=$(get_token "$APP_ID_B" "$APP_SECRET_B")

# --- 加载 prompt 模板 ---
TEMPLATE_FILE="$PROJECT_DIR/templates/${MODE}.md"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "❌ 模板不存在: $TEMPLATE_FILE"
  exit 1
fi
TEMPLATE=$(cat "$TEMPLATE_FILE")

build_prompt() {
  local role=$1
  local opponent_text=$2
  local round=$3
  local total=$4
  local is_last=$5

  local prompt="$TEMPLATE"
  prompt=$(echo "$prompt" | sed "s|{{role}}|$role|g")
  prompt=$(echo "$prompt" | sed "s|{{topic}}|$TOPIC|g")

  if [[ -n "$opponent_text" ]]; then
    prompt="$prompt

---
对方上一轮的发言：
$opponent_text"
  fi

  if [[ "$is_last" == "true" ]]; then
    prompt="$prompt

这是最后一轮（第 ${round}/${total} 轮），请给出总结性观点。"
  else
    prompt="$prompt

这是第 ${round}/${total} 轮。"
  fi

  echo "$prompt"
}

# --- 调用 bot CLI ---
call_bot() {
  local cmd_template=$1
  local parse_cmd=$2
  local message=$3
  local timeout_sec=$4

  # 写入临时文件避免 shell 转义问题
  local tmpfile
  tmpfile=$(mktemp /tmp/bot2bot-msg-XXXXXX.txt)
  echo "$message" > "$tmpfile"

  local result
  if echo "$cmd_template" | grep -q "openclaw agent"; then
    # OpenClaw：用 --message 参数读文件内容
    local msg_content
    msg_content=$(cat "$tmpfile")
    result=$($TIMEOUT_CMD "$timeout_sec" openclaw agent --agent main --message "$msg_content" --json 2>/dev/null) || {
      rm -f "$tmpfile"
      echo "[超时或调用失败]"
      return 1
    }
  elif echo "$cmd_template" | grep -q "hermes chat"; then
    # Hermes：用 -q 参数
    local msg_content
    msg_content=$(cat "$tmpfile")
    result=$($TIMEOUT_CMD "$timeout_sec" hermes chat -q "$msg_content" -Q 2>/dev/null) || {
      rm -f "$tmpfile"
      echo "[超时或调用失败]"
      return 1
    }
  else
    # 通用：替换 {message} 占位符（用文件路径）
    local cmd="${cmd_template//\{message\}/\$(cat $tmpfile)}"
    result=$($TIMEOUT_CMD "$timeout_sec" bash -c "$cmd" 2>/dev/null) || {
      rm -f "$tmpfile"
      echo "[超时或调用失败]"
      return 1
    }
  fi

  rm -f "$tmpfile"

  if [[ -n "$parse_cmd" ]]; then
    echo "$result" | eval "$parse_cmd"
  else
    echo "$result"
  fi
}

# --- 发送飞书消息 ---
send_feishu_message() {
  local token=$1
  local chat_id=$2
  local text=$3
  local reply_to=$4  # 可为空
  local bot_name=$5
  local round=$6
  local total=$7

  local tmpfile
  tmpfile=$(mktemp /tmp/bot2bot-send-XXXXXX.txt)
  echo "$text" > "$tmpfile"

  local resp
  resp=$(python3 - "$token" "$chat_id" "$tmpfile" "$reply_to" "$bot_name" "$round" "$total" << 'PYEOF'
import sys, json, urllib.request

token, chat_id, textfile, reply_to, bot_name, rnd, total = sys.argv[1:8]

with open(textfile) as f:
    text = f.read().strip()

footer = f"_({rnd}/{total} · {bot_name})_" if rnd != "end" else ""
full_text = f"{text}\n\n{footer}" if footer else text

post = json.dumps({"zh_cn": {"content": [[{"tag": "md", "text": full_text}]]}})
body = {"msg_type": "post", "content": post}

if reply_to:
    url = f"https://open.feishu.cn/open-apis/im/v1/messages/{reply_to}/reply"
else:
    url = f"https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
    body["receive_id"] = chat_id

data = json.dumps(body).encode()
req = urllib.request.Request(url, data=data, headers={
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json"
})

try:
    resp = json.loads(urllib.request.urlopen(req).read())
    print(resp.get("data", {}).get("message_id", ""))
except Exception as e:
    print("", file=sys.stderr)
    print(f"发送失败: {e}", file=sys.stderr)
PYEOF
  )

  rm -f "$tmpfile"
  echo "$resp"
}

# --- 共识检测 ---
check_consensus() {
  local text=$1
  echo "$text" | grep -qi "✅.*共识达成\|✅.*consensus\|✅.*达成一致" && return 0
  return 1
}

# --- 主循环 ---
echo "=== 讨论开始 ==="
echo "话题: $TOPIC"
echo "模式: $MODE"
echo "参与者: $NAME_A ($ROLE_A) vs $NAME_B ($ROLE_B)"
echo "轮次: $ROUNDS"
echo ""

LAST_MSG_ID=""
LAST_TEXT=""
CONSENSUS=false

# 确定先后顺序
if [[ "$FIRST" == "b" ]]; then
  # 交换 A 和 B
  TMP_NAME=$NAME_A; NAME_A=$NAME_B; NAME_B=$TMP_NAME
  TMP_ROLE=$ROLE_A; ROLE_A=$ROLE_B; ROLE_B=$TMP_ROLE
  TMP_TOKEN=$TOKEN_A; TOKEN_A=$TOKEN_B; TOKEN_B=$TMP_TOKEN
  TMP_CMD=$CMD_A; CMD_A=$CMD_B; CMD_B=$TMP_CMD
  TMP_PARSE=$PARSE_A; PARSE_A=$PARSE_B; PARSE_B=$TMP_PARSE
fi

for round in $(seq 1 "$ROUNDS"); do
  IS_LAST="false"
  [[ "$round" -eq "$ROUNDS" ]] && IS_LAST="true"

  # --- Bot A 发言 ---
  echo "--- 第 ${round}/${ROUNDS} 轮 · $NAME_A ---"
  PROMPT_A=$(build_prompt "$ROLE_A" "$LAST_TEXT" "$round" "$ROUNDS" "$IS_LAST")
  TEXT_A=$(call_bot "$CMD_A" "$PARSE_A" "$PROMPT_A" "$TIMEOUT")

  if [[ -z "$TEXT_A" || "$TEXT_A" == "[超时或调用失败]" ]]; then
    echo "⚠️ $NAME_A 回复失败或超时，跳过"
    continue
  fi

  echo "$NAME_A: ${TEXT_A:0:100}..."

  # token 可能过期，刷新
  TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A" 2>/dev/null) || TOKEN_A="$TOKEN_A"

  LAST_MSG_ID=$(send_feishu_message "$TOKEN_A" "$CHAT_ID" "$TEXT_A" "$LAST_MSG_ID" "$NAME_A" "$round" "$ROUNDS")
  echo "  → 已发到群里 (msg: ${LAST_MSG_ID:0:20}...)"

  # 共识检测
  if check_consensus "$TEXT_A"; then
    echo "✅ $NAME_A 表示达成共识"
    CONSENSUS=true
    break
  fi

  LAST_TEXT="$TEXT_A"

  # --- Bot B 发言 ---
  echo "--- 第 ${round}/${ROUNDS} 轮 · $NAME_B ---"
  PROMPT_B=$(build_prompt "$ROLE_B" "$LAST_TEXT" "$round" "$ROUNDS" "$IS_LAST")
  TEXT_B=$(call_bot "$CMD_B" "$PARSE_B" "$PROMPT_B" "$TIMEOUT")

  if [[ -z "$TEXT_B" || "$TEXT_B" == "[超时或调用失败]" ]]; then
    echo "⚠️ $NAME_B 回复失败或超时，跳过"
    continue
  fi

  echo "$NAME_B: ${TEXT_B:0:100}..."

  TOKEN_B=$(get_token "$APP_ID_B" "$APP_SECRET_B" 2>/dev/null) || TOKEN_B="$TOKEN_B"

  LAST_MSG_ID=$(send_feishu_message "$TOKEN_B" "$CHAT_ID" "$TEXT_B" "$LAST_MSG_ID" "$NAME_B" "$round" "$ROUNDS")
  echo "  → 已发到群里 (msg: ${LAST_MSG_ID:0:20}...)"

  # 共识检测
  if check_consensus "$TEXT_B"; then
    echo "✅ $NAME_B 表示达成共识"
    CONSENSUS=true
    break
  fi

  LAST_TEXT="$TEXT_B"
  echo ""
done

# --- 结束消息 ---
echo ""
if [[ "$CONSENSUS" == "true" ]]; then
  echo "=== 讨论结束（共识达成）==="
  END_MSG="⏹ 讨论结束 — 双方达成共识"
else
  echo "=== 讨论结束（${ROUNDS} 轮完成）==="
  END_MSG="⏹ 讨论结束 — 已完成 ${ROUNDS} 轮"
fi

# 发结束消息（以 Bot A 身份）
TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A" 2>/dev/null) || true
if [[ -n "$LAST_MSG_ID" ]]; then
  send_feishu_message "$TOKEN_A" "$CHAT_ID" "$END_MSG" "$LAST_MSG_ID" "系统" "end" "" >/dev/null 2>&1
fi

echo "完成。"
