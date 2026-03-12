#!/bin/bash
# UserPromptSubmit hook — 双重职责：
# 1. 空输入时检查 Dashboard 消息
# 2. 非空输入时检测"新概念信号"，提醒调用 intent-check

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
INPUT=$(cat)
USER_INPUT=$(echo "$INPUT" | jq -r '.userInput // empty' | xargs)

# ── 空输入 / "." / "check" → 检查 Dashboard 消息 ──
if [ -z "$USER_INPUT" ] || [ "$USER_INPUT" = "." ] || [ "$USER_INPUT" = "check" ]; then
  result=$(curl -sf http://localhost:${DASHBOARD_PORT:-7890}/api/messages 2>/dev/null)
  count=$(echo "$result" | jq '.messages | length' 2>/dev/null)
  if [ "$count" -gt "0" ] 2>/dev/null; then
    cat << CONTEXT
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Dashboard 有 ${count} 条消息待处理:\n$(echo "$result" | jq -c '.messages[]')"
  }
}
CONTEXT
  fi
  exit 0
fi

# ── 非空输入 → 新概念检测（轻量，< 50ms）──

# 跳过简短指令（< 10 字通常是"巡检"、"看日志"等日常命令）
[ ${#USER_INPUT} -lt 10 ] && exit 0

# 跳过纯中文日常运维指令
echo "$USER_INPUT" | grep -qiE "^(巡检|检查|看日志|部署|重启|状态|查|更新|回滚|停|启动)" && exit 0

# 检测"实现性指令"信号 — 用户要求创建/开发/改造/增加新东西
if echo "$USER_INPUT" | grep -qiE "(加个|增加|创建|开发|写个|实现|改造|新增|搭建|设计|build|create|implement|add|write)"; then

  # 提取关键词（去掉常见中文助词和标点）
  KEYWORDS=$(echo "$USER_INPUT" | sed 's/[，。！？、；：""''（）\[\]{}]/ /g;s/  */ /g')

  # 检查是否有不在知识库中的概念
  KNOWLEDGE_DIR="$PROJECT_DIR/memory/knowledge"
  SKILLS_DIR="$PROJECT_DIR/skills"
  UNKNOWN=""
  KNOWN_COUNT=0
  CHECKED_COUNT=0

  for word in $KEYWORDS; do
    # 跳过短词和常见词
    [ ${#word} -lt 3 ] && continue
    echo "$word" | grep -qiE "^(加个|增加|创建|开发|写个|实现|改造|新增|一个|什么|怎么|可以|需要|报告|脚本|功能|配置|检查|设置|the|and|for|this|that|with)$" && continue

    CHECKED_COUNT=$((CHECKED_COUNT + 1))
    # 在知识库和 skills 中搜索
    found=0
    [ -d "$KNOWLEDGE_DIR" ] && grep -rqli "$word" "$KNOWLEDGE_DIR/" 2>/dev/null && found=1
    [ "$found" -eq 0 ] && [ -d "$SKILLS_DIR" ] && grep -rqli "$word" "$SKILLS_DIR/" 2>/dev/null && found=1

    if [ "$found" -eq 1 ]; then
      KNOWN_COUNT=$((KNOWN_COUNT + 1))
    else
      UNKNOWN="${UNKNOWN:+$UNKNOWN, }$word"
    fi
  done

  # 只在完全陌生的领域触发（已知概念 = 0 且有未知概念）
  if [ -n "$UNKNOWN" ] && [ "$KNOWN_COUNT" -eq 0 ] && [ "$CHECKED_COUNT" -gt 0 ]; then
    cat << CONTEXT
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "【意图校验提醒】用户指令包含知识库中未收录的概念: [$UNKNOWN]。实现前建议调用 /intent-check 验证理解是否正确，避免方向性错误。如果你确信理解正确可跳过。"
  }
}
CONTEXT
    exit 0
  fi
fi

exit 0
