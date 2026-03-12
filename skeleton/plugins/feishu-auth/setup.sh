#!/bin/bash
# 飞书 OAuth 一次性授权（通过 keys.artux.ai Worker relay）
# 用法: bash plugins/feishu-auth/setup.sh
# 前置: 飞书应用后台添加重定向 URL: https://keys.artux.ai/auth/callback
#       开通 offline_access 权限 + 刷新 token 安全开关

set -e
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"

# 加载 .env
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

APP_ID="${FEISHU_APP_ID:?'FEISHU_APP_ID not set in .env'}"
CALLBACK_PORT="${FEISHU_CALLBACK_PORT:-9876}"
REDIRECT_URI="https://keys.artux.ai/auth/callback"

# 检查是否已有有效 token
if [ -f "$PLUGIN_DIR/tokens.json" ]; then
  expires_at=$(python3 -c "import sys,json; print(json.load(open('$PLUGIN_DIR/tokens.json')).get('refresh_expires_at',0))" 2>/dev/null || echo "0")
  now_ms=$(($(date +%s) * 1000))
  if [ "$expires_at" -gt "$now_ms" ] 2>/dev/null; then
    echo "Token already exists and refresh_token is still valid."
    echo "Run 'bash plugins/feishu-auth/get-token.sh' to get a fresh access_token."
    read -p "Re-authorize anyway? (y/N) " confirm
    [ "$confirm" != "y" ] && exit 0
  fi
fi

# 构建授权 URL
# offline_access 必须包含，否则拿不到 refresh_token
SCOPES="offline_access wiki:wiki docx:document docx:document:readonly drive:drive drive:file bitable:bitable contact:user.id:readonly"
ENCODED_REDIRECT=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${REDIRECT_URI}'))")
ENCODED_SCOPES=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SCOPES}'))")

# 生成 CSRF token
CSRF=$(python3 -c "import secrets; print(secrets.token_hex(16))")

# state = "ops:port:csrf" — Worker 通过 app 名选凭据
STATE="ops:${CALLBACK_PORT}:${CSRF}"

AUTH_URL="https://accounts.feishu.cn/open-apis/authen/v1/authorize?client_id=${APP_ID}&redirect_uri=${ENCODED_REDIRECT}&scope=${ENCODED_SCOPES}&state=${STATE}"

echo "=== Feishu OAuth Setup ==="
echo ""
echo "1. Starting callback server on port ${CALLBACK_PORT}..."

# 启动回调服务器（后台）
node "$PLUGIN_DIR/callback-server.js" &
SERVER_PID=$!

# 确保退出时清理
cleanup() { kill $SERVER_PID 2>/dev/null; }
trap cleanup EXIT

sleep 1

echo "2. Opening browser for authorization..."
echo ""
echo "   If browser doesn't open, visit:"
echo "   $AUTH_URL"
echo ""

# 打开浏览器
if command -v open &>/dev/null; then
  open "$AUTH_URL"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$AUTH_URL"
else
  echo "   Please open the URL above manually."
fi

echo "3. Waiting for authorization callback (via keys.artux.ai relay)..."
echo "   (Will timeout in 5 minutes)"
echo ""

# 等待回调服务器完成
wait $SERVER_PID
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && [ -f "$PLUGIN_DIR/tokens.json" ]; then
  echo ""
  echo "=== Authorization Complete ==="
  echo "Tokens saved to: $PLUGIN_DIR/tokens.json"
  echo ""
  echo "Usage:"
  echo '  TOKEN=$(bash plugins/feishu-auth/get-token.sh)'
  echo '  curl -H "Authorization: Bearer $TOKEN" https://open.feishu.cn/...'
else
  echo ""
  echo "=== Authorization Failed ==="
  echo "Check:"
  echo "  1. 飞书应用后台是否添加了重定向 URL: https://keys.artux.ai/auth/callback"
  echo "  2. 是否开通了 offline_access 权限"
  echo "  3. Worker 是否已部署 OPS 应用凭据"
  exit 1
fi
