#!/usr/bin/env bash
# 创建飞书综合站点报告（性能 + SEO + 地域，写入 Wiki 知识库）
# 用法: bash scripts/feishu-site-report.sh <perf.json> <seo.json> <geo.json> <token>
# 任何报告文件可传 "" 跳过

set -euo pipefail

PERF_FILE="${1:-}"
SEO_FILE="${2:-}"
GEO_FILE="${3:-}"
TOKEN="${4:-}"
FEISHU_DOMAIN="${FEISHU_DOMAIN:-hengjunhome.feishu.cn}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$PROJECT_DIR/data/cf-reports/daemon.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] site-report: $*" >> "$LOG_FILE" 2>/dev/null || true; }

# 至少需要一个报告
[ -z "$PERF_FILE" ] && [ -z "$SEO_FILE" ] && [ -z "$GEO_FILE" ] && { echo ""; exit 0; }

dt=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
first_domain=""
[ -n "$PERF_FILE" ] && [ -f "$PERF_FILE" ] && first_domain=$(jq -r '.results[0].url // empty' "$PERF_FILE" | sed 's|https\?://||;s|/.*||')
[ -z "$first_domain" ] && [ -n "$SEO_FILE" ] && [ -f "$SEO_FILE" ] && first_domain=$(jq -r '.results[0].domain // empty' "$SEO_FILE")
[ -z "$first_domain" ] && first_domain="site"
DOC_TITLE="📊 ${first_domain} 综合报告 | ${dt}"

# ── 创建文档（Wiki 优先）──
WIKI_SPACE="${FEISHU_PERF_WIKI_SPACE_ID:-}"
USER_TOKEN=""
DOC_ID=""
NODE_TOKEN=""

if [ -n "$WIKI_SPACE" ] && [ -f "$PROJECT_DIR/plugins/feishu-auth/get-token.sh" ]; then
  USER_TOKEN=$(bash "$PROJECT_DIR/plugins/feishu-auth/get-token.sh" 2>/dev/null) || true
fi

if [ -n "$WIKI_SPACE" ] && [ -n "$USER_TOKEN" ]; then
  WIKI_RESP=$(curl -sf -X POST "https://open.feishu.cn/open-apis/wiki/v2/spaces/${WIKI_SPACE}/nodes" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg t "$DOC_TITLE" '{"obj_type":"docx","node_type":"origin","title":$t}')" 2>/dev/null) || true
  DOC_ID=$(echo "$WIKI_RESP" | jq -r '.data.node.obj_token // empty' 2>/dev/null)
  NODE_TOKEN=$(echo "$WIKI_RESP" | jq -r '.data.node.node_token // empty' 2>/dev/null)
fi

if [ -z "$DOC_ID" ]; then
  DOC_RESP=$(curl -sf -X POST "https://open.feishu.cn/open-apis/docx/v1/documents" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg t "$DOC_TITLE" '{title:$t}')")
  DOC_ID=$(echo "$DOC_RESP" | jq -r '.data.document.document_id // empty')
fi

if [ -z "$DOC_ID" ]; then
  log "创建文档失败"
  echo ""
  exit 0
fi
log "文档已创建: $DOC_ID"

WRITE_TOKEN="${USER_TOKEN:-$TOKEN}"

# ── 辅助函数 ──
add_block() {
  curl -sf -X POST \
    "https://open.feishu.cn/open-apis/docx/v1/documents/$DOC_ID/blocks/$DOC_ID/children" \
    -H "Authorization: Bearer $WRITE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$1" > /dev/null 2>&1
}

add_heading1() { add_block "$(jq -n --arg t "$1" '{children:[{block_type:3,heading1:{elements:[{text_run:{content:$t}}]}}],index:-1}')"; }
add_heading2() { add_block "$(jq -n --arg t "$1" '{children:[{block_type:4,heading2:{elements:[{text_run:{content:$t}}]}}],index:-1}')"; }
add_text() { add_block "$(jq -n --arg t "$1" '{children:[{block_type:2,text:{elements:[{text_run:{content:$t}}]}}],index:-1}')"; }
add_code() { add_block "$(jq -n --arg t "$1" '{children:[{block_type:14,code:{elements:[{text_run:{content:$t}}],language:1}}],index:-1}')"; }
add_divider() { add_block '{"children":[{"block_type":22,"divider":{}}],"index":-1}'; }
add_bullet() { add_block "$(jq -n --arg t "$1" '{children:[{block_type:12,bullet:{elements:[{text_run:{content:$t}}]}}],index:-1}')"; }

