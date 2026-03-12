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

当多个 Agent 实例基于同一个 claude-agent-kit 时：

```
Agent A (server-maintenance)  →  学到 Shopify 安全模式
Agent B (另一个电商项目)      →  也能用这些模式

共享路径：
1. Agent A 发现有价值的通用模式
2. 用户确认后，反哺到 claude-agent-kit/docs/proven-patterns.md
3. Agent B 创建时继承这些知识
```

目前这一步需要人工触发（用户说"同步到 kit"）。未来可以通过共享知识目录自动化。
