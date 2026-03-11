# Claude Agent Kit — 框架维护指南

## 这是什么

这是一个**元项目** — 不是 Agent 本身，而是用来创建 Agent 的框架。通过 `create-agent.sh` 脚手架，可以快速生成具备完整运作体系的 Claude Code Agent 项目。

## 核心架构：7 个可复用原语

| 原语 | 文件 | 说明 |
|------|------|------|
| Agent 定义 | `skeleton/CLAUDE.md.tmpl` | 角色、启动序列、安全规则、Skill 映射 |
| Dashboard | `skeleton/web/` | Express+WS 服务器 + 等距像素风 Canvas UI |
| Skills | `skeleton/skills/` | 按需技能，无状态，`/{name}` 调用 |
| Plugins | `skeleton/plugins/` | 后台守护进程，有状态，独立于 Claude 进程树 |
| Memory | `skeleton/memory/` | 每实体 Markdown 知识文件，操作前必读 |
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

### Team 模式（可选）
- 生成的 CLAUDE.md.tmpl 默认单人模式
- 可手动扩展为 Lead + N Worker 架构（参考 server-maintenance 项目）
- Lead 只做轮询调度，Worker 执行所有实际操作
- 同一实体的操作分配给同一 Worker（memory 文件并发安全）

## 文件结构说明

```
claude-agent-kit/
├── CLAUDE.md              ← 你正在读的这个（框架维护者的指南）
├── create-agent.sh        ← 交互式脚手架
├── skeleton/              ← 项目模板（create-agent.sh 复制 + 变量替换）
│   ├── CLAUDE.md.tmpl     ← Agent 灵魂模板（{{VAR}} 占位符）
│   ├── entities.yaml.tmpl ← 实体清单模板
│   ├── setup.sh           ← 生成项目的安装脚本
│   ├── web/               ← Dashboard 通用版
│   ├── skills/_example/   ← Skill 编写范例
│   ├── plugins/_example/  ← Plugin 编写范例
│   ├── scripts/           ← 通用脚本（轮询等）
│   ├── memory/            ← 记忆模板
│   └── templates/claude/  ← Hooks + settings 模板
└── docs/                  ← 框架文档
```

## 维护原则

### 修改 skeleton/ 时注意
- `*.tmpl` 文件使用 `{{VAR}}` 占位符，`create-agent.sh` 通过 sed 替换
- 修改 server.js 时保持通用性 — 不要引入领域特定逻辑
- 修改 index.html 时注意标签使用 API 返回的 `entity_label`，不要硬编码

### 演进方向
- **UI 主题化**：当前只有等距像素风，未来可做多套主题供选择
- **Team 模式模板化**：将 Lead+Worker 架构作为 CLAUDE.md.tmpl 的可选段落
- **Plugin 市场**：常用 Plugin（飞书通知、定时报告、Webhook 监听）提取为可复用模块
- **create-agent.sh 增强**：支持选择主题、Team 规模、预装 Plugin 等

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
