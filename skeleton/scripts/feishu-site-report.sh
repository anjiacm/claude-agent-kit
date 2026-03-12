#!/usr/bin/env bash
# 创建飞书综合站点报告（性能 + SEO + GEO + 流量，写入 Wiki 知识库）
# 用法: bash scripts/feishu-site-report.sh <perf.json> <seo.json> <geo.json> <traffic.json> <token>
# 任何报告文件可传 "" 跳过

set -euo pipefail

PERF_FILE="${1:-}"
SEO_FILE="${2:-}"
GEO_FILE="${3:-}"
TRAFFIC_FILE="${4:-}"
TOKEN="${5:-}"
FEISHU_DOMAIN="${FEISHU_DOMAIN:-hengjunhome.feishu.cn}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$PROJECT_DIR/data/cf-reports/daemon.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] site-report: $*" >> "$LOG_FILE" 2>/dev/null || true; }

# 至少需要一个报告
[ -z "$PERF_FILE" ] && [ -z "$SEO_FILE" ] && [ -z "$GEO_FILE" ] && [ -z "$TRAFFIC_FILE" ] && { echo ""; exit 0; }

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
# 🤖 GEO 审计 (AI 搜索引擎优化)
# ══════════════════════════════════════════
if [ -n "$GEO_FILE" ] && [ -f "$GEO_FILE" ]; then
  geo_count=$(jq -r '.results | length' "$GEO_FILE" 2>/dev/null || echo "0")
  if [ "$geo_count" -gt 0 ]; then
    ([ -n "$PERF_FILE" ] && [ -f "$PERF_FILE" ]) || ([ -n "$SEO_FILE" ] && [ -f "$SEO_FILE" ]) && add_divider
    add_heading1 "🤖 GEO 审计 (AI 搜索引擎优化)"

    i=0
    while [ "$i" -lt "$geo_count" ]; do
      domain=$(jq -r ".results[$i].domain" "$GEO_FILE")
      geo_score=$(jq -r ".results[$i].geo_score" "$GEO_FILE")
      schema_s=$(jq -r ".results[$i].scores.schema" "$GEO_FILE")
      semantic_s=$(jq -r ".results[$i].scores.semantic" "$GEO_FILE")
      crawl_s=$(jq -r ".results[$i].scores.crawlability" "$GEO_FILE")
      eat_s=$(jq -r ".results[$i].scores.eat" "$GEO_FILE")
      fresh_s=$(jq -r ".results[$i].scores.freshness" "$GEO_FILE")

      add_heading2 "$domain"

      ge=$(rate_emoji "$geo_score" 70 40 higher)
      risk=$(jq -r ".results[$i].ai_visibility.visibility_risk" "$GEO_FILE")
      risk_icon="🟢"; [ "$risk" = "medium" ] && risk_icon="🟡"; [ "$risk" = "high" ] && risk_icon="🔴"
      add_text "$ge GEO 综合分: ${geo_score}/100  |  ${risk_icon} AI 可见性风险: ${risk}"
      add_text "结构化数据: ${schema_s} | 语义结构: ${semantic_s} | AI 爬虫: ${crawl_s} | E-A-T: ${eat_s} | 新鲜度: ${fresh_s}"

      # CF 阻止提示
      cf_blocked=$(jq -r ".results[$i].content_structure.cf_blocked" "$GEO_FILE")
      [ "$cf_blocked" = "true" ] && add_bullet "⚠️ CF Managed Challenge 阻止了 HTML 分析，以下结果仅基于 robots.txt 和外部可访问数据"

      # Content-Signal（CF 新特性）
      cs_search=$(jq -r ".results[$i].content_signal.search // empty" "$GEO_FILE")
      cs_ai_input=$(jq -r ".results[$i].content_signal.ai_input // empty" "$GEO_FILE")
      cs_ai_train=$(jq -r ".results[$i].content_signal.ai_train // empty" "$GEO_FILE")
      if [ -n "$cs_search" ] || [ -n "$cs_ai_input" ] || [ -n "$cs_ai_train" ]; then
        cs_text="Content-Signal:"
        [ -n "$cs_search" ] && cs_text="${cs_text} search=${cs_search}"
        [ -n "$cs_ai_input" ] && cs_text="${cs_text} ai-input=${cs_ai_input}"
        [ -n "$cs_ai_train" ] && cs_text="${cs_text} ai-train=${cs_ai_train}"
        add_code "$cs_text"
      fi

      # 结构化数据详情
      add_heading2 "Schema.org 结构化数据"
      types=$(jq -r '[.results['"$i"'].structured_data.types[] // empty] | join(", ")' "$GEO_FILE" 2>/dev/null || echo "")
      has_jsonld=$(jq -r ".results[$i].structured_data.has_jsonld" "$GEO_FILE")
      if [ "$has_jsonld" = "true" ]; then
        add_text "✅ JSON-LD: ${types}"
      else
        add_text "❌ 未检测到 JSON-LD 结构化数据"
      fi

      sd_checks=""
      for key in has_product has_faq has_organization has_breadcrumb has_review; do
        val=$(jq -r ".results[$i].structured_data.${key}" "$GEO_FILE")
        label=$(echo "$key" | sed 's/has_//;s/_/ /g')
        [ "$val" = "true" ] && sd_checks="${sd_checks}✅ ${label}  " || sd_checks="${sd_checks}❌ ${label}  "
      done
      add_text "$sd_checks"

      # AI 爬虫可访问性
      add_heading2 "AI 爬虫可访问性"
      blocked=$(jq -r ".results[$i].ai_crawlers.blocked_count" "$GEO_FILE")
      bot_text=""
      bot_count=$(jq -r ".results[$i].ai_crawlers.bots | length" "$GEO_FILE")
      j=0
      while [ "$j" -lt "$bot_count" ]; do
        b_name=$(jq -r ".results[$i].ai_crawlers.bots[$j].bot" "$GEO_FILE")
        b_status=$(jq -r ".results[$i].ai_crawlers.bots[$j].status" "$GEO_FILE")
        icon="✅"
        [ "$b_status" = "blocked" ] && icon="🚫"
        [ "$b_status" = "default_blocked" ] && icon="⚠️"
        bot_text="${bot_text}${icon} ${b_name}  "
        j=$((j + 1))
      done
      add_text "$bot_text"
      [ "$blocked" -gt 0 ] && add_bullet "⚠️ ${blocked} 个 AI 爬虫被 robots.txt 阻止"

      # E-A-T 信号
      add_heading2 "E-A-T 信号"
      eat_checks=""
      for key in about_page contact_page privacy_policy terms_of_service author_attribution social_profiles; do
        val=$(jq -r ".results[$i].eat_signals.${key}" "$GEO_FILE")
        label=$(echo "$key" | sed 's/_/ /g')
        [ "$val" = "true" ] && eat_checks="${eat_checks}✅ ${label}\n" || eat_checks="${eat_checks}❌ ${label}\n"
      done
      add_text "$(echo -e "$eat_checks")"

      # 内容结构
      h1=$(jq -r ".results[$i].content_structure.h1" "$GEO_FILE")
      h2=$(jq -r ".results[$i].content_structure.h2" "$GEO_FILE")
      h3=$(jq -r ".results[$i].content_structure.h3" "$GEO_FILE")
      lists=$(jq -r ".results[$i].content_structure.lists" "$GEO_FILE")
      add_text "标题层级: H1=${h1} H2=${h2} H3=${h3} | 列表: ${lists}"

      # 新鲜度
      sitemap_fresh=$(jq -r ".results[$i].freshness.sitemap_freshness" "$GEO_FILE")
      sitemap_urls=$(jq -r ".results[$i].freshness.sitemap_url_count" "$GEO_FILE")
      latest_mod=$(jq -r ".results[$i].freshness.latest_mod // empty" "$GEO_FILE")
      fresh_icon="🟢"; [ "$sitemap_fresh" = "stale" ] && fresh_icon="🔴"; [ "$sitemap_fresh" = "unknown" ] && fresh_icon="⚠️"
      fresh_text="${fresh_icon} Sitemap: ${sitemap_fresh} (${sitemap_urls} URLs)"
      [ -n "$latest_mod" ] && fresh_text="${fresh_text} 最近更新: ${latest_mod}"
      add_text "$fresh_text"

      i=$((i + 1))
      [ "$i" -lt "$geo_count" ] && add_divider
    done
  fi
