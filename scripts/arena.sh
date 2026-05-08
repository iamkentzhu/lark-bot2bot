#!/usr/bin/env bash
set -euo pipefail

# macOS 兼容的 timeout 实现
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  run_with_timeout() {
    local secs=$1; shift
    perl -e "alarm $secs; exec @ARGV" -- "$@"
  }
  TIMEOUT_CMD="run_with_timeout"
fi

# lark-bot2bot arena — 核心编排脚本
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- 参数解析 ---
CONFIG_FILE="$HOME/.bot2bot/config.yaml"
TOPIC=""
MODE="freeform"
ROUNDS=""
ROLE_A=""
ROLE_B=""
FIRST="a"
TIMEOUT=""

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
    *) echo "❌ Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "❌ --topic 必须指定"
  exit 1
fi

# --- Preflight ---
echo "=== 前置检查 ==="
bash "$SCRIPT_DIR/preflight.sh" --config "$CONFIG_FILE" || exit 1
echo ""

# --- 解析配置（用 python 统一处理，避免 shell 特殊字符问题）---
read_config() {
  python3 - "$CONFIG_FILE" "$ROUNDS" "$TIMEOUT" << 'PYEOF'
import yaml, json, sys

config_file, cli_rounds, cli_timeout = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_file) as f:
    cfg = yaml.safe_load(f)

defaults = cfg.get("defaults", {})
rounds = int(cli_rounds) if cli_rounds else defaults.get("max_rounds", 3)
timeout_sec = int(cli_timeout) if cli_timeout else defaults.get("timeout_seconds", 90)
hard_limit = defaults.get("hard_limit", 30)

if rounds > hard_limit:
    rounds = hard_limit
    print(f"⚠️ 轮次已限制为硬上限 {hard_limit}", file=sys.stderr)

out = {
    "chat_id": cfg["chat_id"],
    "rounds": rounds,
    "timeout": timeout_sec,
    "hard_limit": hard_limit,
    "participants": cfg["participants"],
}
print(json.dumps(out))
PYEOF
}

CONFIG_JSON=$(read_config)

CHAT_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['chat_id'])")
ROUNDS=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['rounds'])")
TIMEOUT=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['timeout'])")

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
ENDPOINT_A=$(get_participant 0 endpoint)
ENDPOINT_B=$(get_participant 1 endpoint)
API_KEY_A=$(get_participant 0 api_key)
API_KEY_B=$(get_participant 1 api_key)
MODEL_A=$(get_participant 0 model)
MODEL_B=$(get_participant 1 model)

if [[ -z "$ROLE_A" ]]; then ROLE_A="参与者"; fi
if [[ -z "$ROLE_B" ]]; then ROLE_B="参与者"; fi

# --- 获取 token（带错误检查）---
get_token() {
  local app_id=$1
  local app_secret=$2
  local resp
  resp=$(curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF
{"app_id":"$app_id","app_secret":"$app_secret"}
EOF
  )
  local code
  code=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',-1))" 2>/dev/null)
  if [[ "$code" != "0" ]]; then
    echo ""
    return 1
  fi
  echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['tenant_access_token'])"
}

TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A") || { echo "❌ 获取 $NAME_A token 失败"; exit 1; }
TOKEN_B=$(get_token "$APP_ID_B" "$APP_SECRET_B") || { echo "❌ 获取 $NAME_B token 失败"; exit 1; }

# --- 加载 prompt 模板 ---
TEMPLATE_FILE="$PROJECT_DIR/templates/${MODE}.md"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "❌ 模板不存在: $TEMPLATE_FILE（可用模式: debate, review, brainstorm, freeform）"
  exit 1
fi
TEMPLATE=$(cat "$TEMPLATE_FILE")

