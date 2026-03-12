#!/bin/bash
# 获取有效的飞书 user_access_token
# 自动刷新过期 token，输出到 stdout 供其他脚本使用
# 用法: TOKEN=$(bash plugins/feishu-auth/get-token.sh)
# 注意: refresh_token 只能用一次，每次刷新后会更新 tokens.json

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"
TOKENS_FILE="$PLUGIN_DIR/tokens.json"

# 加载 .env
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

APP_ID="${FEISHU_APP_ID:?'FEISHU_APP_ID not set'}"
APP_SECRET="${FEISHU_APP_SECRET:?'FEISHU_APP_SECRET not set'}"

# 检查 tokens.json 存在
if [ ! -f "$TOKENS_FILE" ]; then
  echo "ERROR: No tokens found. Run 'bash plugins/feishu-auth/setup.sh' first." >&2
  exit 1
fi

# 读取 token 信息
read_tokens() {
  python3 -c "
import json
with open('$TOKENS_FILE') as f:
    t = json.load(f)
print(t.get('access_token', ''))
print(t.get('refresh_token', ''))
print(t.get('expires_at', 0))
print(t.get('refresh_expires_at', 0))
"
}

tokens_output=$(read_tokens)
ACCESS_TOKEN=$(echo "$tokens_output" | sed -n '1p')
REFRESH_TOKEN=$(echo "$tokens_output" | sed -n '2p')
EXPIRES_AT=$(echo "$tokens_output" | sed -n '3p')
REFRESH_EXPIRES_AT=$(echo "$tokens_output" | sed -n '4p')

NOW_MS=$(($(date +%s) * 1000))
# 提前 5 分钟刷新
BUFFER=300000

# 检查 refresh_token 是否过期
if [ "$NOW_MS" -ge "$REFRESH_EXPIRES_AT" ] 2>/dev/null; then
  echo "ERROR: refresh_token expired (code 20037). Run 'bash plugins/feishu-auth/setup.sh' to re-authorize." >&2
  exit 1
fi

# access_token 未过期，直接返回
if [ "$NOW_MS" -lt "$((EXPIRES_AT - BUFFER))" ] 2>/dev/null; then
  echo "$ACCESS_TOKEN"
  exit 0
fi

# access_token 过期，用 refresh_token 刷新
# 注意：refresh_token 只能使用一次，刷新后必须更新
REFRESH_RESULT=$(curl -s -X POST 'https://open.feishu.cn/open-apis/authen/v2/oauth/token' \
  -H 'Content-Type: application/json; charset=utf-8' \
  -d "{
    \"grant_type\": \"refresh_token\",
    \"client_id\": \"${APP_ID}\",
    \"client_secret\": \"${APP_SECRET}\",
    \"refresh_token\": \"${REFRESH_TOKEN}\"
  }" 2>/dev/null)

# 检查返回的 error code
ERROR_CODE=$(echo "$REFRESH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('code', d.get('error', '')))" 2>/dev/null || echo "parse_error")

if [ "$ERROR_CODE" = "20037" ] || [ "$ERROR_CODE" = "20064" ] || [ "$ERROR_CODE" = "20073" ]; then
  echo "ERROR: refresh_token invalid or expired (code $ERROR_CODE). Run 'bash plugins/feishu-auth/setup.sh' to re-authorize." >&2
  exit 1
fi

NEW_ACCESS=$(echo "$REFRESH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

if [ -z "$NEW_ACCESS" ]; then
  echo "ERROR: Token refresh failed: $REFRESH_RESULT" >&2
  echo "Run 'bash plugins/feishu-auth/setup.sh' to re-authorize." >&2
  exit 1
fi

# 更新 tokens.json（refresh_token 是单次使用，必须保存新的）
python3 << PYEOF
import json, time, datetime

result = json.loads('''${REFRESH_RESULT}''')
with open('${TOKENS_FILE}') as f:
    tokens = json.load(f)

tokens['access_token'] = result['access_token']
# refresh_token 单次使用，必须更新为新的
tokens['refresh_token'] = result.get('refresh_token', '')
tokens['expires_at'] = int(time.time() * 1000) + result.get('expires_in', 7200) * 1000
if 'refresh_token_expires_in' in result:
    tokens['refresh_expires_at'] = int(time.time() * 1000) + result['refresh_token_expires_in'] * 1000
elif 'refresh_expires_in' in result:
    tokens['refresh_expires_at'] = int(time.time() * 1000) + result['refresh_expires_in'] * 1000
tokens['refreshed_at'] = datetime.datetime.now().isoformat()

with open('${TOKENS_FILE}', 'w') as f:
    json.dump(tokens, f, indent=2)
PYEOF

echo "$NEW_ACCESS"
