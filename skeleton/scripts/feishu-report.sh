#!/usr/bin/env bash
# 飞书多维表格汇报工具
# 用法：
#   feishu-report.sh cf <report_file>
#   feishu-report.sh health <alias> <cpu%> <mem%> <disk%> <status> [note]
#   feishu-report.sh waf <zone> <rule_name> <type:新增|修改|删除> <reason>
#   feishu-report.sh deploy <alias> <project> <success|fail> [message]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
LOG_FILE="$PROJECT_DIR/data/cf-reports/daemon.log"

# 加载 .env
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] feishu: $*" >> "$LOG_FILE" 2>/dev/null || true; }

# 检查必要变量
if [ -z "${FEISHU_APP_ID:-}" ] || [ -z "${FEISHU_APP_SECRET:-}" ]; then
  log "FEISHU_APP_ID / FEISHU_APP_SECRET 未配置，跳过"
  exit 0
fi

# ── 获取飞书 access token ──────────────────────────────────────────────────
get_token() {
  local resp
  resp=$(curl -sf -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}" 2>/dev/null) || {
    log "获取 token 失败"
    exit 0
  }
  echo "$resp" | jq -r '.tenant_access_token // empty'
}

# ── 插入 Bitable 行 ───────────────────────────────────────────────────────
insert_record() {
  local token="$1" table_id="$2" fields_json="$3"
  local app_token="${FEISHU_BITABLE_APP_TOKEN:-}"
  if [ -z "$app_token" ] || [ -z "$table_id" ]; then
    log "Bitable APP_TOKEN 或 TABLE_ID 未配置，跳过"
    return 0
  fi
  local result
  result=$(curl -sf -X POST \
    "https://open.feishu.cn/open-apis/bitable/v1/apps/$app_token/tables/$table_id/records" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"fields\": $fields_json}" 2>/dev/null) || { log "插入记录失败"; return 0; }
  local code
  code=$(echo "$result" | jq -r '.code // -1')
  [ "$code" = "0" ] && log "Bitable 记录插入成功 (table: $table_id)" || log "Bitable 插入异常: $result"
}

# ── 带重试的 curl 封装 ─────────────────────────────────────────────────────
# 用法：curl_retry <max_retries> <curl_args...>
# 返回：curl 的输出（stdout），失败返回空
curl_retry() {
  local max_retries="$1"; shift
  local attempt=0 result
  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    result=$(curl "$@" 2>/dev/null) && { echo "$result"; return 0; }
    [ "$attempt" -lt "$max_retries" ] && { log "curl 失败，${attempt}/${max_retries} 次重试..."; sleep 2; }
  done
  log "curl 重试 ${max_retries} 次均失败"
  return 1
}