fi

# ══════════════════════════════════════════
# 📈 流量概览
# ══════════════════════════════════════════
if [ -n "$TRAFFIC_FILE" ] && [ -f "$TRAFFIC_FILE" ]; then
  overview=$(jq -r '.overview // empty' "$TRAFFIC_FILE")
  if [ -n "$overview" ] && [ "$overview" != "null" ]; then
    add_divider
    add_heading1 "📈 流量概览"

    period=$(jq -r '.period | "\(.start) ~ \(.end) (\(.days)天)"' "$TRAFFIC_FILE")
    total=$(jq -r '.overview.total_requests' "$TRAFFIC_FILE")
    pv=$(jq -r '.overview.page_views' "$TRAFFIC_FILE")
    uv=$(jq -r '.overview.unique_visitors' "$TRAFFIC_FILE")
    bw=$(jq -r '.overview.bandwidth_mb' "$TRAFFIC_FILE")
    cache_pct=$(jq -r '.overview.cache_ratio_pct' "$TRAFFIC_FILE")

    add_text "📅 ${period}"
    add_text "请求: ${total} | PV: ${pv} | UV: ${uv} | 带宽: ${bw}MB | 缓存: ${cache_pct}%"

    # Top 5 国家
    add_heading2 "🗺 Top 国家"
    country_text=""
    j=0
    while [ "$j" -lt 5 ]; do
      c_name=$(jq -r ".countries[$j].country // empty" "$TRAFFIC_FILE")
      [ -z "$c_name" ] && break
      c_req=$(jq -r ".countries[$j].requests" "$TRAFFIC_FILE")
      c_pct=$(jq -r ".countries[$j].pct" "$TRAFFIC_FILE")
      c_threats=$(jq -r ".countries[$j].threats" "$TRAFFIC_FILE")
      threat_mark=""
      [ "$c_threats" -gt 100 ] 2>/dev/null && threat_mark=" ⚠️"
      country_text="${country_text}• ${c_name}: ${c_req} (${c_pct}%)${threat_mark}\n"
      j=$((j + 1))
    done
    add_text "$(echo -e "$country_text")"

    # HTTP 状态码（精简）
    status_count=$(jq -r '.status_codes | length' "$TRAFFIC_FILE")
    status_text=""
    j=0
    while [ "$j" -lt "$status_count" ]; do
      s_code=$(jq -r ".status_codes[$j].status" "$TRAFFIC_FILE")
      s_req=$(jq -r ".status_codes[$j].requests" "$TRAFFIC_FILE")
      icon="🟢"
      [ "$s_code" -ge 400 ] 2>/dev/null && icon="🟡"
      [ "$s_code" -ge 500 ] 2>/dev/null && icon="🔴"
      status_text="${status_text}${icon} ${s_code}: ${s_req}  "
      j=$((j + 1))
    done
    [ -n "$status_text" ] && add_text "$status_text"
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
