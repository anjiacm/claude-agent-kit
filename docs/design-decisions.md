# 设计决策记录

## 为什么是 7 个原语

从 server-maintenance 项目（12 台服务器的运维 Agent）实践中提炼。每个原语解决一个独立问题：

| 问题 | 原语 | 为什么不能少 |
|------|------|-------------|
| Claude 需要知道自己是谁 | Agent 定义 | 没有 CLAUDE.md = 没有灵魂 |
| 用户需要看到发生了什么 | Dashboard | 纯终端交互对非技术用户不友好 |
| Claude 需要知道怎么做事 | Skills | 没有 Skill = 每次都要重新教 |
| 有些事需要持续运行 | Plugins | Claude 会话会结束，但监控不能停 |
| Claude 需要记住每个实体 | Memory | 没有记忆 = 每次都是新手 |
| 会话启动需要自动化 | Hooks | 手动初始化太慢，用户体验差 |
| 敏感信息需要隔离 | Config | Token 不能进 git |

## Skill vs Plugin 判断树

```
需要持续运行？
  ├── 是 → Plugin（daemon.sh + nohup）
  └── 否 → 需要 Claude 理解和判断？
              ├── 是 → Skill（SKILL.md）
              └── 否 → 普通脚本（scripts/）
```

实际例子：
- 健康检查 → **Skill**（需要 Claude 分析结果、决定是否告警）
- CF 定时巡检 → **Plugin**（每 2h 自动跑，结果注入消息队列，Claude 收到后分析）
- Dashboard 轮询 → **脚本**（纯机械轮询，不需要 Claude 理解）

## 为什么 Plugin 用消息队列而不是直接调用

Plugin 独立于 Claude 进程树（nohup），Claude 会话可能已经结束。消息队列是唯一可靠的异步通信方式：

```
Plugin daemon → POST /api/messages → 队列存储 → Claude 轮询拿到 → 分析处理
```

如果 Claude 不在线，消息在队列里等着。下次启动时自动处理。

## 为什么 Dashboard 用等距像素风

最初的 server-maintenance 项目选了这个风格。但这个决策**不应该绑定到框架**：
- 当前 skeleton 直接 fork 了像素风 UI
- 未来应该支持多主题：像素风、简洁卡片、表格式
- 核心是 Express+WS 服务端 + REST API，前端可以完全替换

**现状**：先用着，架构层比 UI 层重要。等有 2-3 个不同类型的 Agent 后再做主题化。

## 端口隔离策略

每个 Agent 项目独立端口，通过 `DASHBOARD_PORT` 环境变量配置：

| 项目 | 端口 | 原因 |
|------|------|------|
| server-maintenance | 7890 | 首个项目，默认端口 |
| amazon-analytics | 7891 | 第二个项目 |
| （未来项目） | 7892+ | 递增 |

多个 Agent 可以同时运行，互不干扰。`create-agent.sh` 支持自定义端口。

## Team 模式的演进

**V1（当前 skeleton）**：单 Claude 实例，直接执行所有 Skill
**V2（server-maintenance 已验证）**：Lead + 4 Worker，Lead 只调度不执行

Team 模式的收益：
- 并行处理多个实体（4 Worker 同时检查 12 台服务器）
- Lead 不阻塞（分配完立即重启轮询）
- Memory 文件安全（同一实体分配给同一 Worker）

Team 模式的成本：
- 更多 API 消耗
- 调度逻辑复杂度增加
- 需要 Task/SendMessage 工具支持

**未来方向**：CLAUDE.md.tmpl 增加 Team 段落的条件渲染。

## 从项目回馈 kit 的流程

```
具体项目验证新模式 → 确认领域无关 → 提取到 skeleton/ → 更新 docs/ → 提交 kit
```

**已回馈**：
- Plugin 自动发现（从 CF daemon 硬编码 → plugins/ 自动扫描）
- 消息队列双向通信（从单向 → Plugin 注入 + 用户操作）
- Memory 可移植化（PROJECT_MEMORY.md + setup.sh 同步）

**待回馈**：
- Team 模式模板化
- UI 主题系统
- 飞书通知 Plugin 通用化