# ── 创建飞书云文档并写入内容 ──────────────────────────────────────────────
# 用法：create_learning_doc <token> <report_file>
# 返回：文档 URL（stdout），失败返回空
create_learning_doc() {
  local token="$1" report_file="$2"
  local wiki_space="${FEISHU_WIKI_SPACE_ID:-}"
  local folder="${FEISHU_LEARNING_FOLDER_TOKEN:-}"

  # 优先使用 Wiki 知识库，fallback 到普通文件夹
  if [ -z "$wiki_space" ] && [ -z "$folder" ]; then
    log "FEISHU_WIKI_SPACE_ID 和 FEISHU_LEARNING_FOLDER_TOKEN 均未配置，跳过文档创建"
    return 1
  fi

  # 获取 user_access_token（Wiki API 需要）
  local user_token=""
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ -n "$wiki_space" ] && [ -f "$script_dir/../plugins/feishu-auth/get-token.sh" ]; then
    user_token=$(bash "$script_dir/../plugins/feishu-auth/get-token.sh" 2>/dev/null) || true
  fi

  # 解析报告
  local topic reason impact sources_text
  topic=$(jq -r '.topic // "未知课题"' "$report_file")
  reason=$(jq -r '.reason // ""' "$report_file")
  impact=$(jq -r '.impact // ""' "$report_file")
  sources_text=$(jq -r '.sources // [] | join("\n")' "$report_file")
  local now_bj
  now_bj=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')

  # 1. 创建文档（Wiki 优先，fallback 到普通文档）
  local create_resp doc_id
  local date_str
  date_str=$(TZ='Asia/Shanghai' date '+%Y-%m-%d')
  local doc_title="📚 ${date_str} | $topic"

  if [ -n "$wiki_space" ] && [ -n "$user_token" ]; then
    # Wiki 知识库模式：创建知识空间节点
    local wiki_body
    wiki_body=$(jq -n --arg title "$doc_title" '{"obj_type":"docx","node_type":"origin","title":$title}')
    create_resp=$(curl_retry 3 -sf -X POST \
      "https://open.feishu.cn/open-apis/wiki/v2/spaces/${wiki_space}/nodes" \
      -H "Authorization: Bearer $user_token" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d "$wiki_body") || { log "Wiki 节点创建失败，尝试普通文档"; wiki_space=""; }
    if [ -n "$wiki_space" ]; then
      doc_id=$(echo "$create_resp" | jq -r '.data.node.obj_token // empty')
      [ -z "$doc_id" ] && { log "Wiki 节点返回异常: $create_resp"; wiki_space=""; }
    fi
  fi

  # Fallback: 普通文件夹文档
  if [ -z "$doc_id" ] && [ -n "$folder" ]; then
    local create_body
    create_body=$(jq -n --arg title "$doc_title" --arg folder "$folder" \
      '{"title":$title,"folder_token":$folder}')
    create_resp=$(curl_retry 3 -sf -X POST \
      "https://open.feishu.cn/open-apis/docx/v1/documents" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$create_body") || { log "创建文档失败"; return 1; }
    doc_id=$(echo "$create_resp" | jq -r '.data.document.document_id // empty')
  fi

  [ -z "$doc_id" ] && { log "创建文档返回异常: $create_resp"; return 1; }
  log "文档已创建: $doc_id (wiki=${wiki_space:+yes})"

  # 2. 构建内容块
  local learnings_json blocks
  learnings_json=$(jq -r '.learnings // []' "$report_file")

  # 构建 blocks 数组：来源 → 要点（bullets）→ 影响 → 参考资料
  blocks=$(jq -n \
    --arg reason "$reason" \
    --arg impact "$impact" \
    --arg sources "$sources_text" \
    --arg time "$now_bj" \
    --argjson learnings "$learnings_json" \
    '
    # 辅助函数：构建文本元素
    def text_el($t): {text_run:{content:$t}};
    def bold_el($t): {text_run:{content:$t, text_element_style:{bold:true}}};

    # 标题: 学习来源
    [{block_type:4, heading2:{elements:[text_el("学习来源")]}}] +

    # 段落: reason
    [{block_type:2, text:{elements:[text_el($reason)]}}] +

    # 分割线
    [{block_type:22, divider:{}}] +

    # 标题: 学到了什么
    [{block_type:4, heading2:{elements:[text_el("学到了什么")]}}] +

    # Bullet 列表
    [$learnings[] | {block_type:12, bullet:{elements:[text_el(.)]}}] +

    # 分割线
    [{block_type:22, divider:{}}] +

    # 标题: 未来影响
    [{block_type:4, heading2:{elements:[text_el("未来影响")]}}] +
    [{block_type:2, text:{elements:[text_el($impact)]}}] +

    # 分割线 + 参考资料
    (if ($sources | length) > 0 then
      [{block_type:22, divider:{}}] +
      [{block_type:4, heading2:{elements:[text_el("参考资料")]}}] +
      [$sources | split("\n")[] | select(length > 0) | {block_type:12, bullet:{elements:[text_el(.)]}}]
    else [] end) +

    # 尾注
    [{block_type:22, divider:{}}] +
    [{block_type:2, text:{elements:[{text_run:{content:("🤖 自主学习 · " + $time), text_element_style:{italic:true}}}]}}]
    ')

  # 3. 写入内容块（Wiki 节点用 user_token，普通文档用 tenant token）
  local write_token="${user_token:-$token}"
  local write_body write_resp
  write_body=$(jq -n --argjson children "$blocks" '{"children":$children}')
  write_resp=$(curl_retry 3 -sf -X POST \
    "https://open.feishu.cn/open-apis/docx/v1/documents/${doc_id}/blocks/${doc_id}/children" \
    -H "Authorization: Bearer $write_token" \
    -H "Content-Type: application/json" \
    -d "$write_body") || { log "写入文档内容失败（文档已创建: $doc_id）"; }

  local write_code
  write_code=$(echo "$write_resp" | jq -r '.code // -1' 2>/dev/null)
  [ "$write_code" = "0" ] && log "文档内容写入成功" || log "文档内容写入异常: $write_resp"

  # 返回文档 URL
  local domain="${FEISHU_DOMAIN:-hengjunhome.feishu.cn}"
  if [ -n "$wiki_space" ] && [ -n "$user_token" ]; then
    # Wiki 文档 URL
    local node_token
    node_token=$(echo "$create_resp" | jq -r '.data.node.node_token // empty')
    echo "https://${domain}/wiki/${node_token}"
  else
    echo "https://${domain}/docx/${doc_id}"
  fi
}

# ── 直接给配置用户发 IM 消息卡片 ─────────────────────────────────────────
# 用法：send_im_direct <token> <card_json_compact>
# FEISHU_NOTIFY_USER_IDS: 逗号分隔的 open_id 列表（.env 配置）
send_im_direct() {
  local token="$1" card_json="$2"
  local uids="${FEISHU_NOTIFY_USER_IDS:-${FEISHU_NOTIFY_USER_ID:-}}"
  [ -z "$uids" ] && return 0

  local body uid
  IFS=',' read -ra uid_arr <<< "$uids"
  for uid in "${uid_arr[@]}"; do
    uid="${uid// /}"
    [ -z "$uid" ] && continue
    body=$(jq -n --arg uid "$uid" --arg card "$card_json" \
      '{"receive_id":$uid,"msg_type":"interactive","content":$card}')
    local result
    result=$(curl -sf -X POST \
      "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body" 2>/dev/null) || { log "IM 发送失败 ($uid)"; continue; }
    local code
    code=$(echo "$result" | jq -r '.code // -1')
    [ "$code" = "0" ] && log "IM 消息已发送 ($uid)" || log "IM 发送异常 ($uid): $result"
  done
}

# ── 发群消息卡片（警告时触发）─────────────────────────────────────────────
send_webhook_card() {
  local title="$1" content="$2" color="$3"
  local webhook="${FEISHU_WEBHOOK_URL:-}"
  [ -z "$webhook" ] && return 0
  local card
  card=$(jq -n \
    --arg title "$title" \
    --arg content "$content" \
    --arg color "$color" \
    '{
      msg_type: "interactive",
      card: {
        config: {wide_screen_mode: true},
        header: {
          template: $color,
          title: {tag: "plain_text", content: $title}
        },
        elements: [{
          tag: "div",
          text: {tag: "lark_md", content: $content}
        }]
      }
    }')
  curl -sf -X POST "$webhook" -H "Content-Type: application/json" -d "$card" > /dev/null 2>&1 \
    && log "群消息发送成功" || log "群消息发送失败"
}

# ── 子命令：cf ────────────────────────────────────────────────────────────
cmd_cf() {
  local report_file="$1"
  [ ! -f "$report_file" ] && { log "报告文件不存在: $report_file"; exit 0; }

  # 解析摘要行（兼容 macOS grep，不用 -P）
  local cart checkout blocks anomalies gaps zone timestamp
  cart=$(grep 'Cart 总流量:' "$report_file" 2>/dev/null | sed 's/.*Cart 总流量: \([0-9]*\).*/\1/' | head -1 | tr -d '[:space:]' || true)
  cart="${cart:-0}"; [[ "$cart" =~ ^[0-9]+$ ]] || cart=0
  checkout=$(grep 'Checkout 总流量:' "$report_file" 2>/dev/null | sed 's/.*Checkout 总流量: \([0-9]*\).*/\1/' | head -1 | tr -d '[:space:]' || true)
  checkout="${checkout:-0}"; [[ "$checkout" =~ ^[0-9]+$ ]] || checkout=0
  blocks=$(grep '防火墙拦截:' "$report_file" 2>/dev/null | sed 's/.*防火墙拦截: \([0-9]*\).*/\1/' | head -1 | tr -d '[:space:]' || true)
  blocks="${blocks:-0}"; [[ "$blocks" =~ ^[0-9]+$ ]] || blocks=0
  anomalies=$(grep '高频异常 IP:' "$report_file" 2>/dev/null | sed 's/.*高频异常 IP: \([0-9]*\).*/\1/' | head -1 | tr -d '[:space:]' || true)
  anomalies="${anomalies:-0}"; [[ "$anomalies" =~ ^[0-9]+$ ]] || anomalies=0
  gaps=$(grep -c '^GAP ' "$report_file" 2>/dev/null | tr -d '[:space:]' || true)
  gaps="${gaps:-0}"; [[ "$gaps" =~ ^[0-9]+$ ]] || gaps=0
  zone="${CF_ZONE_LABEL:-nouhaus.com}"
  timestamp=$(basename "$report_file" | sed 's/.*cf-report-\([0-9]*-[0-9]*\).*/\1/' | head -1)
  local datetime="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2}"

  # 转换为北京时间（UTC+8）
  local epoch_local bj_datetime
  epoch_local=$(date -j -f "%Y-%m-%d %H:%M:%S" "$datetime" "+%s" 2>/dev/null || date +%s)
  bj_datetime=$(TZ='Asia/Shanghai' date -j -f "%s" "$epoch_local" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$datetime")

  # ── 新增字段解析 ────────────────────────────────────────────────────────
  # 总请求量（Cart 总请求 + Checkout 总请求，来自报告详情段）
  local total_cart total_checkout total_req
  total_cart=$(grep 'Cart 总请求:' "$report_file" 2>/dev/null | sed 's/.*Cart 总请求: \([0-9]*\).*/\1/' | head -1 || true)
  total_cart="${total_cart:-0}"; [[ "$total_cart" =~ ^[0-9]+$ ]] || total_cart=0
  total_checkout=$(grep 'Checkout 总请求:' "$report_file" 2>/dev/null | sed 's/.*Checkout 总请求: \([0-9]*\).*/\1/' | head -1 || true)
  total_checkout="${total_checkout:-0}"; [[ "$total_checkout" =~ ^[0-9]+$ ]] || total_checkout=0
  total_req=$(( total_cart + total_checkout ))

  # TOP异常IP（前3个规则缺口 IP，格式：IP (N次)，换行分隔）
  local top_ips
  top_ips=$(grep '^GAP ' "$report_file" 2>/dev/null | head -3 \
    | sed 's/GAP [a-z]* \([^ ]*\) → \([0-9]*\)次.*/\1 (\2次)/' \
    | tr '\n' '\n' || echo "")

  # 威胁分类（多选，自动检测，构建 JSON 数组）
  local threat_json
  local -a threat_arr=()
  grep -q 'managed_challenge' "$report_file" 2>/dev/null && threat_arr+=("Bot流量") || true
  grep -qE 'TENCENT|CHINANET|China Telecom|CNNIC' "$report_file" 2>/dev/null && threat_arr+=("ASN黑名单") || true
  [ "$gaps" -gt 0 ] && threat_arr+=("规则缺口") || true
  grep -qE 'wlwmanifest|wp-login|union.*select|DROP TABLE' "$report_file" 2>/dev/null && threat_arr+=("注入攻击") || true
  if [ "${#threat_arr[@]}" -gt 0 ]; then
    threat_json=$(printf '%s\n' "${threat_arr[@]}" | jq -R . | jq -s .)
  else
    threat_json='[]'
  fi

  # 风险等级
  local risk="🟢正常"
  if [[ "${anomalies:-0}" -ge 5 || "${gaps:-0}" -ge 3 ]]; then
    risk="🔴警告"
  elif [[ "${anomalies:-0}" -ge 1 || "${gaps:-0}" -ge 1 ]]; then
    risk="🟡注意"
  fi

  local summary
  summary=$(grep -A5 "4/4 摘要" "$report_file" 2>/dev/null | tail -4 | tr '\n' '\\n' || echo "")

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && { log "token 为空，跳过"; exit 0; }

  # 构造 Bitable fields（时间戳转 ms 整数，使用北京时间 epoch）
  local ts_ms
  ts_ms=$((epoch_local * 1000))

  local notify_uid="${FEISHU_NOTIFY_USER_ID:-}"

  local fields
  fields=$(jq -n \
    --arg zone "$zone" \
    --argjson cart "$cart" \
    --argjson checkout "$checkout" \
    --argjson blocks "$blocks" \
    --argjson anomalies "$anomalies" \
    --argjson gaps "$gaps" \
    --arg risk "$risk" \
    --arg summary "$summary" \
    --argjson ts_ms "$ts_ms" \
    --argjson total_req "$total_req" \
    --arg top_ips "$top_ips" \
    --argjson threat_json "$threat_json" \
    --arg notify_uid "$notify_uid" \
    --arg title "${zone}-巡检-${bj_datetime:0:16}" \
    '{
      "标题": $title,
      "巡检时间": $ts_ms,
      "Zone": $zone,
      "Cart流量": $cart,
      "Checkout流量": $checkout,
      "防火墙拦截数": $blocks,
      "高频异常IP数": $anomalies,
      "规则缺口数": $gaps,
      "风险等级": $risk,
      "摘要": $summary,
      "总请求量": $total_req,
      "TOP异常IP": $top_ips,
      "威胁分类": $threat_json,
      "已处理": false
    } + (if $notify_uid != "" then {"责任人": [{"id": $notify_uid}]} else {} end)')

  insert_record "$token" "${FEISHU_CF_TABLE_ID:-}" "$fields"

  # 每次巡检都直接发 IM（卡片两列布局，颜色随风险等级）
  local im_color="green"
  [ "$risk" = "🟡注意" ] && im_color="yellow"
  [ "$risk" = "🔴警告" ] && im_color="red"

  local im_card
  im_card=$(jq -nc \
    --arg color   "$im_color" \
    --arg zone    "$zone" \
    --arg dt      "${bj_datetime:0:16}" \
    --arg risk    "$risk" \
    --arg total   "$total_req" \
    --arg blocks  "$blocks" \
    --arg cart    "$cart" \
    --arg chk     "$checkout" \
    --arg anom    "$anomalies" \
    --arg gaps    "$gaps" \
    --arg top_ips "$top_ips" \
    --argjson threats "$threat_json" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: $color,
        title: {tag: "plain_text", content: ("🛡️ CF 安全巡检 | " + $zone)}
      },
      elements: [
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**巡检时间**\n" + $dt)}},
          {is_short: true, text: {tag: "lark_md", content: ("**风险等级**\n" + $risk)}}
        ]},
        {tag: "hr"},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**总请求量**\n" + $total + " 次")}},
          {is_short: true, text: {tag: "lark_md", content: ("**防火墙拦截**\n" + $blocks + " 次")}}
        ]},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**Cart 流量**\n" + $cart + " 次")}},
          {is_short: true, text: {tag: "lark_md", content: ("**Checkout 流量**\n" + $chk + " 次")}}
        ]},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**高频异常 IP**\n" + $anom + " 个")}},
          {is_short: true, text: {tag: "lark_md", content: ("**规则缺口**\n" + $gaps + " 个")}}
        ]}
      ]
      + (if ($top_ips | length) > 0 then [
          {tag: "hr"},
          {tag: "div", text: {tag: "lark_md",
            content: ("**TOP 异常 IP**\n" +
              ($top_ips | split("\n") | map(select(length>0) | "• " + .) | join("\n")))
          }}
        ] else [] end)
      + (if ($threats | length) > 0 then [
          {tag: "div", text: {tag: "lark_md",
            content: ("**威胁分类**：" + ($threats | join("  ·  ")))
          }}
        ] else [] end)
    }')
  send_im_direct "$token" "$im_card"

  # 🔴 警告时额外发群消息（webhook）
  if [ "$risk" = "🔴警告" ] && [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
    local msg="**CF 安全警告 | $zone**\n\n"
    msg+="- Cart 流量：$cart | Checkout：$checkout\n"
    msg+="- 防火墙拦截：$blocks 次\n"
    msg+="- 高频异常 IP：$anomalies 个 | 规则缺口：$gaps 个\n\n"
    msg+="请尽快检查运维 Dashboard"
    send_webhook_card "🔴 CF 安全警告" "$msg" "red"
  fi

  log "CF 报告处理完成: 风险=$risk cart=$cart checkout=$checkout 拦截=$blocks"
}