rate_emoji() {
  local val="$1" good="$2" poor="$3" direction="${4:-lower}"
  if [ "$direction" = "lower" ]; then
    [ "$val" -le "$good" ] 2>/dev/null && echo "🟢" && return
    [ "$val" -ge "$poor" ] 2>/dev/null && echo "🔴" && return
  else
    [ "$val" -ge "$good" ] 2>/dev/null && echo "🟢" && return
    [ "$val" -le "$poor" ] 2>/dev/null && echo "🔴" && return
  fi
  echo "🟡"
}

# ══════════════════════════════════════════
# 📊 性能分析
# ══════════════════════════════════════════
if [ -n "$PERF_FILE" ] && [ -f "$PERF_FILE" ]; then
  perf_count=$(jq -r '.results | length' "$PERF_FILE")
  if [ "$perf_count" -gt 0 ]; then
    add_heading1 "📊 性能分析"

    i=0
    while [ "$i" -lt "$perf_count" ]; do
      url=$(jq -r ".results[$i].url" "$PERF_FILE")
      score=$(jq -r ".results[$i].score" "$PERF_FILE")
      lcp=$(jq -r ".results[$i].lcp" "$PERF_FILE")
      fcp=$(jq -r ".results[$i].fcp" "$PERF_FILE")
      cls=$(jq -r ".results[$i].cls" "$PERF_FILE")
      ttfb=$(jq -r ".results[$i].ttfb" "$PERF_FILE")
      tbt=$(jq -r ".results[$i].tbt // 0" "$PERF_FILE")

      short_url=$(echo "$url" | sed -E 's|https?://||')
      add_heading2 "$short_url"

      # 指标概览
      se=$(rate_emoji "$score" 90 50 higher)
      le=$(rate_emoji "$lcp" 2500 4000 lower)
      te=$(rate_emoji "$ttfb" 800 1800 lower)
      be=$(rate_emoji "$tbt" 200 600 lower)
      cls_display=$(echo "$cls" | awk '{printf "%.2f", $1}')

      overview="$se Score: ${score}  |  $le LCP: ${lcp}ms  |  FCP: ${fcp}ms\n$te TTFB: ${ttfb}ms  |  $be TBT: ${tbt}ms  |  CLS: ${cls_display}"
      add_text "$(echo -e "$overview")"

      # LCP 元素分析
      lcp_selector=$(jq -r ".results[$i].lcpElement.selector // empty" "$PERF_FILE")
      if [ -n "$lcp_selector" ]; then
        lcp_snippet=$(jq -r ".results[$i].lcpElement.snippet // empty" "$PERF_FILE")
        lcp_img=$(echo "$lcp_snippet" | sed -n 's/.*src="\([^"]*\)".*/\1/p' | head -1 || true)
        code_text="LCP 元素: ${lcp_selector}"
        [ -n "$lcp_img" ] && code_text="${code_text}\n图片: ${lcp_img}"
        add_code "$code_text"

        # LCP 阶段
        phase_count=$(jq -r ".results[$i].lcpPhases | length" "$PERF_FILE" 2>/dev/null || echo "0")
        if [ "$phase_count" -gt 0 ]; then
          phase_text=""
          j=0
          while [ "$j" -lt "$phase_count" ]; do
            p_name=$(jq -r ".results[$i].lcpPhases[$j].phase" "$PERF_FILE")
            p_dur=$(jq -r ".results[$i].lcpPhases[$j].duration_ms" "$PERF_FILE")
            pct=0; [ "$lcp" -gt 0 ] && pct=$((p_dur * 100 / lcp))
            marker=""; [ "$pct" -gt 40 ] && marker=" ⚠️"
            phase_text="${phase_text}${p_name}: ${p_dur}ms (${pct}%)${marker}  |  "
            j=$((j + 1))
          done
          add_text "${phase_text%  |  }"
        fi
      fi

      # 第三方脚本
      tp_count=$(jq -r ".results[$i].thirdParties | length" "$PERF_FILE" 2>/dev/null || echo "0")
      if [ "$tp_count" -gt 0 ]; then
        tp_text=""
        j=0
        while [ "$j" -lt "$tp_count" ]; do
          tp_name=$(jq -r ".results[$i].thirdParties[$j].name" "$PERF_FILE")
          tp_size=$(jq -r ".results[$i].thirdParties[$j].size_kb" "$PERF_FILE")
          tp_time=$(jq -r ".results[$i].thirdParties[$j].main_thread_ms" "$PERF_FILE")
          tp_text="${tp_text}• ${tp_name}: ${tp_size}KB / ${tp_time}ms\n"
          j=$((j + 1))
        done
        add_text "第三方脚本:"
        add_text "$(echo -e "$tp_text")"
      fi

      # 优化建议
      opp_count=$(jq -r ".results[$i].opportunities | length" "$PERF_FILE" 2>/dev/null || echo "0")
      if [ "$opp_count" -gt 0 ]; then
        j=0
        while [ "$j" -lt "$opp_count" ]; do
          opp_title=$(jq -r ".results[$i].opportunities[$j].title" "$PERF_FILE")
          opp_savings=$(jq -r ".results[$i].opportunities[$j].savings_ms" "$PERF_FILE")
          add_bullet "💡 ${opp_title} — 可节省 ${opp_savings}ms"
          j=$((j + 1))
        done
      fi

      i=$((i + 1))
      [ "$i" -lt "$perf_count" ] && add_divider
    done
  fi
