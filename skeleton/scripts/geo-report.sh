#!/bin/bash
# GEO (Generative Engine Optimization) 审计
# 检查网站对 AI 搜索引擎（ChatGPT/Perplexity/Gemini）的可见性
# 用法: bash scripts/geo-report.sh [domain1,domain2,...] [output_dir]
# 输出: JSON 报告路径 (stdout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$PROJECT_DIR/.env" ] && { set -a; source "$PROJECT_DIR/.env"; set +a; }

DOMAINS="${1:-${SEO_CHECK_DOMAINS:-${PERF_TARGET_URLS:-}}}"
DOMAINS=$(echo "$DOMAINS" | sed -E 's|https?://||g;s|/[^ ,]*||g')
OUTPUT_DIR="${2:-$PROJECT_DIR/data/geo-reports}"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

if [ -z "$DOMAINS" ]; then
  echo "错误: 未配置目标域名" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== GEO 审计 (Generative Engine Optimization) $(date '+%Y-%m-%d %H:%M') ===" >&2

RESULTS_JSON="[]"

IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
for domain in "${DOMAIN_LIST[@]}"; do
  domain=$(echo "$domain" | tr -d '[:space:]')
  [ -z "$domain" ] && continue
  URL="https://$domain"

  echo "--- $domain ---" >&2

  # ── 获取首页 HTML（尝试 www 前缀绕 CF）──
  echo "  [抓取] 获取首页..." >&2
  HTML=$(curl -sfL -H "User-Agent: $UA" -m 15 "$URL/" 2>/dev/null || echo "")
  CF_BLOCKED="false"
  if [ ${#HTML} -lt 1000 ]; then
    # 可能被 CF challenge 挡了，尝试 www
    if [[ ! "$domain" == www.* ]]; then
      HTML=$(curl -sfL -H "User-Agent: $UA" -m 15 "https://www.${domain}/" 2>/dev/null || echo "")
    fi
    [ ${#HTML} -lt 1000 ] && CF_BLOCKED="true"
  fi
  HTML_SIZE=${#HTML}
  echo "  HTML: ${HTML_SIZE} 字节 (CF blocked: $CF_BLOCKED)" >&2

  # ══════════════════════════════════════════
  # 1. 结构化数据检查 (Schema.org JSON-LD)
  # ══════════════════════════════════════════
  echo "  [1/6] 结构化数据..." >&2
  SCHEMA_TYPES="[]"
  HAS_JSONLD="false"
  HAS_FAQ="false"
  HAS_PRODUCT="false"
  HAS_ORG="false"
  HAS_BREADCRUMB="false"
  HAS_ARTICLE="false"
  HAS_HOWTO="false"
  HAS_REVIEW="false"

  # 如果首页被 CF 挡了，尝试抓产品页/博客页分析结构化数据
  ANALYSIS_HTML="$HTML"
  if [ "$CF_BLOCKED" = "true" ]; then
    echo "  [结构化数据] 首页被 CF 阻止，尝试 sitemap 找可访问页面..." >&2
    SITEMAP_XML=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/sitemap.xml" 2>/dev/null \
      || curl -sfL -H "User-Agent: $UA" -m 10 "https://www.${domain}/sitemap.xml" 2>/dev/null || echo "")
    if [ -n "$SITEMAP_XML" ]; then
      # 找一个产品页 URL
      SAMPLE_URL=$(echo "$SITEMAP_XML" | grep -oE '<loc>[^<]*</loc>' | sed 's/<[^>]*>//g' | grep '/products/' | head -1 || true)
      [ -z "$SAMPLE_URL" ] && SAMPLE_URL=$(echo "$SITEMAP_XML" | grep -oE '<loc>[^<]*</loc>' | sed 's/<[^>]*>//g' | grep '/blogs/' | head -1 || true)
      if [ -n "$SAMPLE_URL" ]; then
        echo "  [结构化数据] 尝试: $SAMPLE_URL" >&2
        ANALYSIS_HTML=$(curl -sfL -H "User-Agent: $UA" -m 15 "$SAMPLE_URL" 2>/dev/null || echo "")
        [ ${#ANALYSIS_HTML} -gt 1000 ] && echo "  [结构化数据] 成功获取 ${#ANALYSIS_HTML} 字节" >&2
      fi
    fi
  fi

  if [ ${#ANALYSIS_HTML} -gt 1000 ]; then
    # 提取所有 JSON-LD 块中的 @type
    JSONLD_TYPES=$(echo "$ANALYSIS_HTML" | sed -n 's/.*<script[^>]*type="application\/ld+json"[^>]*>\(.*\)<\/script>.*/\1/gp' \
      | tr '\n' ' ' \
      | grep -oE '"@type"\s*:\s*"[^"]*"' \
      | sed -E 's/"@type"\s*:\s*"([^"]*)"/\1/' \
      | sort -u || true)

    if [ -n "$JSONLD_TYPES" ]; then
      HAS_JSONLD="true"
      SCHEMA_TYPES=$(echo "$JSONLD_TYPES" | jq -R -s 'split("\n") | map(select(length > 0))')
      echo "$JSONLD_TYPES" | grep -qi "faq" && HAS_FAQ="true"
      echo "$JSONLD_TYPES" | grep -qi "product" && HAS_PRODUCT="true"
      echo "$JSONLD_TYPES" | grep -qi "organization" && HAS_ORG="true"
      echo "$JSONLD_TYPES" | grep -qi "breadcrumb" && HAS_BREADCRUMB="true"
      echo "$JSONLD_TYPES" | grep -qi "article\|blogposting\|newsarticle" && HAS_ARTICLE="true"
      echo "$JSONLD_TYPES" | grep -qi "howto" && HAS_HOWTO="true"
      echo "$JSONLD_TYPES" | grep -qi "review\|aggregaterating" && HAS_REVIEW="true"
    fi
  fi
  echo "  Schema: $HAS_JSONLD types=$SCHEMA_TYPES" >&2

  # ══════════════════════════════════════════
  # 2. 内容结构分析 (AI 可提取性)
  # ══════════════════════════════════════════
  echo "  [2/6] 内容结构..." >&2
  H1_COUNT=0; H2_COUNT=0; H3_COUNT=0
  HAS_META_DESC="false"
  META_DESC_LEN=0
  HAS_LANG="false"
  HAS_OG="false"
  LIST_COUNT=0

  if [ ${#ANALYSIS_HTML} -gt 1000 ]; then
    H1_COUNT=$(echo "$ANALYSIS_HTML" | grep -coi '<h1' || true)
    H2_COUNT=$(echo "$ANALYSIS_HTML" | grep -coi '<h2' || true)
    H3_COUNT=$(echo "$ANALYSIS_HTML" | grep -coi '<h3' || true)
    LIST_COUNT=$(echo "$ANALYSIS_HTML" | grep -coi '<ul\|<ol' || true)

    META_DESC=$(echo "$ANALYSIS_HTML" | sed -n 's/.*<meta[^>]*name="description"[^>]*content="\([^"]*\)".*/\1/Ip' | head -1 || true)
    [ -n "$META_DESC" ] && { HAS_META_DESC="true"; META_DESC_LEN=${#META_DESC}; }

    echo "$ANALYSIS_HTML" | grep -qi 'lang=' && HAS_LANG="true"
    echo "$ANALYSIS_HTML" | grep -qi 'property="og:' && HAS_OG="true"
  fi

  # 语义 HTML 得分 (0-100)
  SEMANTIC_SCORE=0
  [ "$H1_COUNT" -ge 1 ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 20))
  [ "$H2_COUNT" -ge 2 ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 20))
  [ "$H3_COUNT" -ge 1 ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 10))
  [ "$LIST_COUNT" -ge 1 ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 15))
  [ "$HAS_META_DESC" = "true" ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 15))
  [ "$HAS_LANG" = "true" ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 10))
  [ "$HAS_OG" = "true" ] && SEMANTIC_SCORE=$((SEMANTIC_SCORE + 10))
  echo "  H1=$H1_COUNT H2=$H2_COUNT H3=$H3_COUNT 列表=$LIST_COUNT 语义=$SEMANTIC_SCORE" >&2

  # ══════════════════════════════════════════
  # 3. AI 爬虫可访问性 + Content-Signal
  # ══════════════════════════════════════════
  echo "  [3/6] AI 爬虫可访问性..." >&2
  ROBOTS=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/robots.txt" 2>/dev/null \
    || curl -sfL -H "User-Agent: $UA" -m 10 "https://www.${domain}/robots.txt" 2>/dev/null || echo "")
  AI_BOTS_JSON="[]"

  # 解析 Content-Signal（CF 新特性）
  CONTENT_SIGNAL_SEARCH=""
  CONTENT_SIGNAL_AI_INPUT=""
  CONTENT_SIGNAL_AI_TRAIN=""
  if [ -n "$ROBOTS" ]; then
    CS_LINE=$(echo "$ROBOTS" | grep -i 'Content-Signal:' | head -1 || true)
    if [ -n "$CS_LINE" ]; then
      CONTENT_SIGNAL_SEARCH=$(echo "$CS_LINE" | grep -oiE 'search=[a-z]+' | sed 's/search=//' || true)
      CONTENT_SIGNAL_AI_INPUT=$(echo "$CS_LINE" | grep -oiE 'ai-input=[a-z]+' | sed 's/ai-input=//' || true)
      CONTENT_SIGNAL_AI_TRAIN=$(echo "$CS_LINE" | grep -oiE 'ai-train=[a-z]+' | sed 's/ai-train=//' || true)
      echo "  Content-Signal: search=$CONTENT_SIGNAL_SEARCH ai-input=$CONTENT_SIGNAL_AI_INPUT ai-train=$CONTENT_SIGNAL_AI_TRAIN" >&2
    fi
  fi

  # 逐个检查 AI 爬虫
  for bot in GPTBot ChatGPT-User ClaudeBot PerplexityBot Google-Extended Applebot-Extended Bytespider CCBot meta-externalagent Amazonbot; do
    status="allowed"
    if [ -n "$ROBOTS" ]; then
      # 检查是否有专门的 User-agent 段 + Disallow: /
      BOT_SECTION=$(echo "$ROBOTS" | awk -v bot="$bot" '
        BEGIN { IGNORECASE=1; found=0 }
        /^[[:space:]]*User-agent:/ {
          if (found) exit
          if (index($0, bot) > 0) found=1
          next
        }
        found && /^[[:space:]]*Disallow:.*\/$/ { print "blocked"; exit }
        found && /^[[:space:]]*$/ { exit }
      ')
      [ "$BOT_SECTION" = "blocked" ] && status="blocked"
    else
      status="no_robots"
    fi
    AI_BOTS_JSON=$(echo "$AI_BOTS_JSON" | jq --arg b "$bot" --arg s "$status" '. + [{bot:$b, status:$s}]')
  done

  BLOCKED_COUNT=$(echo "$AI_BOTS_JSON" | jq '[.[] | select(.status == "blocked")] | length')
  ALLOWED_COUNT=$(echo "$AI_BOTS_JSON" | jq '[.[] | select(.status == "allowed" or .status == "no_robots")] | length')
  echo "  AI 爬虫: $ALLOWED_COUNT 允许, $BLOCKED_COUNT 阻止" >&2

  # ══════════════════════════════════════════
  # 4. E-A-T 信号 (经验/专业/权威/可信)
  # ══════════════════════════════════════════
  echo "  [4/6] E-A-T 信号..." >&2
  HAS_ABOUT="false"
  HAS_CONTACT="false"
  HAS_PRIVACY="false"
  HAS_TERMS="false"
  HAS_AUTHOR="false"
  HAS_SOCIAL="false"

  # 直接检查关键页面是否存在（不依赖首页 HTML）
  for page_path in "/pages/about" "/about" "/about-us"; do
    status_code=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "$URL$page_path" 2>/dev/null \
      || curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "https://www.${domain}${page_path}" 2>/dev/null || echo "000")
    if [ "$status_code" = "200" ]; then
      HAS_ABOUT="true"
      break
    fi
  done

  for page_path in "/pages/contact" "/contact" "/contact-us"; do
    status_code=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "$URL$page_path" 2>/dev/null \
      || curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "https://www.${domain}${page_path}" 2>/dev/null || echo "000")
    if [ "$status_code" = "200" ]; then
      HAS_CONTACT="true"
      break
    fi
  done

  # Privacy / Terms 检查（Shopify 通常在 /policies/）
  for page_path in "/policies/privacy-policy" "/privacy" "/privacy-policy"; do
    status_code=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "$URL$page_path" 2>/dev/null || echo "000")
    if [ "$status_code" = "200" ]; then
      HAS_PRIVACY="true"
      break
    fi
  done

  for page_path in "/policies/terms-of-service" "/terms" "/tos"; do
    status_code=$(curl -sfL -H "User-Agent: $UA" -o /dev/null -w "%{http_code}" -m 8 "$URL$page_path" 2>/dev/null || echo "000")
    if [ "$status_code" = "200" ]; then
      HAS_TERMS="true"
      break
    fi
  done

  # 从可用的 HTML 检查 author 和 social
  if [ ${#ANALYSIS_HTML} -gt 1000 ]; then
    echo "$ANALYSIS_HTML" | grep -qi 'rel="author"\|class="author"\|itemprop="author"' && HAS_AUTHOR="true"
    echo "$ANALYSIS_HTML" | grep -qi 'twitter.com\|facebook.com\|instagram.com\|linkedin.com\|youtube.com' && HAS_SOCIAL="true"
  fi

  # About 页深度（如果可访问）
  ABOUT_DEPTH="none"
  if [ "$HAS_ABOUT" = "true" ]; then
    ABOUT_HTML=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/pages/about" 2>/dev/null \
      || curl -sfL -H "User-Agent: $UA" -m 10 "https://www.${domain}/pages/about" 2>/dev/null || echo "")
    ABOUT_LEN=${#ABOUT_HTML}
    [ "$ABOUT_LEN" -gt 10000 ] && ABOUT_DEPTH="detailed"
    [ "$ABOUT_LEN" -gt 3000 ] && [ "$ABOUT_LEN" -le 10000 ] && ABOUT_DEPTH="moderate"
    [ "$ABOUT_LEN" -gt 0 ] && [ "$ABOUT_LEN" -le 3000 ] && ABOUT_DEPTH="minimal"
  fi

  EAT_SCORE=0
  [ "$HAS_ABOUT" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  [ "$ABOUT_DEPTH" = "detailed" ] && EAT_SCORE=$((EAT_SCORE + 10))
  [ "$ABOUT_DEPTH" = "moderate" ] && EAT_SCORE=$((EAT_SCORE + 5))
  [ "$HAS_CONTACT" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  [ "$HAS_PRIVACY" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  [ "$HAS_TERMS" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  [ "$HAS_AUTHOR" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  [ "$HAS_SOCIAL" = "true" ] && EAT_SCORE=$((EAT_SCORE + 15))
  echo "  E-A-T=$EAT_SCORE (about=$HAS_ABOUT/$ABOUT_DEPTH contact=$HAS_CONTACT)" >&2

  # ══════════════════════════════════════════
  # 5. 内容新鲜度信号
  # ══════════════════════════════════════════
  echo "  [5/6] 内容新鲜度..." >&2
  HAS_LASTMOD="false"
  HAS_PUBLISH_DATE="false"
  LATEST_MOD=""

  if [ ${#ANALYSIS_HTML} -gt 1000 ]; then
    echo "$ANALYSIS_HTML" | grep -qi 'dateModified\|datePublished\|article:modified_time\|article:published_time' && HAS_PUBLISH_DATE="true"
  fi

  # 检查 sitemap 的 lastmod
  SITEMAP_FRESH="unknown"
  [ -z "${SITEMAP_XML:-}" ] && SITEMAP_XML=$(curl -sfL -H "User-Agent: $UA" -m 10 "$URL/sitemap.xml" 2>/dev/null \
    || curl -sfL -H "User-Agent: $UA" -m 10 "https://www.${domain}/sitemap.xml" 2>/dev/null || echo "")
  SITEMAP_URL_COUNT=0
  if [ -n "$SITEMAP_XML" ]; then
    SITEMAP_URL_COUNT=$(echo "$SITEMAP_XML" | grep -c '<loc>' 2>/dev/null || echo "0")
    LATEST_MOD=$(echo "$SITEMAP_XML" | grep -oE '<lastmod>[^<]+</lastmod>' | sed 's/<[^>]*>//g' | sort -r | head -1 || true)
    if [ -n "$LATEST_MOD" ]; then
      HAS_LASTMOD="true"
      MOD_DATE=$(echo "$LATEST_MOD" | cut -c1-10)
      THIRTY_AGO=$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || echo "")
      if [ -n "$THIRTY_AGO" ] && [ "$MOD_DATE" '>' "$THIRTY_AGO" ] 2>/dev/null; then
        SITEMAP_FRESH="recent"
      else
        SITEMAP_FRESH="stale"
      fi
    fi
  fi

  FRESHNESS_SCORE=0
  [ "$HAS_PUBLISH_DATE" = "true" ] && FRESHNESS_SCORE=$((FRESHNESS_SCORE + 30))
  [ "$HAS_LASTMOD" = "true" ] && FRESHNESS_SCORE=$((FRESHNESS_SCORE + 25))
  [ "$SITEMAP_FRESH" = "recent" ] && FRESHNESS_SCORE=$((FRESHNESS_SCORE + 25))
  [ "$SITEMAP_URL_COUNT" -gt 50 ] 2>/dev/null && FRESHNESS_SCORE=$((FRESHNESS_SCORE + 20))
  echo "  新鲜度=$FRESHNESS_SCORE sitemap=$SITEMAP_FRESH urls=$SITEMAP_URL_COUNT lastmod=$LATEST_MOD" >&2

  # ══════════════════════════════════════════
  # 6. AI 引用状态说明
  # ══════════════════════════════════════════
  echo "  [6/6] AI 可见性评估..." >&2
  AI_CITATION="unchecked"
  # 完整追踪需要 Perplexity API / Otterly.AI 等付费服务
  # 此处基于 robots.txt 和 Content-Signal 推断可见性风险

  AI_VISIBILITY_RISK="low"
  # 如果大多数 AI 爬虫被阻止 + ai-train=no → AI 引用风险高
  if [ "$BLOCKED_COUNT" -ge 5 ]; then
    AI_VISIBILITY_RISK="high"
  elif [ "$BLOCKED_COUNT" -ge 3 ]; then
    AI_VISIBILITY_RISK="medium"
  fi
  echo "  AI 可见性风险: $AI_VISIBILITY_RISK" >&2

  # ══════════════════════════════════════════
  # 综合评分
  # ══════════════════════════════════════════

  # 结构化数据得分 (0-100)
  SCHEMA_SCORE=0
  [ "$HAS_JSONLD" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 30))
  [ "$HAS_PRODUCT" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 20))
  [ "$HAS_FAQ" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 15))
  [ "$HAS_ORG" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 10))
  [ "$HAS_BREADCRUMB" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 10))
  [ "$HAS_REVIEW" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 10))
  [ "$HAS_ARTICLE" = "true" ] && SCHEMA_SCORE=$((SCHEMA_SCORE + 5))

  # AI 可访问性得分 (0-100)
  CRAWL_SCORE=0
  TOTAL_BOTS=$(echo "$AI_BOTS_JSON" | jq 'length')
  if [ "$TOTAL_BOTS" -gt 0 ]; then
    CRAWL_SCORE=$((ALLOWED_COUNT * 100 / TOTAL_BOTS))
  fi

  # GEO 综合分 (加权平均)
  GEO_SCORE=$(( (SCHEMA_SCORE * 25 + SEMANTIC_SCORE * 20 + CRAWL_SCORE * 20 + EAT_SCORE * 20 + FRESHNESS_SCORE * 15) / 100 ))

  DOMAIN_STATUS="ok"
  [ "$GEO_SCORE" -lt 60 ] && DOMAIN_STATUS="warn"
  [ "$GEO_SCORE" -lt 40 ] && DOMAIN_STATUS="error"

  echo "  → GEO=$GEO_SCORE (Schema=$SCHEMA_SCORE 语义=$SEMANTIC_SCORE 爬虫=$CRAWL_SCORE E-A-T=$EAT_SCORE 新鲜=$FRESHNESS_SCORE)" >&2

  # 构建结果 JSON
  RESULT=$(jq -n \
    --arg domain "$domain" \
    --arg status "$DOMAIN_STATUS" \
    --argjson geo_score "$GEO_SCORE" \
    --argjson schema_score "$SCHEMA_SCORE" \
    --argjson semantic_score "$SEMANTIC_SCORE" \
    --argjson crawl_score "$CRAWL_SCORE" \
    --argjson eat_score "$EAT_SCORE" \
    --argjson freshness_score "$FRESHNESS_SCORE" \
    --argjson schema_types "$SCHEMA_TYPES" \
    --argjson has_jsonld "$HAS_JSONLD" \
    --argjson has_faq "$HAS_FAQ" \
    --argjson has_product "$HAS_PRODUCT" \
    --argjson has_org "$HAS_ORG" \
    --argjson has_breadcrumb "$HAS_BREADCRUMB" \
    --argjson has_review "$HAS_REVIEW" \
    --argjson has_article "$HAS_ARTICLE" \
    --argjson h1 "$H1_COUNT" \
    --argjson h2 "$H2_COUNT" \
    --argjson h3 "$H3_COUNT" \
    --argjson lists "$LIST_COUNT" \
    --argjson has_meta_desc "$HAS_META_DESC" \
    --argjson meta_desc_len "$META_DESC_LEN" \
    --argjson cf_blocked "$CF_BLOCKED" \
    --arg content_signal_search "${CONTENT_SIGNAL_SEARCH:-}" \
    --arg content_signal_ai_input "${CONTENT_SIGNAL_AI_INPUT:-}" \
    --arg content_signal_ai_train "${CONTENT_SIGNAL_AI_TRAIN:-}" \
    --argjson ai_bots "$AI_BOTS_JSON" \
    --argjson blocked_bots "$BLOCKED_COUNT" \
    --argjson has_about "$HAS_ABOUT" \
    --argjson has_contact "$HAS_CONTACT" \
    --argjson has_privacy "$HAS_PRIVACY" \
    --argjson has_terms "$HAS_TERMS" \
    --argjson has_author "$HAS_AUTHOR" \
    --argjson has_social "$HAS_SOCIAL" \
    --arg about_depth "$ABOUT_DEPTH" \
    --argjson has_publish_date "$HAS_PUBLISH_DATE" \
    --argjson has_lastmod "$HAS_LASTMOD" \
    --arg latest_mod "${LATEST_MOD:-}" \
    --arg sitemap_fresh "$SITEMAP_FRESH" \
    --argjson sitemap_urls "$SITEMAP_URL_COUNT" \
    --arg ai_citation "$AI_CITATION" \
    --arg ai_visibility_risk "$AI_VISIBILITY_RISK" \
    '{
      domain: $domain,
      status: $status,
      geo_score: $geo_score,
      scores: {
        schema: $schema_score,
        semantic: $semantic_score,
        crawlability: $crawl_score,
        eat: $eat_score,
        freshness: $freshness_score
      },
      structured_data: {
        has_jsonld: $has_jsonld,
        types: $schema_types,
        has_faq: $has_faq,
        has_product: $has_product,
        has_organization: $has_org,
        has_breadcrumb: $has_breadcrumb,
        has_review: $has_review,
        has_article: $has_article
      },
      content_structure: {
        h1: $h1, h2: $h2, h3: $h3,
        lists: $lists,
        has_meta_description: $has_meta_desc,
        meta_description_length: $meta_desc_len,
        cf_blocked: $cf_blocked
      },
      content_signal: {
        search: $content_signal_search,
        ai_input: $content_signal_ai_input,
        ai_train: $content_signal_ai_train
      },
      ai_crawlers: {
        bots: $ai_bots,
        blocked_count: $blocked_bots
      },
      eat_signals: {
        about_page: $has_about,
        about_depth: $about_depth,
        contact_page: $has_contact,
        privacy_policy: $has_privacy,
        terms_of_service: $has_terms,
        author_attribution: $has_author,
        social_profiles: $has_social
      },
      freshness: {
        has_publish_date: $has_publish_date,
        has_lastmod: $has_lastmod,
        latest_mod: $latest_mod,
        sitemap_freshness: $sitemap_fresh,
        sitemap_url_count: $sitemap_urls
      },
      ai_visibility: {
        citation_status: $ai_citation,
        visibility_risk: $ai_visibility_risk
      }
    }')

  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson r "$RESULT" '. + [$r]')
done

echo "=== GEO 审计完成 ===" >&2

REPORT_FILE="$OUTPUT_DIR/geo-audit-${TIMESTAMP}.json"
jq -n --arg ts "$TIMESTAMP" --argjson results "$RESULTS_JSON" \
  '{timestamp:$ts, type:"geo_audit", results:$results}' > "$REPORT_FILE"

echo "$REPORT_FILE"
