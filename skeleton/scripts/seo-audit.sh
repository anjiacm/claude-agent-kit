#!/bin/bash
# SEO 深度审计 — Lighthouse SEO + 基础检查
# 用法: bash scripts/seo-audit.sh [domain1,domain2,...] [output_dir]
# 输出: JSON 报告路径 (stdout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$PROJECT_DIR/.env" ] && { set -a; source "$PROJECT_DIR/.env"; set +a; }

DOMAINS="${1:-${SEO_CHECK_DOMAINS:-${PERF_TARGET_URLS:-}}}"
# 从 URL 提取域名
DOMAINS=$(echo "$DOMAINS" | sed -E 's|https?://||g;s|/[^ ,]*||g')
OUTPUT_DIR="${2:-$PROJECT_DIR/data/seo-reports}"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

if [ -z "$DOMAINS" ]; then
  echo "错误: 未配置目标域名" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== SEO 深度审计 $(date '+%Y-%m-%d %H:%M') ===" >&2

RESULTS_JSON="[]"

IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
for domain in "${DOMAIN_LIST[@]}"; do
  domain=$(echo "$domain" | tr -d '[:space:]')
  [ -z "$domain" ] && continue
  URL="https://$domain"

  echo "--- $domain ---" >&2

  # ── 1. Lighthouse SEO 审计 ──
  LH_SEO_SCORE=""
  LH_AUDITS="[]"
  LH_JSON="$OUTPUT_DIR/lh-seo-${TIMESTAMP}-${domain}.json"

  echo "  [Lighthouse SEO] 运行中..." >&2
  if lighthouse "$URL" \
    --output=json --output-path="$LH_JSON" \
    --chrome-flags="--headless --no-sandbox --disable-gpu" \
    --only-categories=seo \
    --quiet 2>/dev/null; then

    LH_SEO_SCORE=$(jq -r '.categories.seo.score * 100 | floor' "$LH_JSON" 2>/dev/null || echo "")
    echo "  SEO Score: ${LH_SEO_SCORE}" >&2

    # 提取每项审计结果
    LH_AUDITS=$(jq '[
      .categories.seo.auditRefs[] as $ref |
      .audits[$ref.id] |
      select(.score != null) |
      {
        id: .id,
        title: .title,
        score: .score,
        description: (.description | split("[Learn")[0] | gsub("\\n"; " ") | .[0:120]),
        displayValue: (.displayValue // null),
        details_count: ((.details.items // []) | length)
      }
    ] | sort_by(.score)' "$LH_JSON" 2>/dev/null || echo "[]")
  else
    echo "  [Lighthouse SEO] 运行失败" >&2
  fi

  # ── 2. 结构化数据检查 ──
  echo "  [结构化数据] 检查中..." >&2
  STRUCTURED_DATA="{}"
  if [ -f "$LH_JSON" ]; then
    # 从 Lighthouse 的 structured-data 审计提取
    STRUCTURED_DATA=$(jq '{
      has_structured_data: ((.audits["structured-data"].score // 1) == 1),
      is_crawlable: ((.audits["is-crawlable"].score // 0) == 1),
      has_canonical: ((.audits["canonical"].score // 0) == 1),
      has_hreflang: ((.audits["hreflang"].score // null) == 1 or .audits["hreflang"].score == null),
      robots_valid: ((.audits["robots-txt"].score // 1) == 1),
      has_meta_description: ((.audits["meta-description"].score // 0) == 1),
      has_document_title: ((.audits["document-title"].score // 0) == 1),
      http_status: ((.audits["http-status-code"].score // 0) == 1),
      link_text: ((.audits["link-text"].score // 0) == 1),
      images_alt: ((.audits["image-alt"].score // 0) == 1),
      viewport: ((.audits["viewport"].score // 0) == 1),
      font_size: ((.audits["font-size"].score // null) == 1 or .audits["font-size"].score == null),
      tap_targets: ((.audits["tap-targets"].score // null) == 1 or .audits["tap-targets"].score == null)
    }' "$LH_JSON" 2>/dev/null || echo "{}")
  fi

  # ── 3. 基础检查（robots.txt / sitemap / 响应头）──
  echo "  [基础检查] 运行中..." >&2
  BASIC_CHECKS="[]"

  # robots.txt
  ROBOTS=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/robots.txt" 2>/dev/null || echo "")
  if [ -n "$ROBOTS" ]; then
    HAS_SITEMAP=$(echo "$ROBOTS" | grep -ci "sitemap:" || true)
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq --arg v "${#ROBOTS}字节, sitemap引用=$HAS_SITEMAP" \
      '. + [{name:"robots.txt", status:"pass", detail:$v}]')
  else
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq '. + [{name:"robots.txt", status:"fail", detail:"不可访问"}]')
  fi

  # sitemap.xml
  SITEMAP_STATUS=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 10 "$URL/sitemap.xml" 2>/dev/null || echo "000")
  if [ "$SITEMAP_STATUS" = "200" ] || [ "$SITEMAP_STATUS" = "301" ]; then
    URL_COUNT=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/sitemap.xml" 2>/dev/null | grep -c "<loc>" 2>/dev/null || echo "0")
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq --arg v "HTTP $SITEMAP_STATUS, ${URL_COUNT} URLs" \
      '. + [{name:"sitemap.xml", status:"pass", detail:$v}]')
  else
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq --arg v "HTTP $SITEMAP_STATUS" \
      '. + [{name:"sitemap.xml", status:"warn", detail:$v}]')
  fi

  # HSTS
  HAS_HSTS=$(curl -sfL -H "User-Agent: $UA" -I -m 10 -L "$URL/" 2>/dev/null | grep -ci "strict-transport-security" || true)
  if [ "$HAS_HSTS" -gt 0 ]; then
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq '. + [{name:"HSTS", status:"pass", detail:"已启用"}]')
  else
    BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq '. + [{name:"HSTS", status:"warn", detail:"未启用"}]')
  fi

  # 重定向链
  REDIR_INFO=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{num_redirects}" -m 10 -L "http://$domain/" 2>/dev/null || echo "0")
  REDIR_STATUS="pass"
  [ "$REDIR_INFO" -gt 2 ] && REDIR_STATUS="warn"
  BASIC_CHECKS=$(echo "$BASIC_CHECKS" | jq --arg s "$REDIR_STATUS" --arg v "${REDIR_INFO} 次重定向" \
    '. + [{name:"redirects", status:$s, detail:$v}]')

  # ── 4. 失败项统计 ──
  FAILED=$(echo "$LH_AUDITS" | jq '[.[] | select(.score == 0)] | length' 2>/dev/null || echo "0")
  PASSED=$(echo "$LH_AUDITS" | jq '[.[] | select(.score == 1)] | length' 2>/dev/null || echo "0")
  DOMAIN_STATUS="ok"
  [ "$FAILED" -ge 1 ] && DOMAIN_STATUS="warn"
  [ "$FAILED" -ge 3 ] && DOMAIN_STATUS="error"
  [ -z "$LH_SEO_SCORE" ] && DOMAIN_STATUS="unknown"

  echo "  → 通过=$PASSED 失败=$FAILED 状态=$DOMAIN_STATUS" >&2

  RESULT=$(jq -n \
    --arg domain "$domain" \
    --arg status "$DOMAIN_STATUS" \
    --argjson score "${LH_SEO_SCORE:-0}" \
    --argjson audits "$LH_AUDITS" \
    --argjson structured "$STRUCTURED_DATA" \
    --argjson basics "$BASIC_CHECKS" \
    --argjson failed "$FAILED" \
    --argjson passed "$PASSED" \
    '{domain:$domain, status:$status, seo_score:$score,
      passed:$passed, failed:$failed,
      audits:$audits, structured_data:$structured, basic_checks:$basics}')
  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson r "$RESULT" '. + [$r]')

  # 清理 Lighthouse JSON
  find "$OUTPUT_DIR" -name "lh-seo-*.json" -mtime +3 -delete 2>/dev/null || true
done

echo "=== SEO 审计完成 ===" >&2

REPORT_FILE="$OUTPUT_DIR/seo-audit-${TIMESTAMP}.json"
jq -n --arg ts "$TIMESTAMP" --argjson results "$RESULTS_JSON" \
  '{timestamp:$ts, results:$results}' > "$REPORT_FILE"

echo "$REPORT_FILE"
