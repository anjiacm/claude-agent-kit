#!/bin/bash
# 地域流量分析 — 基于 Cloudflare GraphQL Analytics
# 用法: bash scripts/geo-report.sh [days] [zone_id]
# 输出: JSON 报告路径 (stdout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$PROJECT_DIR/.env" ] && { set -a; source "$PROJECT_DIR/.env"; set +a; }

DAYS="${1:-7}"
ZONE_ID="${2:-${CF_ZONE_ID_NOUHAUS:-}}"
CF_TOK=$(echo -n "${CF_API_TOKEN:-}" | tr -d '[:space:]')
OUTPUT_DIR="$PROJECT_DIR/data/geo-reports"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

if [ -z "$CF_TOK" ] || [ -z "$ZONE_ID" ]; then
  echo "错误: 需要 CF_API_TOKEN 和 CF_ZONE_ID_NOUHAUS" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

DATE_END=$(date '+%Y-%m-%d')
DATE_START=$(date -v-${DAYS}d '+%Y-%m-%d' 2>/dev/null || date -d "${DAYS} days ago" '+%Y-%m-%d')

echo "=== 地域流量分析 (${DATE_START} ~ ${DATE_END}) ===" >&2

# ── 1. 地域分布 + 浏览器 + 缓存 ──
GEO_RAW=$(curl -s "https://api.cloudflare.com/client/v4/graphql" \
  -H "Authorization: Bearer $CF_TOK" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query { viewer { zones(filter:{zoneTag:\"'$ZONE_ID'\"}) { httpRequests1dGroups(limit:1, filter:{date_geq:\"'$DATE_START'\", date_leq:\"'$DATE_END'\"}) { sum { requests pageViews bytes cachedRequests cachedBytes countryMap { clientCountryName requests bytes threats } browserMap { uaBrowserFamily pageViews } responseStatusMap { edgeResponseStatus requests } contentTypeMap { edgeResponseContentTypeName requests bytes } } uniq { uniques } } } } }"
  }' 2>/dev/null)

if ! echo "$GEO_RAW" | jq -e '.data.viewer.zones[0]' >/dev/null 2>&1; then
  echo "错误: CF GraphQL 查询失败" >&2
  echo "$GEO_RAW" | jq '.errors' 2>/dev/null >&2
  exit 1
fi

# ── 2. 提取并格式化数据 ──
REPORT=$(echo "$GEO_RAW" | jq '
  .data.viewer.zones[0].httpRequests1dGroups[0] as $d |
  {
    period: {start: "'"$DATE_START"'", end: "'"$DATE_END"'", days: '"$DAYS"'},
    overview: {
      total_requests: $d.sum.requests,
      page_views: $d.sum.pageViews,
      unique_visitors: $d.uniq.uniques,
      bandwidth_mb: ($d.sum.bytes / 1048576 | floor),
      cached_requests: $d.sum.cachedRequests,
      cache_ratio_pct: (if $d.sum.requests > 0 then ($d.sum.cachedRequests / $d.sum.requests * 100 | floor) else 0 end),
      cached_bandwidth_mb: ($d.sum.cachedBytes / 1048576 | floor)
    },
    countries: [
      $d.sum.countryMap | sort_by(-.requests) | .[0:15] | .[] |
      {
        country: .clientCountryName,
        requests: .requests,
        bandwidth_mb: (.bytes / 1048576 | floor),
        threats: .threats,
        pct: (if $d.sum.requests > 0 then (.requests / $d.sum.requests * 100 * 10 | floor / 10) else 0 end)
      }
    ],
    browsers: [
      $d.sum.browserMap | sort_by(-.pageViews) | .[0:8] | .[] |
      {
        browser: .uaBrowserFamily,
        page_views: .pageViews,
        pct: (if $d.sum.pageViews > 0 then (.pageViews / $d.sum.pageViews * 100 * 10 | floor / 10) else 0 end)
      }
    ],
    status_codes: [
      $d.sum.responseStatusMap | sort_by(-.requests) | .[0:8] | .[] |
      { status: .edgeResponseStatus, requests: .requests }
    ],
    content_types: [
      $d.sum.contentTypeMap | sort_by(-.requests) | .[0:6] | .[] |
      {
        type: .edgeResponseContentTypeName,
        requests: .requests,
        bandwidth_mb: (.bytes / 1048576 | floor)
      }
    ]
  }
')

echo "$REPORT" | jq -r '
  "总览: \(.overview.total_requests) 请求 | \(.overview.page_views) PV | \(.overview.unique_visitors) UV | \(.overview.bandwidth_mb)MB",
  "缓存: \(.overview.cache_ratio_pct)% (\(.overview.cached_bandwidth_mb)MB)",
  "",
  "Top 5 国家:",
  (.countries[0:5][] | "  \(.country): \(.requests) 请求 (\(.pct)%) 威胁=\(.threats)")
' >&2

# ── 3. 保存报告 ──
REPORT_FILE="$OUTPUT_DIR/geo-${TIMESTAMP}.json"
echo "$REPORT" | jq --arg ts "$TIMESTAMP" '. + {timestamp: $ts}' > "$REPORT_FILE"

echo "$REPORT_FILE"