fi

# ══════════════════════════════════════════
# 🔍 SEO 审计
# ══════════════════════════════════════════
if [ -n "$SEO_FILE" ] && [ -f "$SEO_FILE" ]; then
  seo_count=$(jq -r '.results | length' "$SEO_FILE")
  if [ "$seo_count" -gt 0 ]; then
    [ -n "$PERF_FILE" ] && [ -f "$PERF_FILE" ] && add_divider
    add_heading1 "🔍 SEO 审计"

    i=0
    while [ "$i" -lt "$seo_count" ]; do
      domain=$(jq -r ".results[$i].domain" "$SEO_FILE")
      seo_score=$(jq -r ".results[$i].seo_score" "$SEO_FILE")
      passed=$(jq -r ".results[$i].passed" "$SEO_FILE")
      failed=$(jq -r ".results[$i].failed" "$SEO_FILE")

      add_heading2 "$domain"

      se=$(rate_emoji "$seo_score" 90 50 higher)
      add_text "$se SEO Score: ${seo_score}  |  ✅ 通过: ${passed}  |  ❌ 失败: ${failed}"

      # 失败的审计项
      fail_list=$(jq -r "[.results[$i].audits[] | select(.score == 0)] | length" "$SEO_FILE" 2>/dev/null || echo "0")
      if [ "$fail_list" -gt 0 ]; then
        add_text "❌ 未通过项:"
        j=0
        while [ "$j" -lt "$fail_list" ]; do
          title=$(jq -r "[.results[$i].audits[] | select(.score == 0)][$j].title" "$SEO_FILE")
          desc=$(jq -r "[.results[$i].audits[] | select(.score == 0)][$j].description" "$SEO_FILE")
          add_bullet "${title}"
          j=$((j + 1))
        done
      fi

      # 结构化数据检查清单
      sd=$(jq -r ".results[$i].structured_data" "$SEO_FILE")
      if [ "$sd" != "null" ] && [ "$sd" != "{}" ]; then
        checklist=""
        for key in has_meta_description has_document_title has_canonical is_crawlable images_alt link_text viewport; do
          val=$(echo "$sd" | jq -r ".${key} // false")
          label=$(echo "$key" | sed 's/_/ /g;s/has //;s/is //')
          [ "$val" = "true" ] && checklist="${checklist}✅ ${label}  " || checklist="${checklist}❌ ${label}  "
        done
        add_text "$checklist"
      fi

      # 基础检查
      basic_count=$(jq -r ".results[$i].basic_checks | length" "$SEO_FILE" 2>/dev/null || echo "0")
      if [ "$basic_count" -gt 0 ]; then
        basic_text=""
        j=0
        while [ "$j" -lt "$basic_count" ]; do
          b_name=$(jq -r ".results[$i].basic_checks[$j].name" "$SEO_FILE")
          b_status=$(jq -r ".results[$i].basic_checks[$j].status" "$SEO_FILE")
          b_detail=$(jq -r ".results[$i].basic_checks[$j].detail" "$SEO_FILE")
          icon="✅"; [ "$b_status" = "warn" ] && icon="⚠️"; [ "$b_status" = "fail" ] && icon="❌"
          basic_text="${basic_text}${icon} ${b_name}: ${b_detail}\n"
          j=$((j + 1))
        done
        add_text "$(echo -e "$basic_text")"
      fi

      i=$((i + 1))
    done
  fi
fi