build_prompt() {
  local role=$1
  local opponent_text=$2
  local round=$3
  local total=$4
  local is_last=$5

  # 用 python 做模板替换，避免 sed 特殊字符问题
  # 用临时文件传参，避免 ARG_MAX 和 ps 暴露
  local tmpfile_tpl tmpfile_opp
  tmpfile_tpl=$(mktemp /tmp/bot2bot-tpl-XXXXXX.txt)
  tmpfile_opp=$(mktemp /tmp/bot2bot-opp-XXXXXX.txt)
  printf '%s' "$TEMPLATE" > "$tmpfile_tpl"
  printf '%s' "$opponent_text" > "$tmpfile_opp"

  local prompt
  prompt=$(python3 - "$tmpfile_tpl" "$role" "$TOPIC" "$tmpfile_opp" "$round" "$total" "$is_last" << 'PYEOF'
import sys

tpl_file, role, topic, opp_file, rnd, total, is_last = sys.argv[1:8]

with open(tpl_file) as f:
    prompt = f.read()
with open(opp_file) as f:
    opponent = f.read().strip()

prompt = prompt.replace("{{role}}", role).replace("{{topic}}", topic)

if opponent:
    prompt += f"\n\n---\n对方上一轮的发言：\n{opponent}"

if is_last == "true":
    prompt += f"\n\n这是最后一轮（第 {rnd}/{total} 轮），请给出总结性观点。"
else:
    prompt += f"\n\n这是第 {rnd}/{total} 轮。"

print(prompt)
PYEOF
  )
  rm -f "$tmpfile_tpl" "$tmpfile_opp"
  echo "$prompt"
}

# --- 调用 bot（自动选择 local-cli 或 http-api）---
call_bot() {
  local bot_type=$1
  local cmd_template=$2
  local parse_cmd=$3
  local message=$4
  local timeout_sec=$5
  local endpoint=$6
  local api_key=$7
  local model=$8

  if [[ "$bot_type" == "http-api" ]]; then
    call_bot_http "$endpoint" "$api_key" "$model" "$message" "$timeout_sec"
  else
    call_bot_cli "$cmd_template" "$parse_cmd" "$message" "$timeout_sec"
  fi
}

# local-cli 模式
call_bot_cli() {
  local cmd_template=$1
  local parse_cmd=$2
  local message=$3
  local timeout_sec=$4

  local tmpfile
  tmpfile=$(mktemp /tmp/bot2bot-msg-XXXXXX.txt)
  printf '%s' "$message" > "$tmpfile"

  local result=""
  local exit_code=0
  local msg_content
  msg_content=$(cat "$tmpfile")

  if echo "$cmd_template" | grep -q "openclaw agent"; then
    local agent_id
    agent_id=$(echo "$cmd_template" | sed -n 's/.*--agent  *\([^ ]*\).*/\1/p')
    if [[ -z "$agent_id" ]]; then agent_id="main"; fi
    result=$($TIMEOUT_CMD "$timeout_sec" openclaw agent --agent "$agent_id" --message "$msg_content" --json 2>/dev/null) || exit_code=$?
  elif echo "$cmd_template" | grep -q "hermes chat"; then
    result=$($TIMEOUT_CMD "$timeout_sec" hermes chat -q "$msg_content" -Q 2>/dev/null) || exit_code=$?
  else
    echo "❌ 不支持的命令模板: $cmd_template" >&2
    rm -f "$tmpfile"
    return 1
  fi

  rm -f "$tmpfile"

  if [[ $exit_code -ne 0 || -z "$result" ]]; then
    echo "[超时或调用失败]"
    return 1
  fi

  if [[ -n "$parse_cmd" ]]; then
    echo "$result" | eval "$parse_cmd" || echo "$result"
  else
    echo "$result"
  fi
}

# http-api 模式（OpenAI 兼容接口）
call_bot_http() {
  local endpoint=$1
  local api_key=$2
  local model=$3
  local message=$4
  local timeout_sec=$5

  if [[ -z "$endpoint" ]]; then
    echo "❌ http-api 模式需要配置 endpoint" >&2
    return 1
  fi

  if [[ -z "$model" ]]; then model="hermes-agent"; fi

  local tmpfile
  tmpfile=$(mktemp /tmp/bot2bot-http-XXXXXX.json)

  # 构造 OpenAI 兼容请求体
  python3 - "$message" "$model" "$tmpfile" << 'PYEOF'
import sys, json
message, model, outfile = sys.argv[1:4]
body = {
    "model": model,
    "messages": [{"role": "user", "content": message}],
    "stream": False
}
with open(outfile, 'w') as f:
    json.dump(body, f, ensure_ascii=False)
PYEOF

  local auth_header=""
  if [[ -n "$api_key" ]]; then
    auth_header="Authorization: Bearer $api_key"
  fi

  local resp
  resp=$(curl -s --max-time "$timeout_sec" \
    -X POST "$endpoint" \
    -H "Content-Type: application/json" \
    ${auth_header:+-H "$auth_header"} \
    -d @"$tmpfile" 2>/dev/null)

  rm -f "$tmpfile"

  if [[ -z "$resp" ]]; then
    echo "[超时或调用失败]"
    return 1
  fi

  # 从 OpenAI 兼容响应中提取 content
  local content
  content=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    choices = d.get('choices', [])
    if choices:
        print(choices[0].get('message', {}).get('content', ''))
    else:
        print(d.get('error', {}).get('message', '[API 返回无内容]'))
except:
    print('[响应解析失败]')
" 2>/dev/null)

  if [[ -z "$content" || "$content" == "[API 返回无内容]" || "$content" == "[响应解析失败]" ]]; then
    echo "[HTTP API 调用失败]"
    return 1
  fi

  echo "$content"
}

