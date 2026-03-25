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
- ✅ 有空闲 Worker 时所有任务（含研究/探索）SendMessage 给 Worker，不 spawn 新 agent
- ❌ Lead 执行 Skill → 阻塞轮询，无法感知新消息
- ❌ 有空闲 Worker 却 spawn Explore/general-purpose agent → iTerm 面板堆积，Worker 浪费
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

## 中心化状态协议（Worker 心跳 + 状态注册表 + 精准恢复）

> 2026-03-25 新增。从 server-maintenance + android-tools 两个项目验证。

### 设计哲学
- ✅ **状态集中存储**：所有 Worker 状态存储在 Express 服务器 + `data/worker-states.json`
- ✅ **恢复决策分布式**：stop-check.sh 和 dashboard-poll.sh 各自独立读状态做决策
- ✅ **不盲目重建**：任何组件检测到 Worker 异常时，先"读账本"再精准恢复
- ❌ 全量 TeamDelete + 重建所有 Worker → 丢失正在执行的任务 + iTerm 窗格溢出

### Worker 生命周期（5 阶段）
```
online → busy → progress → idle → error
  ↑                                  |
  └──────── spawn 重建 ←─────────────┘
```

- ✅ 每个阶段通过 `POST /api/worker/state` 上报（含 task 描述）
- ✅ 心跳：Worker 启动时 + 完成任务时，30 分钟无心跳视为 dead
- ✅ 状态上报视为心跳（一次 API 调用同时刷新两者）
- ❌ 只发心跳不上报状态 → Lead 不知道 Worker 在干什么

### Worker ID 持久化
- ✅ spawn 后**立即**写 `data/worker-ids.json`（task ID + 时间戳）
- ✅ 上下文压缩后从文件恢复 task ID → SendMessage 继续使用
- ❌ 不写文件 → 压缩后丢失 task ID，无法恢复通信

### 精准恢复流程（stop-check.sh）
```
读 worker-ids.json → 查 /api/team/health → 读状态注册表 → 决策
```

恢复策略矩阵：

| alive 数 | dead Worker 状态 | 动作 |
|----------|-----------------|------|
| N/N（全部） | - | 代发心跳，恢复 task IDs |
| >0 | idle/error | ping → 60s 无回复 → spawn 那一个 |
| >0 | busy (<30min) | 不动，等待任务完成 |
| 0 | - | 代发心跳刷新 → 再查 → 仍为 0 → 逐个 spawn |

- ✅ busy Worker 绝不重建（保护正在执行的任务）
- ✅ ping 确认后才 spawn（避免误判）
- ❌ alive=0 就直接全量重建 → busy 的 Worker 可能只是心跳延迟

### 轮询保活（DAEMON_MODE 双模式）
- ✅ Normal 模式：消费消息 → 输出 → 退出前自启 Daemon 副本（nohup）
- ✅ Daemon 模式：不消费消息（避免无人处理），只做 60s Worker 健康检查
- ✅ 冷却机制：1 小时内不重复 ping 同一批 Worker
- ❌ 退出时不启 Daemon → Workers 死了没人发现

### Lead 调度原则
- ✅ Lead **只做轮询和调度，不执行任何 SSH/Skill 操作**
- ✅ 收到飞书/Dashboard 消息 → 1 秒内 SendMessage 给空闲 Worker → 立即回到当前任务
- ✅ 飞书消息和主任务并行，不串行
- ❌ Lead 自己去 SSH 查服务器 → Worker 全空闲，Lead 阻塞在单任务上
