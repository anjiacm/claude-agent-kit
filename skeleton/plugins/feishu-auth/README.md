# Feishu OAuth Plugin

飞书 user_access_token 获取插件，支持自动刷新。

## 为什么需要

飞书部分 API（如知识库 Wiki）要求 `user_access_token`（用户身份），不支持 `tenant_access_token`（应用身份）。

## 前置配置

1. `.env` 中配置 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`
2. 在[飞书开放平台](https://open.feishu.cn) → 应用 → 安全设置 → 添加重定向 URL：
   ```
   http://localhost:9876/callback
   ```

## 使用

### 首次授权
```bash
bash plugins/feishu-auth/setup.sh
# 自动打开浏览器 → 点击授权 → token 保存到 tokens.json
```

### 获取 token（脚本调用）
```bash
TOKEN=$(bash plugins/feishu-auth/get-token.sh)
curl -H "Authorization: Bearer $TOKEN" https://open.feishu.cn/open-apis/wiki/v2/spaces
```

### Token 生命周期
- `access_token`: 2 小时（自动刷新）
- `refresh_token`: 30 天（过期需重新 `setup.sh`）

## 文件说明

| 文件 | 说明 |
|------|------|
| `setup.sh` | 一次性 OAuth 授权流程 |
| `get-token.sh` | 获取有效 token（自动刷新） |
| `callback-server.js` | 临时回调服务器（setup.sh 内部使用） |
| `tokens.json` | token 存储（gitignored） |