# --- 发送飞书消息（带错误处理）---
send_feishu_message() {
  local token=$1
  local chat_id=$2
  local text=$3
  local reply_to=$4
  local bot_name=$5
  local round=$6
  local total=$7

  local tmpfile
  tmpfile=$(mktemp /tmp/bot2bot-send-XXXXXX.txt)
  printf '%s' "$text" > "$tmpfile"

  # 通过环境变量传 token，避免在 ps 中暴露
  local msg_id
  msg_id=$(BOT2BOT_TOKEN="$token" python3 - "$chat_id" "$tmpfile" "$reply_to" "$bot_name" "$round" "$total" << 'PYEOF'
import sys, os, json, urllib.request, urllib.error

token = os.environ["BOT2BOT_TOKEN"]
chat_id, textfile, reply_to, bot_name, rnd, total = sys.argv[1:7]

with open(textfile) as f:
    text = f.read().strip()

footer = f"_({rnd}/{total} · {bot_name})_" if rnd not in ("end", "") else ""
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
    raw = urllib.request.urlopen(req, timeout=15).read()
    resp = json.loads(raw)
    code = resp.get("code", -1)
    if code != 0:
        print(f"FEISHU_ERROR:{code}:{resp.get('msg','')}", file=sys.stderr)
        print("")
    else:
        print(resp.get("data", {}).get("message_id", ""))
except urllib.error.HTTPError as e:
    print(f"HTTP_ERROR:{e.code}", file=sys.stderr)
    print("")
except Exception as e:
    print(f"SEND_ERROR:{e}", file=sys.stderr)
    print("")
PYEOF
  )

  rm -f "$tmpfile"

  if [[ -z "$msg_id" ]]; then
    echo "⚠️ 消息发送失败（$bot_name 第 $round 轮）" >&2
  fi
  echo "$msg_id"
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
LAST_GOOD_MSG_ID=""
LAST_TEXT=""
CONSENSUS=false

# 确定先后顺序
if [[ "$FIRST" == "b" ]]; then
  TMP=$NAME_A; NAME_A=$NAME_B; NAME_B=$TMP
  TMP=$ROLE_A; ROLE_A=$ROLE_B; ROLE_B=$TMP
  TMP=$TOKEN_A; TOKEN_A=$TOKEN_B; TOKEN_B=$TMP
  TMP=$TYPE_A; TYPE_A=$TYPE_B; TYPE_B=$TMP
  TMP=$CMD_A; CMD_A=$CMD_B; CMD_B=$TMP
  TMP=$PARSE_A; PARSE_A=$PARSE_B; PARSE_B=$TMP
  TMP=$APP_ID_A; APP_ID_A=$APP_ID_B; APP_ID_B=$TMP
  TMP=$APP_SECRET_A; APP_SECRET_A=$APP_SECRET_B; APP_SECRET_B=$TMP
  TMP=$ENDPOINT_A; ENDPOINT_A=$ENDPOINT_B; ENDPOINT_B=$TMP
  TMP=$API_KEY_A; API_KEY_A=$API_KEY_B; API_KEY_B=$TMP
  TMP=$MODEL_A; MODEL_A=$MODEL_B; MODEL_B=$TMP
fi

for round in $(seq 1 "$ROUNDS"); do
  IS_LAST="false"
  [[ "$round" -eq "$ROUNDS" ]] && IS_LAST="true"

  # --- Bot A 发言 ---
  echo "--- 第 ${round}/${ROUNDS} 轮 · $NAME_A ---"
  PROMPT_A=$(build_prompt "$ROLE_A" "$LAST_TEXT" "$round" "$ROUNDS" "$IS_LAST")
  TEXT_A=$(call_bot "$TYPE_A" "$CMD_A" "$PARSE_A" "$PROMPT_A" "$TIMEOUT" "$ENDPOINT_A" "$API_KEY_A" "$MODEL_A") || true

  if [[ -z "$TEXT_A" || "$TEXT_A" == "[超时或调用失败]" ]]; then
    echo "⚠️ $NAME_A 回复失败或超时，跳过本轮"
    continue
  fi

  echo "$NAME_A: ${TEXT_A:0:100}..."

  TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A" 2>/dev/null) || true

  # reply 链容错：发送失败时回退到上一条成功的 msg_id
  reply_target="${LAST_MSG_ID:-$LAST_GOOD_MSG_ID}"
  new_msg_id=""
  new_msg_id=$(send_feishu_message "$TOKEN_A" "$CHAT_ID" "$TEXT_A" "$reply_target" "$NAME_A" "$round" "$ROUNDS")
  if [[ -n "$new_msg_id" ]]; then
    LAST_MSG_ID="$new_msg_id"
    LAST_GOOD_MSG_ID="$new_msg_id"
    echo "  → 已发到群里"
  else
    echo "  ⚠️ 发送失败，讨论内容仍会继续"
    LAST_MSG_ID=""
  fi

  if check_consensus "$TEXT_A"; then
    echo "✅ $NAME_A 表示达成共识"
    CONSENSUS=true
    break
  fi

  LAST_TEXT="$TEXT_A"

  # --- Bot B 发言 ---
  echo "--- 第 ${round}/${ROUNDS} 轮 · $NAME_B ---"
  PROMPT_B=$(build_prompt "$ROLE_B" "$LAST_TEXT" "$round" "$ROUNDS" "$IS_LAST")
  TEXT_B=$(call_bot "$TYPE_B" "$CMD_B" "$PARSE_B" "$PROMPT_B" "$TIMEOUT" "$ENDPOINT_B" "$API_KEY_B" "$MODEL_B") || true

  if [[ -z "$TEXT_B" || "$TEXT_B" == "[超时或调用失败]" ]]; then
    echo "⚠️ $NAME_B 回复失败或超时，跳过本轮"
    continue
  fi

  echo "$NAME_B: ${TEXT_B:0:100}..."

  TOKEN_B=$(get_token "$APP_ID_B" "$APP_SECRET_B" 2>/dev/null) || true

  reply_target="${LAST_MSG_ID:-$LAST_GOOD_MSG_ID}"
  new_msg_id=$(send_feishu_message "$TOKEN_B" "$CHAT_ID" "$TEXT_B" "$reply_target" "$NAME_B" "$round" "$ROUNDS")
  if [[ -n "$new_msg_id" ]]; then
    LAST_MSG_ID="$new_msg_id"
    LAST_GOOD_MSG_ID="$new_msg_id"
    echo "  → 已发到群里"
  else
    echo "  ⚠️ 发送失败，讨论内容仍会继续"
    LAST_MSG_ID=""
  fi

  if check_consensus "$TEXT_B"; then
    echo "✅ $NAME_B 表示达成共识"
    CONSENSUS=true
    break
  fi

  LAST_TEXT="$TEXT_B"
  echo ""
done

# --- 结束 ---
echo ""
if [[ "$CONSENSUS" == "true" ]]; then
  echo "=== 讨论结束（共识达成）==="
  END_MSG="⏹ 讨论结束 — 双方达成共识"
else
  echo "=== 讨论结束（${ROUNDS} 轮完成）==="
  END_MSG="⏹ 讨论结束 — 已完成 ${ROUNDS} 轮"
fi

# 发结束消息（回退到最后成功的 msg_id）
TOKEN_A=$(get_token "$APP_ID_A" "$APP_SECRET_A" 2>/dev/null) || true
end_reply="${LAST_MSG_ID:-$LAST_GOOD_MSG_ID}"
if [[ -n "$end_reply" ]]; then
  send_feishu_message "$TOKEN_A" "$CHAT_ID" "$END_MSG" "$end_reply" "" "end" "" >/dev/null 2>&1 || true
fi

echo "完成。"
