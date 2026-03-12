#!/bin/bash
# 综合站点报告 — 运行性能 + SEO + 地域分析，生成飞书 Wiki 文档
# 用法: bash scripts/site-report.sh [target_urls]
# 默认从 .env 读取配置

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$PROJECT_DIR/.env" ] && { set -a; source "$PROJECT_DIR/.env"; set +a; }

TARGET="${1:-${PERF_TARGET_URLS:-}}"

echo "╔══════════════════════════════════════╗"
echo "║     综合站点报告                      ║"
echo "╚══════════════════════════════════════╝"
echo ""

PERF_REPORT="" SEO_REPORT="" GEO_REPORT=""

# ── 1. 性能分析 ──
echo "▶ [1/3] 性能分析..."
PERF_REPORT=$(bash "$SCRIPT_DIR/perf-monitor.sh" "$TARGET" 2>&1 | tail -1)
echo "  → $PERF_REPORT"
echo ""

# ── 2. SEO 审计 ──
echo "▶ [2/3] SEO 审计..."
SEO_REPORT=$(bash "$SCRIPT_DIR/seo-audit.sh" 2>&1 | tail -1)
echo "  → $SEO_REPORT"
echo ""

# ── 3. 地域流量分析 ──
echo "▶ [3/3] 地域流量分析..."
GEO_REPORT=$(bash "$SCRIPT_DIR/geo-report.sh" 2>&1 | tail -1)
echo "  → $GEO_REPORT"
echo ""

# ── 4. 生成飞书文档 ──
echo "▶ 生成飞书综合报告..."
TENANT=$(curl -sf -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d "{\"app_id\":\"${FEISHU_APP_ID:-}\",\"app_secret\":\"${FEISHU_APP_SECRET:-}\"}" | jq -r '.tenant_access_token // empty')

if [ -n "$TENANT" ]; then
  DOC_URL=$(bash "$SCRIPT_DIR/feishu-site-report.sh" "$PERF_REPORT" "$SEO_REPORT" "$GEO_REPORT" "$TENANT" 2>/dev/null)
  echo ""
  echo "══════════════════════════════════════"
  echo "📄 报告文档: $DOC_URL"
  echo "══════════════════════════════════════"
else
  echo "  ⚠️ 飞书 Token 获取失败，跳过文档生成"
fi
