# 自我学习机制

## 核心理念

Agent 不应只执行指令，而应该从持续运行中积累领域知识。每次 Plugin 报告、Skill 执行、异常处理都是学习机会。

## 学习闭环

```
Plugin daemon 产出数据
    ↓
POST /api/messages → Claude 轮询收到
    ↓
Claude 分析（对比知识库中的基线和历史）
    ↓
├── 正常：简报 + 确认基线稳定
├── 异常：深入分析 + 记录到 incident-log
└── 趋势：更新基线 + 记录变化原因
    ↓
更新 memory/knowledge/ 知识文件
    ↓
下次分析时，读取更新后的知识 → 对比更精准
```

## 知识文件设计原则

### 1. 基线文件（baselines）

记录正常状态的量化数据，用于异常检测：

```markdown
## 性能基线

| URL | Score | LCP | TTFB | 采样时间 | 样本数 |
|-----|-------|-----|------|---------|--------|
| example.com | 75±5 | 3200±400ms | 200±50ms | 2026-03-12 | 15 |

> 连续 3 次偏离基线 > 20% 视为趋势变化，需记录 incident
```

关键：基线不是固定值，是**滚动平均 + 标准差**。每次检查后微调。

### 2. 模式文件（patterns）

记录发现的规律和因果关系：

```markdown
## 已确认模式

### Shopify 高峰时段
- 观察：每周二/四 20:00-22:00 流量翻倍
- 影响：LCP 上升 30%，WAF 拦截数翻倍
- 处置：高峰前不做规则变更
- 首次发现：2026-03-01 | 确认次数：5

### CF 规则变更后 24h
- 观察：新增 WAF 规则后 24h 内误报率高
- 处置：新规则先用 managed_challenge 模式，观察 24h 再切 block
- 首次发现：2026-02-28 | 确认次数：3
```

### 3. 事件日志（incident-log）

跨实体的重要事件时间线，帮助发现关联：

```markdown
| 日期 | 类型 | 事件 | 影响 |
|------|------|------|------|
| 03-10 | trend | nouhaus LCP 连续 3 次 > 8s | 性能恶化，疑似新 App 安装 |
| 03-11 | change | CF 新增 ASN 拦截规则 | 拦截率 +15%，误报待观察 |
| 03-12 | discovery | LCP 退步与新 Shopify App 相关 | 建议移除或延迟加载 |
```

## 学习状态机

课题在 `learning-queue.md` 中流转，有 3 个状态：

```
pending ──claim──→ learning ──完成──→ done（移到已完成表）
   ↑                  │
   └──recover(24h)────┘   claim 超时(2h) 自动释放锁
```

### 状态流转

| 状态 | 含义 | 进入条件 | 退出条件 |
|------|------|---------|---------|
| `pending` | 待学 | 用户/Hook 写入，或 recover 重置 | Worker claim 成功 |
| `learning` | 学习中 | Worker claim 后更新 | 学完 → done，或超时 → pending |
| `done` | 已完成 | 学完移到已完成表 | 终态 |

### 多 Worker 安全

多个 Worker 可能同时空闲，`/api/learning/claim` 保证同一课题只被一个 Worker 学习：

```
Worker-1: POST /api/learning/claim {topic:"X"} → {success:true}   ← 领取成功
Worker-2: POST /api/learning/claim {topic:"X"} → {success:false}  ← 已被领取，选下一个
Worker-1: 学习完成 → POST /api/learning/release {topic:"X"}      ← 释放锁
```

### 超时保护

| 机制 | 超时 | 实现位置 |
|------|------|---------|
| Claim 锁 | 2 小时 | `server.js` cleanExpiredClaims() |
| Learning 状态 | 24 小时 | `/api/learning/recover` 端点 |

- **Claim 锁超时**：Worker crash 后 2h 自动释放，其他 Worker 可重新领取
- **Learning 状态恢复**：`idle-learn.sh` 启动时调用 recover API，将昨天及更早的 `learning` 状态重置为 `pending`

### Hook 驱动链

```
主进程 Stop hook (learning-reflect.sh)
    → 每次实际工作后反思盲区
    → 发现盲区写入 learning-queue.md
    → 如有最近学习成果，提醒验证是否正确应用

Worker TeammateIdle hook (idle-learn.sh)
    → 调用 /api/learning/recover 清理 stale
    → 有 pending 课题 → 反思 + 领取 + 学习 (exit 2)
    → 无课题 + 冷却期外 → 仅反思 (exit 2)
    → 无课题 + 冷却期内 → 允许空闲 (exit 0)

UserPromptSubmit hook (prompt-check.sh)
    → 检测用户消息中的新概念
    → 注入提醒调用 intent-check Skill 验证理解
```

### Dashboard API 端点

| 端点 | 方法 | 用途 |
|------|------|------|
| `/api/learning/claim` | POST | 领取课题 `{topic, worker_name}` |
| `/api/learning/release` | POST | 释放课题 `{topic}` |
| `/api/learning/claims` | GET | 查看当前所有锁 |
| `/api/learning/recover` | POST | 恢复 stale 课题（learning > 24h → pending） |

## Agent 何时该学习

### 收到 Plugin 报告时（自动触发）

```
收到 cf_report / perf_report / ssl_report ...
    ↓
1. 读取对应知识文件（baselines + patterns）
2. 对比本次数据 vs 基线
3. 如有显著变化：
   - 更新基线（滚动平均）
   - 记录 incident-log
   - 检查是否匹配已知模式
   - 如果不匹配 → 记录为新模式待确认
```

### 执行 Skill 后（主动反思）

```
部署操作完成 / WAF 规则变更 / 配置修改
    ↓
1. 记录操作到实体 memory 的操作历史
2. 预期：这次操作应该产生什么效果？
3. 设置观察点：下次 Plugin 报告时验证效果
4. 验证结果写入 patterns（操作→效果的因果关系）
```

### 趋势检测（跨多次报告）

```
每次分析不只看当次，还读 data/ 历史：
- perf-history.csv → 7 天趋势
- cf-reports/ → 拦截量变化
- ssl-reports/ → 证书剩余天数倒计时

连续 3+ 次同方向变化 = 趋势，写入 incident-log
```

## CLAUDE.md 中应添加的指令

在 Agent 的 CLAUDE.md 中添加以下段落，让 Claude 知道自己应该学习：

```markdown
### 自我学习规则

收到 Plugin 报告（如 `cf_report`、`perf_report`）时：
1. **先读知识**：读取 `memory/knowledge/` 相关文件了解基线和模式
2. **对比分析**：本次数据 vs 历史基线，检测异常和趋势
3. **更新知识**：
   - 基线变化 → 更新 baselines 文件
   - 新发现 → 写入 patterns 文件
   - 重要事件 → 记录 incident-log
4. **不只报告，要解释为什么** — 告诉用户"相比上次"的变化
```

## 跨项目知识传递

当多个 Agent 实例基于同一个 agent-kit 时：

```
Agent A (server-maintenance)  →  学到 Shopify 安全模式
Agent B (另一个电商项目)      →  也能用这些模式

共享路径：
1. Agent A 发现有价值的通用模式
2. 用户确认后，反哺到 agent-kit/docs/proven-patterns.md
3. Agent B 创建时继承这些知识
```

目前这一步需要人工触发（用户说"同步到 kit"）。未来可以通过共享知识目录自动化。