# ── 子命令：health ────────────────────────────────────────────────────────
cmd_health() {
  local alias="$1" cpu="$2" mem="$3" disk="$4" status="$5" note="${6:-}"

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && exit 0

  # 状态映射
  local status_label
  case "$status" in
    ok|normal) status_label="正常" ;;
    warn|warning) status_label="警告" ;;
    *) status_label="异常" ;;
  esac

  local ts_ms
  ts_ms=$(( $(date +%s) * 1000 ))

  # cpu/mem/disk 去掉 % 符号
  cpu="${cpu//%/}"
  mem="${mem//%/}"
  disk="${disk//%/}"

  local fields
  fields=$(jq -n \
    --arg alias "$alias" \
    --argjson cpu "${cpu:-0}" \
    --argjson mem "${mem:-0}" \
    --argjson disk "${disk:-0}" \
    --arg status_label "$status_label" \
    --arg note "$note" \
    --argjson ts_ms "$ts_ms" \
    '{
      "检查时间": $ts_ms,
      "服务器": $alias,
      "CPU%": $cpu,
      "内存%": $mem,
      "磁盘%": $disk,
      "状态": $status_label,
      "备注": $note
    }')

  insert_record "$token" "${FEISHU_SERVER_TABLE_ID:-}" "$fields"
  log "健康数据已推送: $alias cpu=$cpu% mem=$mem% disk=$disk% status=$status_label"

  # warn / error 时直接发 IM 告警，ok 不打扰
  if [ "$status" != "ok" ] && [ "$status" != "normal" ]; then
    local im_color="yellow"
    [ "$status" = "error" ] || [ "$status" = "critical" ] && im_color="red"

    local im_card
    im_card=$(jq -nc \
      --arg color "$im_color" \
      --arg alias "$alias" \
      --arg status_label "$status_label" \
      --arg cpu "${cpu}%" \
      --arg mem "${mem}%" \
      --arg disk "${disk}%" \
      --arg note "$note" \
      '{
        config: {wide_screen_mode: true},
        header: {
          template: $color,
          title: {tag: "plain_text", content: ("⚠️ 服务器告警 | " + $alias)}
        },
        elements: [
          {tag: "div", fields: [
            {is_short: true, text: {tag: "lark_md", content: ("**服务器**\n" + $alias)}},
            {is_short: true, text: {tag: "lark_md", content: ("**状态**\n" + $status_label)}}
          ]},
          {tag: "hr"},
          {tag: "div", fields: [
            {is_short: true, text: {tag: "lark_md", content: ("**CPU**\n" + $cpu)}},
            {is_short: true, text: {tag: "lark_md", content: ("**内存**\n" + $mem)}}
          ]},
          {tag: "div", fields: [
            {is_short: true, text: {tag: "lark_md", content: ("**磁盘**\n" + $disk)}},
            {is_short: true, text: {tag: "lark_md", content: ("**备注**\n" + (if $note != "" then $note else "—" end))}}
          ]}
        ]
      }')
    send_im_direct "$token" "$im_card"
  fi
}

