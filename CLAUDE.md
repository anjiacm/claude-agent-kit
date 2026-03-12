# Claude Agent Kit — 框架维护指南

## 这是什么

这是一个**元项目** — 不是 Agent 本身，而是用来创建 Agent 的框架。通过 `create-agent.sh` 脚手架，可以快速生成具备完整运作体系的 Claude Code Agent 项目。

## 核心架构：8 个可复用原语

| 原语 | 文件 | 说明 |
|------|------|------|
| Agent 定义 | `skeleton/CLAUDE.md.tmpl` | 角色、启动序列、安全规则、Skill 映射 |
| Dashboard | `skeleton/web/` | Express+WS 服务器 + 等距像素风 Canvas UI |
| Skills | `skeleton/skills/` | 按需技能，无状态，`/{name}` 调用 |
| Plugins | `skeleton/plugins/` | 后台守护进程，有状态，独立于 Claude 进程树 |
| Memory | `skeleton/memory/` | 每实体 Markdown 知识文件，操作前必读 |
| Knowledge | `skeleton/memory/knowledge/` | 跨实体领域知识（基线、模式、事件日志），自我学习积累 |
| Hooks | `skeleton/templates/claude/hooks/` | 会话生命周期自动化（启动/退出/空输入） |
| Config | `skeleton/entities.yaml.tmpl` + `.env` | 实体清单 + 敏感配置分离 |

## 关键设计决策

### Skill vs Plugin 的本质区别
- **Skill**：用户按需触发，在 Claude 上下文内执行，无状态
- **Plugin**：自动定时/事件驱动，nohup 独立进程，有状态，通过消息队列通信
- 判断标准：需要 Claude 理解和执行 → Skill；需要持续运行不受会话影响 → Plugin

### Plugin 自动发现
- `session-start.sh` 扫描 `plugins/*/start.sh` 自动启动，不硬编码
- `/api/cron/status` 读取 `plugins/*/PLUGIN.md` 的 `pid_file` 字段检查进程状态
- 新增 Plugin 只需创建目录 + 3 个文件，无需修改任何框架代码

### 端口隔离
- 每个 Agent 项目使用独立端口（`DASHBOARD_PORT` 环境变量）
- 默认 7890，`create-agent.sh` 可指定其他端口
- 多个 Agent 项目可同时运行互不干扰

### 通信闭环
```
用户终端 ──────────┐
                   ├──→ Claude Code ──→ 执行 Skill ──→ curl 更新 Dashboard
Dashboard 浏览器 ──┤         ↑
                   │    后台轮询（3s）
Plugin 守护进程 ───┘    ← GET /api/messages
```
- Dashboard 是**唯一中枢** — Claude 通过 curl REST API 更新，浏览器通过 WebSocket 接收
- 消息队列实现双向通信 — Dashboard → Claude（用户操作）、Plugin → Claude（定时报告）
- 后台轮询是 Claude 感知外部事件的核心机制，每次处理完必须立即重启

### Team 模式（可选，create-agent.sh 支持）
- `create-agent.sh` 交互时可选 Team Worker 数量
- CLAUDE.md.tmpl 中 `<!-- IF TEAM_MODE -->` 条件段自动渲染
- Lead 只做轮询调度，Worker 执行所有实际操作
- 同一实体的操作分配给同一 Worker（memory 文件并发安全）

### 内置 Plugin
- **feishu-notify**：飞书深度集成（Bot 长连接 + 消息回复 + 多维表格 + IM 直发）
- **webhook-notify**：轻量 Webhook（飞书群/Slack/Discord/自定义）
- `create-agent.sh` 交互时可选启用，未启用的自动清理

### 自我学习机制
- `docs/self-learning.md` — 完整的自我学习指南（学习闭环、知识文件设计、触发时机）
- `skeleton/memory/knowledge/` — 知识库模板（`_index.md` 索引 + `incident-log.md` 事件日志）
- Dashboard API：`GET /api/knowledge` 列表 + `GET /api/knowledge/:topic` 读取内容
- 学习闭环：Plugin 报告 → Claude 对比基线 → 更新知识文件 → 下次分析更精准
- 知识文件三类：baselines（量化基线）、patterns（因果模式）、incident-log（事件时间线）

### 实践真知
- `docs/proven-patterns.md` 记录从生产项目验证的模式与反模式
- CLAUDE.md.tmpl 内置功能自检清单，每次开发后验证通道完整性
- daemon.sh 模板强制通知闭环（消息队列 + 外部推送双通道）

## 文件结构说明

```
claude-agent-kit/
├── CLAUDE.md              ← 你正在读的这个（框架维护者的指南）
├── create-agent.sh        ← 交互式脚手架（含可选能力选择）
├── skeleton/              ← 项目模板（create-agent.sh 复制 + 变量替换）
│   ├── CLAUDE.md.tmpl     ← Agent 灵魂模板（{{VAR}} + 条件段）
│   ├── entities.yaml.tmpl ← 实体清单模板
│   ├── setup.sh           ← 生成项目的安装脚本
│   ├── web/               ← Dashboard 通用版
│   ├── skills/_example/   ← Skill 编写范例（完整生命周期）
│   ├── plugins/
│   │   ├── _example/      ← Plugin 编写范例（含通知闭环）
│   │   ├── feishu-notify/ ← 飞书深度集成（可选）
│   │   └── webhook-notify/← 轻量 Webhook（可选）
│   ├── scripts/           ← 通用脚本（轮询 + Skill helpers）
│   ├── memory/            ← 记忆模板
│   │   └── knowledge/     ← 跨实体知识库（基线/模式/事件日志）
│   └── templates/claude/  ← Hooks + settings 模板
└── docs/                  ← 框架文档 + 实践真知 + 自我学习指南
```

## 维护原则

### 修改 skeleton/ 时注意
- `*.tmpl` 文件使用 `{{VAR}}` 占位符，`create-agent.sh` 通过 sed 替换
- 修改 server.js 时保持通用性 — 不要引入领域特定逻辑
- 修改 index.html 时注意标签使用 API 返回的 `entity_label`，不要硬编码

### 演进方向
- **UI 主题化**：当前只有等距像素风，未来可做多套主题供选择
- ~~Team 模式模板化~~：✅ 已完成（CLAUDE.md.tmpl 条件段 + create-agent.sh 交互）
- ~~Plugin 市场~~：✅ 已内置 feishu-notify + webhook-notify
- ~~create-agent.sh 增强~~：✅ 已支持 Team/飞书/Webhook 选择
- **更多内置 Plugin**：定时报告生成、健康监控告警等

## 从已有项目提炼到 kit 的流程

当在具体项目中验证了新的通用模式后：
1. 确认该模式是**领域无关**的（不依赖特定 SSH/API/数据源）
2. 提取到 skeleton/ 对应位置
3. 如需配置化，添加 `{{VAR}}` 占位符 + `create-agent.sh` 交互
4. 更新 docs/ 文档
5. 在 _example 中添加示例

## 已创建的 Agent 项目

| 项目 | 角色 | 端口 | 实体类型 |
|------|------|------|---------|
| server-maintenance | 服务器运维助手 | 7890 | server (SSH) |
| amazon-analytics | 亚马逊数据分析助手 | 7891 | product (API) |
