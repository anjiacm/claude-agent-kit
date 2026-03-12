#!/usr/bin/env node
// 飞书 OAuth 回调接收服务器
// 接收 keys.artux.ai Worker relay 传来的 token，存入 tokens.json

const http = require('http');
const url = require('url');
const fs = require('fs');
const path = require('path');

const PORT = process.env.FEISHU_CALLBACK_PORT || 9876;
const TOKENS_FILE = path.join(__dirname, 'tokens.json');

const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);

  if (parsed.pathname === '/callback') {
    const { token, refresh_token, expires_in, refresh_expires_in, user, state, error } = parsed.query;

    // Worker 传来的错误
    if (error) {
      res.writeHead(400, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(`<html><body style="font-family:sans-serif;text-align:center;padding:60px">
        <h1 style="color:#e74c3c">Authorization Failed</h1>
        <p>${error}</p>
      </body></html>`);
      console.error(JSON.stringify({ success: false, error }));
      setTimeout(() => { server.close(); process.exit(1); }, 1000);
      return;
    }

    if (!token) {
      res.writeHead(400, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end('<h2>Missing token in callback</h2>');
      setTimeout(() => { server.close(); process.exit(1); }, 1000);
      return;
    }

    // 解析用户信息
    let userInfo = {};
    if (user) {
      try {
        const decoded = Buffer.from(user, 'base64').toString('utf8');
        userInfo = JSON.parse(decoded);
      } catch (e) { /* ignore */ }
    }

    // 存储 token
    const expiresIn = parseInt(expires_in) || 7200;
    const refreshExpiresIn = parseInt(refresh_expires_in) || 604800;
    const tokens = {
      access_token: token,
      refresh_token: refresh_token || '',
      expires_at: Date.now() + expiresIn * 1000,
      refresh_expires_at: Date.now() + refreshExpiresIn * 1000,
      user: userInfo,
      created_at: new Date().toISOString()
    };

    fs.writeFileSync(TOKENS_FILE, JSON.stringify(tokens, null, 2));

    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<html><body style="font-family:sans-serif;text-align:center;padding:60px">
      <h1 style="color:#2ecc71">Authorization Successful</h1>
      <p>Welcome, ${userInfo.name || 'user'}!</p>
      <p>user_access_token obtained. You can close this page.</p>
      <p style="color:#999">Token expires in ${Math.round(expiresIn / 3600)}h,
      refresh token expires in ${Math.round(refreshExpiresIn / 86400)}d</p>
    </body></html>`);

    console.log(JSON.stringify({ success: true, user: userInfo.name, expires_in: expiresIn }));
    setTimeout(() => { server.close(); process.exit(0); }, 1000);
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

server.listen(PORT, () => {
  console.error(`Callback server listening on http://localhost:${PORT}/callback`);
});

// 5 分钟超时自动关闭
setTimeout(() => {
  console.error('Timeout: no callback received in 5 minutes');
  server.close();
  process.exit(1);
}, 300000);