# ── 子命令：deploy ────────────────────────────────────────────────────────
cmd_deploy() {
  local alias="$1" project="$2" status="$3" message="${4:-}"

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && exit 0

  local im_color title_emoji result_label
  if [ "$status" = "success" ]; then
    im_color="green"; title_emoji="✅"; result_label="✅ 成功"
  else
    im_color="red"; title_emoji="❌"; result_label="❌ 失败"
  fi

  local dt ts_ms
  dt=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
  ts_ms=$(( $(date +%s) * 1000 ))

  # 写入 Bitable 部署记录表
  local fields
  fields=$(jq -n \
    --argjson ts_ms "$ts_ms" \
    --arg alias "$alias" \
    --arg project "$project" \
    --arg result "$result_label" \
    --arg message "$message" \
    '{
      "部署时间": $ts_ms,
      "服务器": $alias,
      "项目": $project,
      "结果": $result,
      "详情": $message
    }')
  insert_record "$token" "${FEISHU_DEPLOY_TABLE_ID:-}" "$fields"

  local im_card
  im_card=$(jq -nc \
    --arg color "$im_color" \
    --arg alias "$alias" \
    --arg project "$project" \
    --arg status "$status" \
    --arg message "$message" \
    --arg emoji "$title_emoji" \
    --arg dt "$dt" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: $color,
        title: {tag: "plain_text", content: ($emoji + " 部署通知 | " + $alias)}
      },
      elements: [
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**服务器**\n" + $alias)}},
          {is_short: true, text: {tag: "lark_md", content: ("**项目**\n" + $project)}}
        ]},
        {tag: "hr"},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md",
            content: ("**状态**\n" + (if $status == "success" then "已上线 ✅" else "部署失败 ❌" end))}},
          {is_short: true, text: {tag: "lark_md", content: ("**时间**\n" + $dt)}}
        ]}
      ]
      + (if $message != "" then [
          {tag: "hr"},
          {tag: "div", text: {tag: "lark_md", content: ("**详情**\n" + $message)}}
        ] else [] end)
    }')
  send_im_direct "$token" "$im_card"
  log "部署通知已发送: $alias $project ($status)"
}