# ══════════════════════════════════════════
# 🌍 地域流量分析
# ══════════════════════════════════════════
if [ -n "$GEO_FILE" ] && [ -f "$GEO_FILE" ]; then
  overview=$(jq -r '.overview // empty' "$GEO_FILE")
  if [ -n "$overview" ] && [ "$overview" != "null" ]; then
    ([ -n "$PERF_FILE" ] && [ -f "$PERF_FILE" ]) || ([ -n "$SEO_FILE" ] && [ -f "$SEO_FILE" ]) && add_divider
    add_heading1 "🌍 地域流量分析"

    period=$(jq -r '.period | "\(.start) ~ \(.end) (\(.days)天)"' "$GEO_FILE")
    total=$(jq -r '.overview.total_requests' "$GEO_FILE")
    pv=$(jq -r '.overview.page_views' "$GEO_FILE")
    uv=$(jq -r '.overview.unique_visitors' "$GEO_FILE")
    bw=$(jq -r '.overview.bandwidth_mb' "$GEO_FILE")
    cache_pct=$(jq -r '.overview.cache_ratio_pct' "$GEO_FILE")

    add_text "📅 统计周期: ${period}"
    add_text "总请求: ${total} | PV: ${pv} | UV: ${uv} | 带宽: ${bw}MB | 缓存率: ${cache_pct}%"

    # 国家分布
    add_heading2 "🗺 国家/地区分布"
    country_count=$(jq -r '.countries | length' "$GEO_FILE")
    country_text=""
    j=0
    while [ "$j" -lt "$country_count" ]; do
      c_name=$(jq -r ".countries[$j].country" "$GEO_FILE")
      c_req=$(jq -r ".countries[$j].requests" "$GEO_FILE")
      c_pct=$(jq -r ".countries[$j].pct" "$GEO_FILE")
      c_bw=$(jq -r ".countries[$j].bandwidth_mb" "$GEO_FILE")
      c_threats=$(jq -r ".countries[$j].threats" "$GEO_FILE")
      threat_mark=""
      [ "$c_threats" -gt 100 ] 2>/dev/null && threat_mark=" ⚠️${c_threats}威胁"
      country_text="${country_text}• ${c_name}: ${c_req} (${c_pct}%) ${c_bw}MB${threat_mark}\n"
      j=$((j + 1))
    done
    add_text "$(echo -e "$country_text")"

    # 浏览器分布
    add_heading2 "🌐 浏览器分布"
    browser_count=$(jq -r '.browsers | length' "$GEO_FILE")
    browser_text=""
    j=0
    while [ "$j" -lt "$browser_count" ]; do
      b_name=$(jq -r ".browsers[$j].browser" "$GEO_FILE")
      b_pv=$(jq -r ".browsers[$j].page_views" "$GEO_FILE")
      b_pct=$(jq -r ".browsers[$j].pct" "$GEO_FILE")
      browser_text="${browser_text}• ${b_name}: ${b_pv} PV (${b_pct}%)\n"
      j=$((j + 1))
    done
    add_text "$(echo -e "$browser_text")"

    # HTTP 状态码
    add_heading2 "📶 HTTP 状态码"
    status_count=$(jq -r '.status_codes | length' "$GEO_FILE")
    status_text=""
    j=0
    while [ "$j" -lt "$status_count" ]; do
      s_code=$(jq -r ".status_codes[$j].status" "$GEO_FILE")
      s_req=$(jq -r ".status_codes[$j].requests" "$GEO_FILE")
      icon="🟢"
      [ "$s_code" -ge 400 ] 2>/dev/null && icon="🟡"
      [ "$s_code" -ge 500 ] 2>/dev/null && icon="🔴"
      status_text="${status_text}${icon} ${s_code}: ${s_req}  |  "
      j=$((j + 1))
    done
    add_text "${status_text%  |  }"

    # 内容类型
    add_heading2 "📁 内容类型分布"
    ct_count=$(jq -r '.content_types | length' "$GEO_FILE")
    ct_text=""
    j=0
    while [ "$j" -lt "$ct_count" ]; do
      ct_type=$(jq -r ".content_types[$j].type" "$GEO_FILE")
      ct_req=$(jq -r ".content_types[$j].requests" "$GEO_FILE")
      ct_bw=$(jq -r ".content_types[$j].bandwidth_mb" "$GEO_FILE")
      ct_text="${ct_text}• ${ct_type}: ${ct_req} 请求, ${ct_bw}MB\n"
      j=$((j + 1))
    done
    add_text "$(echo -e "$ct_text")"
  fi
fi

# ── 尾注 ──
add_divider
add_block "$(jq -n --arg t "🤖 自动生成 · ${dt}" \
  '{children:[{block_type:2,text:{elements:[{text_run:{content:$t,text_element_style:{italic:true}}}]}}],index:-1}')"

# ── 返回文档 URL ──
if [ -n "$NODE_TOKEN" ]; then
  DOC_URL="https://${FEISHU_DOMAIN}/wiki/${NODE_TOKEN}"
else
  DOC_URL="https://${FEISHU_DOMAIN}/docx/${DOC_ID}"
fi
log "综合报告完成: $DOC_URL"
echo "$DOC_URL"
