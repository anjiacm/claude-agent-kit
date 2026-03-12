# 实践真知 — 已验证的模式与反模式

> 从 server-maintenance 项目实际运行经验提炼。每条规则都经过生产验证。

## 轮询模式

- ✅ 处理完消息后立即重启轮询（run_in_background）
- ❌ 处理消息时忘记重启 → Claude 变聋，**最常见的错误**

## Daemon 模式

- ✅ nohup 独立进程 + PID 文件 + `trap EXIT` 清理
- ✅ session-start.sh 每次检活，死了自动重启
- ✅ PID 文件含项目名（多项目隔离）
- ❌ 用 run_in_background 做长期任务 → context expiry 后丢失

## Daemon 通知闭环（血泪教训）

- ✅ 消息队列注入 + 外部通知推送（双通道）
- ✅ 报告持久化到 data/（即使通知失败也有记录）
- ❌ daemon 只注入消息队列不推送通知 → **跑了 5 天没人知道结果**
- ❌ 写完 daemon 代码不测试通知通道 → "看起来在跑"但通知是断的

> daemon 生成报告后必须走两条通道：
> 1. `POST /api/messages` — Dashboard 消息队列（Claude 轮询处理）
> 2. 通知 Plugin — 飞书/Webhook 推送（人直接看到）
> 漏掉任何一条 = 通知不完整

## 功能自检

- ✅ 每个新功能完成后走自检清单（消息通道、通知推送、Dashboard 展示、memory、PID）
- ❌ 代码写完就算完 → 漏掉关键通道（如通知）可能几天都不发现

## 启动序列

- ✅ session-start.sh 注入完整步骤清单 + "不要询问用户"
- ✅ Hook 启动后台进程（Dashboard、daemon、Bot），Claude 执行初始化（实体、Team、轮询）
- ❌ Hook 注入的指令不完整 → Claude 遗漏步骤（如不创建 Team）
- ❌ 启动时问用户"要不要执行 xxx" → 应该自动执行

## PID 文件管理

- ✅ `kill -0` 检测进程（比 ps 解析更可靠）
- ✅ `trap 'rm -f "$PID_FILE"' EXIT`（保证清理）
- ✅ 文件名含项目名（多项目隔离）
- ❌ 不清理 stale PID → 误判为"已运行"

## 通知推送

- ✅ Plugin daemon 监听 → 消息队列 → Claude 分析 → 推送结果
- ✅ 报告持久化到 data/ + POST 消息队列（双保险）
- ❌ Claude 直接轮询外部 API → 浪费 context
- ❌ 只 POST 消息队列 → Dashboard 重启后丢失

## Team 模式

- ✅ Lead 只做轮询和调度，不执行 Skill → 响应快
- ✅ 同一实体的操作分配给同一 Worker → memory 文件安全
- ✅ 分配完毕后立即重启轮询，不等 Worker 完成
- ❌ Lead 执行 Skill → 阻塞轮询，无法感知新消息
- ❌ 多 Worker 同时写同一 memory 文件 → 数据丢失

## Memory 并发

- ✅ 同一实体分配给同一 Worker
- ❌ 多 Worker 同时写同一 memory 文件

## API Token 安全

- ✅ .env 不进 git + .env.example 模板
- ✅ curl 命令中变量空白去除：`CF_TOK=$(echo -n "$TOKEN" | tr -d '[:space:]')`
- ❌ Token 硬编码或 echo 到终端

## 统一 Daemon（单进程多子任务）

- ✅ 单进程 60s 轮询，检查各子任务是否到期 → 简化 PID 管理
- ✅ 各子任务独立 `last-check-epoch`、独立开关（`MONITOR_*_ENABLED`）
- ✅ 启动时自动清理旧的独立 daemon 进程（平滑迁移）
- ❌ 每个功能一个独立 daemon → PID 文件爆炸，session-start.sh 臃肿

## 时间补偿（Daemon 启动恢复）

- ✅ 读 `last-check-epoch`，计算距上次的秒数
- ✅ 超过间隔 → 立即执行（补检），未超过 → sleep 剩余时间
- ❌ 重启后盲等完整间隔 → 可能漏检数小时

## 知识库 + 自我学习

- ✅ `memory/knowledge/` 目录存放跨实体领域知识（基线、模式、事件日志）
- ✅ Plugin 报告 → Claude 对比基线 → 更新知识文件 → 下次更精准
- ✅ Dashboard API `/api/knowledge` + `/api/knowledge/:topic` 暴露知识
- ❌ 知识文件建了但不读不更新 → 知识库是死的，**最容易犯的错**
- ❌ 只看当次数据不对比历史 → 无法发现趋势

## 飞书文档化报告

- ✅ 复杂报告用 Docx API 生成飞书文档（富文本表格 + 分析）
- ✅ IM 卡片只做摘要 + "查看完整报告"按钮跳转文档
- ✅ Bitable 加 URL 字段关联文档（数据+报告双链）
- ❌ IM 卡片塞太多内容 → 排版崩溃（`\n` 不转义、挤成一行）
- ❌ 只有数据没有分析 → 用户看不懂，无法转发给开发

> Docx API 要点：
> - 创建: `POST /docx/v1/documents`
> - 简单块（text/heading/divider）: `POST .../blocks/{id}/children`
> - 复杂块（table）: `POST .../blocks/{id}/descendant?document_revision_id=-1`
> - block_type: 2=text, 3=h1, 4=h2, 12=bullet, 13=ordered, 22=divider, 31=table, 32=cell
> - 需要权限: `docx:document`

## curl 调用 Dashboard

- ✅ 用 `-s`（静默），失败时能看到错误
- ❌ `-sf | jq` → `-f` 吞错误信息，jq 报错但不知道原因

## Skill 执行规范

- ✅ spawn → term → execute → status → done → memory（完整流程）
- ✅ 操作前备份配置（`cp xxx.conf xxx.conf.backup.$(date)`）
- ✅ 测试再应用（`nginx -t` 先于 reload）
- ❌ 跳过 memory 读取直接操作 → 不了解实体当前状态

## Context Expiry 恢复

- ✅ Daemon 独立进程（nohup），不受 Claude 会话影响
- ✅ Dashboard 独立 Express 进程，不受影响
- ✅ session-start.sh 自动检活 + 重启
- ❌ 轮询和 Team 依赖 Claude 进程 → 新会话必须重建
- ❌ 消息只存内存队列 → 持久化到 data/ 才安全