# ── 子命令：waf ───────────────────────────────────────────────────────────
cmd_waf() {
  local zone="$1" rule_name="$2" change_type="$3" reason="$4"

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && exit 0

  local ts_ms
  ts_ms=$(( $(date +%s) * 1000 ))

  local fields
  fields=$(jq -n \
    --arg zone "$zone" \
    --arg rule_name "$rule_name" \
    --arg change_type "$change_type" \
    --arg reason "$reason" \
    --argjson ts_ms "$ts_ms" \
    '{
      "变更时间": $ts_ms,
      "Zone": $zone,
      "规则名称": $rule_name,
      "变更类型": $change_type,
      "原因": $reason
    }')

  insert_record "$token" "${FEISHU_WAF_TABLE_ID:-}" "$fields"

  # WAF 变更：IM 直发 + 可选群消息
  local waf_card
  waf_card=$(jq -nc \
    --arg zone "$zone" \
    --arg rule_name "$rule_name" \
    --arg change_type "$change_type" \
    --arg reason "$reason" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: "blue",
        title: {tag: "plain_text", content: ("🛡️ WAF 规则变更 | " + $zone)}
      },
      elements: [
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**规则名称**\n" + $rule_name)}},
          {is_short: true, text: {tag: "lark_md", content: ("**变更类型**\n" + $change_type)}}
        ]},
        {tag: "hr"},
        {tag: "div", text: {tag: "lark_md", content: ("**变更原因**\n" + $reason)}}
      ]
    }')
  send_im_direct "$token" "$waf_card"

  if [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
    local msg="**WAF 规则变更 | $zone**\n\n"
    msg+="- 规则：$rule_name\n"
    msg+="- 类型：$change_type\n"
    msg+="- 原因：$reason"
    send_webhook_card "🛡️ WAF 规则变更" "$msg" "blue"
  fi

  log "WAF 变更已推送: $zone $rule_name ($change_type)"
}

