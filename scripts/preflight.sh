#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$HOME/.bot2bot/config.yaml"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ 配置文件不存在: $CONFIG_FILE"
  echo "   请创建配置文件，参考 references/config-guide.md"
  exit 1
fi

echo "=== lark-bot2bot preflight ==="
ERRORS=0

# 检查依赖
for dep in python3 curl jq; do
  if command -v "$dep" &>/dev/null; then
    echo "✅ $dep: 可用"
  else
    echo "❌ $dep: 未安装"
    ERRORS=$((ERRORS + 1))
  fi
done

# 检查 pyyaml
if python3 -c "import yaml" 2>/dev/null; then
  echo "✅ pyyaml: 可用"
else
  echo "❌ pyyaml: 未安装（pip3 install pyyaml）"
  ERRORS=$((ERRORS + 1))
fi

# 解析配置
CONFIG_JSON=$(python3 -c "
import yaml, json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    print(json.dumps(cfg))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" "$CONFIG_FILE" 2>/dev/null) || {
  echo "❌ 配置文件解析失败"
  exit 1
}

if echo "$CONFIG_JSON" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
  true
else
  ERR=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('error',''))")
  echo "❌ 配置文件解析失败: $ERR"
  exit 1
fi

CHAT_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('chat_id',''))")
if [[ -z "$CHAT_ID" ]]; then
  echo "❌ chat_id 未配置"
  ERRORS=$((ERRORS + 1))
else
  echo "✅ chat_id: $CHAT_ID"
fi

PARTICIPANT_COUNT=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('participants',[])))")
if [[ "$PARTICIPANT_COUNT" -lt 2 ]]; then
  echo "❌ 需要至少 2 个参与方，当前: $PARTICIPANT_COUNT"
  ERRORS=$((ERRORS + 1))
fi

for i in $(seq 0 $((PARTICIPANT_COUNT - 1))); do
  NAME=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$i];print(p.get('name',''))")
  TYPE=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$i];print(p.get('type',''))")
  APP_ID=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$i];print(p.get('bot_app_id',''))")
  APP_SECRET=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$i];print(p.get('bot_app_secret',''))")

  echo ""
  echo "--- $NAME ---"

  if [[ -z "$APP_ID" || -z "$APP_SECRET" ]]; then
    echo "❌ $NAME: bot_app_id 或 bot_app_secret 未配置"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 获取 tenant_access_token（用 --data-binary @- 避免 secret 出现在 ps 中）
  TOKEN_RESP=$(curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF
{"app_id":"$APP_ID","app_secret":"$APP_SECRET"}
EOF
  )
  TOKEN_CODE=$(echo "$TOKEN_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',-1))" 2>/dev/null || echo "-1")

  if [[ "$TOKEN_CODE" == "0" ]]; then
    echo "✅ $NAME token: 获取成功"
  else
    echo "❌ $NAME token: 获取失败 (code=$TOKEN_CODE)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [[ "$TYPE" == "local-cli" ]]; then
    CMD=$(echo "$CONFIG_JSON" | python3 -c "import sys,json;p=json.load(sys.stdin)['participants'][$i];print(p.get('command',''))")
    BIN=$(echo "$CMD" | awk '{print $1}')
    if command -v "$BIN" &>/dev/null; then
      echo "✅ $NAME CLI: $BIN 可用"
    else
      echo "❌ $NAME CLI: $BIN 不可用"
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo "❌ 前置检查失败（$ERRORS 个问题）"
  exit 1
else
  echo "✅ 前置检查通过"
  exit 0
fi