# ── 子命令：ssl ──────────────────────────────────────────────────────────
cmd_ssl() {
  local domain="$1" days="$2" issuer="$3" expiry="$4" status="$5"

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && exit 0

  local im_color="yellow" emoji="⚠️" status_label="即将过期"
  if [ "$status" = "expired" ]; then
    im_color="red"; emoji="🔴"; status_label="已过期"
  fi

  local im_card
  im_card=$(jq -nc \
    --arg color "$im_color" \
    --arg domain "$domain" \
    --arg days "$days" \
    --arg issuer "$issuer" \
    --arg expiry "$expiry" \
    --arg emoji "$emoji" \
    --arg status_label "$status_label" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: $color,
        title: {tag: "plain_text", content: ($emoji + " SSL 证书告警 | " + $domain)}
      },
      elements: [
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**域名**\n" + $domain)}},
          {is_short: true, text: {tag: "lark_md", content: ("**状态**\n" + $status_label)}}
        ]},
        {tag: "hr"},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**过期时间**\n" + $expiry)}},
          {is_short: true, text: {tag: "lark_md", content: ("**剩余天数**\n" + $days + " 天")}}
        ]},
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**颁发者**\n" + $issuer)}}
        ]}
      ]
    }')
  send_im_direct "$token" "$im_card"
  log "SSL 告警已发送: $domain ($status, ${days}天)"
}

# ── 子命令：perf ──────────────────────────────────────────────────────────
cmd_perf() {
  local report_file="$1"
  [ ! -f "$report_file" ] && { log "性能报告不存在: $report_file"; exit 0; }

  local token
  token=$(get_token) || exit 0
  [ -z "$token" ] && exit 0

  local status count
  status=$(jq -r '.status' "$report_file" 2>/dev/null || echo "ok")
  count=$(jq -r '.results | length' "$report_file" 2>/dev/null || echo "0")

  local dt ts_ms
  dt=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')
  ts_ms=$(( $(date +%s) * 1000 ))

  # ── 创建飞书文档（详细报告）──
  local doc_url=""
  if [ -f "$PROJECT_DIR/scripts/feishu-perf-doc.sh" ]; then
    doc_url=$(bash "$PROJECT_DIR/scripts/feishu-perf-doc.sh" "$report_file" "$token" 2>/dev/null || echo "")
  fi

  # ── 遍历每个 URL 写入 Bitable ──
  local perf_table="${FEISHU_PERF_TABLE_ID:-}"
  local i=0
  while [ "$i" -lt "$count" ]; do
    local url score lcp fcp cls ttfb url_status
    url=$(jq -r ".results[$i].url" "$report_file")
    score=$(jq -r ".results[$i].score" "$report_file")
    lcp=$(jq -r ".results[$i].lcp" "$report_file")
    fcp=$(jq -r ".results[$i].fcp" "$report_file")
    cls=$(jq -r ".results[$i].cls" "$report_file")
    ttfb=$(jq -r ".results[$i].ttfb" "$report_file")
    url_status=$(jq -r ".results[$i].status" "$report_file")

    if [ -n "$perf_table" ]; then
      local fields
      fields=$(jq -n \
        --argjson ts_ms "$ts_ms" \
        --arg url "$url" \
        --argjson score "$score" \
        --argjson lcp "$lcp" \
        --argjson fcp "$fcp" \
        --arg cls "$cls" \
        --argjson ttfb "$ttfb" \
        --arg status "$url_status" \
        --arg doc_url "$doc_url" \
        '{
          "检查时间": $ts_ms,
          "URL": $url,
          "Performance Score": $score,
          "LCP(ms)": $lcp,
          "FCP(ms)": $fcp,
          "CLS": ($cls | tonumber),
          "TTFB(ms)": $ttfb,
          "状态": $status
        } + (if $doc_url != "" then {"报告链接": {link:$doc_url, text:"查看报告"}} else {} end)')
      insert_record "$token" "$perf_table" "$fields"
    fi
    i=$(( i + 1 ))
  done

  # ── IM 卡片（简洁摘要 + 文档链接按钮）──
  local im_color="green"
  [ "$status" = "warn" ] && im_color="yellow"
  [ "$status" = "error" ] && im_color="red"

  # 构建 URL 摘要行
  local url_lines="[]"
  i=0
  while [ "$i" -lt "$count" ]; do
    local u s l t st se le
    u=$(jq -r ".results[$i].url" "$report_file" | sed 's|https://||')
    s=$(jq -r ".results[$i].score" "$report_file")
    l=$(jq -r ".results[$i].lcp" "$report_file")
    t=$(jq -r ".results[$i].ttfb" "$report_file")
    st=$(jq -r ".results[$i].status" "$report_file")
    se="🟢"; [ "$s" -lt 90 ] 2>/dev/null && se="🟡"; [ "$s" -lt 50 ] 2>/dev/null && se="🔴"
    le="🟢"; [ "$l" -gt 2500 ] 2>/dev/null && le="🟡"; [ "$l" -gt 4000 ] 2>/dev/null && le="🔴"
    url_lines=$(echo "$url_lines" | jq \
      --arg u "$u" --arg s "$s" --arg l "$l" --arg t "$t" --arg se "$se" --arg le "$le" \
      '. + [($se + " Score: " + $s + "  |  " + $le + " LCP: " + $l + "ms  |  TTFB: " + $t + "ms")]')
    i=$(( i + 1 ))
  done

  # 构建 TOP 3 优化项
  local top_opps="[]"
  local opp_count
  opp_count=$(jq -r '.results[0].opportunities | length' "$report_file" 2>/dev/null || echo "0")
  local max_opp=3
  [ "$opp_count" -lt "$max_opp" ] && max_opp="$opp_count"
  i=0
  while [ "$i" -lt "$max_opp" ]; do
    local ot os
    ot=$(jq -r ".results[0].opportunities[$i].title" "$report_file")
    os=$(jq -r ".results[0].opportunities[$i].savings_ms" "$report_file")
    top_opps=$(echo "$top_opps" | jq --arg t "$ot" --arg s "$os" '. + [("🔧 " + $t + " (-" + $s + "ms)")]')
    i=$(( i + 1 ))
  done

  local im_card
  im_card=$(jq -nc \
    --arg color "$im_color" \
    --arg dt "$dt" \
    --arg status "$status" \
    --argjson url_lines "$url_lines" \
    --argjson top_opps "$top_opps" \
    --arg doc_url "$doc_url" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: $color,
        title: {tag: "plain_text", content: "📊 网站性能监控"}
      },
      elements: [
        {tag: "div", fields: [
          {is_short: true, text: {tag: "lark_md", content: ("**检查时间**\n" + $dt)}},
          {is_short: true, text: {tag: "lark_md", content: ("**整体状态**\n" + (if $status == "ok" then "🟢 正常" elif $status == "warn" then "🟡 注意" else "🔴 异常" end))}}
        ]},
        {tag: "hr"},
        {tag: "div", text: {tag: "lark_md", content: ($url_lines | join("\n"))}}
      ]
      + (if ($top_opps | length) > 0 then [
          {tag: "hr"},
          {tag: "div", text: {tag: "lark_md", content: ("**TOP 优化项**\n" + ($top_opps | join("\n")))}}
        ] else [] end)
      + (if $doc_url != "" then [
          {tag: "hr"},
          {tag: "action", actions: [{
            tag: "button",
            text: {tag: "plain_text", content: "📄 查看完整报告"},
            type: "primary",
            url: $doc_url
          }]}
        ] else [] end)
    }')
  send_im_direct "$token" "$im_card"

  log "性能报告处理完成: status=$status urls=$count doc=$doc_url"
}

# ── cmd_learning: 自主学习成果通知 ─────────────────────────────────────────
# 用法：feishu-report.sh learning <report_file>
# 流程：创建飞书云文档 → 发群通知卡片（含文档链接）
# report_file 为 JSON: {"topic":"课题","reason":"为什么学","learnings":["要点1"],"knowledge_files":["文件1"],"impact":"影响","sources":["url1"]}
cmd_learning() {
  local report_file="${1:?用法: feishu-report.sh learning <report.json>}"
  [ ! -f "$report_file" ] && { log "报告文件不存在: $report_file"; exit 1; }

  local chat_id="${FEISHU_LEARNING_CHAT_ID:-}"
  [ -z "$chat_id" ] && { log "FEISHU_LEARNING_CHAT_ID 未配置，跳过学习通知"; return 0; }

  local token
  token=$(get_token)
  [ -z "$token" ] && { log "获取 token 失败，跳过学习通知"; return 0; }

  # 解析报告
  local topic reason impact
  topic=$(jq -r '.topic // "未知课题"' "$report_file")
  reason=$(jq -r '.reason // ""' "$report_file")
  impact=$(jq -r '.impact // ""' "$report_file")

  local learnings_text
  learnings_text=$(jq -r '.learnings // [] | map("- " + .) | join("\n")' "$report_file")
  [ -z "$learnings_text" ] && learnings_text="- （无具体要点）"

  local learnings_count
  learnings_count=$(jq -r '.learnings // [] | length' "$report_file")

  local files_text
  files_text=$(jq -r '.knowledge_files // [] | map("📄 " + .) | join("  ")' "$report_file")

  local now_bj
  now_bj=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')

  # 1. 尝试创建飞书云文档
  local doc_url=""
  doc_url=$(create_learning_doc "$token" "$report_file" 2>/dev/null) || true

  # 2. 构建群通知卡片
  local im_card
  im_card=$(jq -n \
    --arg topic "$topic" \
    --arg reason "$reason" \
    --arg learnings "$learnings_text" \
    --arg count "$learnings_count" \
    --arg files "$files_text" \
    --arg impact "$impact" \
    --arg time "$now_bj" \
    --arg doc_url "$doc_url" \
    '{
      config: {wide_screen_mode: true},
      header: {
        template: "purple",
        title: {tag: "plain_text", content: ("📚 自主学习完成 | " + $topic)}
      },
      elements: [
        {tag: "div", text: {tag: "lark_md", content: ("**触发原因：**" + $reason)}},
        {tag: "hr"},
        {tag: "div", text: {tag: "lark_md", content: ("**学到了（" + $count + " 个要点）：**\n" + $learnings)}},
        {tag: "hr"},
        {tag: "div", text: {tag: "lark_md", content: ("**未来影响：**" + $impact)}},
        {tag: "div", text: {tag: "lark_md", content: ("**更新知识：**" + $files)}}
      ]
      + (if $doc_url != "" then [
          {tag: "hr"},
          {tag: "action", actions: [{
            tag: "button",
            text: {tag: "plain_text", content: "📖 查看完整学习笔记"},
            type: "primary",
            url: $doc_url
          }]}
        ] else [] end)
      + [
        {tag: "note", elements: [{tag: "plain_text", content: ("🕐 " + $time + " | 🤖 自主学习")}]}
      ]
    }')

  # 3. 发送群消息（带重试）
  local body result code
  body=$(jq -n --arg cid "$chat_id" --arg card "$im_card" \
    '{"receive_id":$cid,"msg_type":"interactive","content":$card}')
  result=$(curl_retry 3 -sf -X POST \
    "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body") || { log "学习群通知发送失败（3次重试）: topic=$topic"; return 1; }

  code=$(echo "$result" | jq -r '.code // -1')
  if [ "$code" = "0" ]; then
    log "学习报告已发群: topic=$topic doc=$doc_url"
  else
    log "学习群通知异常 (code=$code): $result"
  fi
}

# ── 主入口 ────────────────────────────────────────────────────────────────
CMD="${1:-}"
shift || true

case "$CMD" in
  cf)       cmd_cf "$@" ;;
  health)   cmd_health "$@" ;;
  deploy)   cmd_deploy "$@" ;;
  waf)      cmd_waf "$@" ;;
  perf)     cmd_perf "$@" ;;
  ssl)      cmd_ssl "$@" ;;
  learning) cmd_learning "$@" ;;
  *)
    echo "用法：$0 <cf|health|deploy|waf|perf|ssl|learning> [args...]"
    echo "  cf       <report_file>"
    echo "  health   <alias> <cpu%> <mem%> <disk%> <ok|warn|error> [note]"
    echo "  deploy   <alias> <project> <success|fail> [message]"
    echo "  waf      <zone> <rule_name> <新增|修改|删除> <reason>"
    echo "  perf     <report_file>"
    echo "  ssl      <domain> <days_remaining> <issuer> <expiry_date> <ok|warning|expired>"
    echo "  learning <report.json>"
    exit 1
    ;;
esac
