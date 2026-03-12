const express = require('express');
const { WebSocketServer } = require('ws');
const http = require('http');
const path = require('path');
const fs = require('fs');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

const PORT = process.env.DASHBOARD_PORT || 7890;

// ─── State ───
const state = {
  servers: {},
  groups: {},
  workers: {},
  workerIdCounter: 0,
  claudeStatus: 'idle',
  operation: null,
  progress: null,
};
let pendingMessages = [];
const history = [];
let historyIdCounter = 0;
const HISTORY_MAX = 100;
const wsClients = new Set();

// ─── Middleware ───
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// ─── WebSocket ───
wss.on('connection', (ws) => {
  wsClients.add(ws);
  const activeWorkers = {};
  for (const [id, w] of Object.entries(state.workers)) {
    if (w.state === 'walking' || w.state === 'working') {
      activeWorkers[id] = w;
    }
  }
  const filteredState = { ...state, workers: activeWorkers };
  ws.send(JSON.stringify({ type: 'full_state', data: filteredState }));

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw);
      if (msg.type === 'user_message' && msg.data) {
        if (msg.data.type === 'cancel_task' && msg.data.workerId) {
          const w = state.workers[msg.data.workerId];
          if (w && (w.state === 'walking' || w.state === 'working')) {
            w.state = 'finished';
            w.result = 'cancelled';
            w.finishTime = Date.now();
            if (state.servers[w.target]) state.servers[w.target]._active = false;
            broadcast({ type: 'worker_done', workerId: w.id, result: 'error' });
            broadcast({ type: 'worker_say', workerId: w.id, text: '已取消' });
          }
        }
        pendingMessages.push({ ...msg.data, timestamp: Date.now() });
      }
    } catch (e) { /* ignore bad messages */ }
  });

  ws.on('close', () => wsClients.delete(ws));
});

function broadcast(payload) {
  const data = JSON.stringify(payload);
  for (const ws of wsClients) {
    if (ws.readyState === 1) ws.send(data);
  }
}

// ─── REST API ───

app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', uptime: process.uptime(), clients: wsClients.size });
});

// Initialize entities (servers/datasets/etc)
app.post('/api/server/init', (req, res) => {
  const servers = Array.isArray(req.body) ? req.body : req.body.servers;
  if (!Array.isArray(servers)) return res.status(400).json({ error: 'servers must be array' });

  state.servers = {};
  state.groups = {};
  for (const s of servers) {
    state.servers[s.alias] = { ...s, metrics: null, _active: false };
    if (!state.groups[s.group]) state.groups[s.group] = [];
    state.groups[s.group].push(s.alias);
  }
  broadcast({ type: 'init_servers', servers });
  res.json({ success: true, count: servers.length });
});

// Update entity status
app.post('/api/server/:alias/status', (req, res) => {
  const { alias } = req.params;
  if (!state.servers[alias]) return res.status(404).json({ error: 'server not found' });
  state.servers[alias].metrics = req.body;
  broadcast({ type: 'server_status', alias, metrics: req.body });
  res.json({ success: true });
});

// Spawn worker
app.post('/api/worker/spawn', (req, res) => {
  const { type, target, label } = req.body;
  if (!type || !target) return res.status(400).json({ error: 'type and target required' });

  state.workerIdCounter++;
  const workerId = `w${state.workerIdCounter}`;
  state.workers[workerId] = {
    id: workerId, type, target, label: label || type,
    state: 'walking', termLines: [], bubble: '',
    startTime: Date.now(),
  };
  if (state.servers[target]) state.servers[target]._active = true;
  broadcast({ type: 'worker_spawn', worker: state.workers[workerId] });
  res.json({ success: true, workerId });
});

// Worker say
app.post('/api/worker/:id/say', (req, res) => {
  const w = state.workers[req.params.id];
  if (!w) return res.status(404).json({ error: 'worker not found' });
  w.bubble = req.body.text || '';
  broadcast({ type: 'worker_say', workerId: w.id, text: w.bubble });
  res.json({ success: true });
});

// Worker terminal write
app.post('/api/worker/:id/term', (req, res) => {
  const w = state.workers[req.params.id];
  if (!w) return res.status(404).json({ error: 'worker not found' });
  const { type: termType, text } = req.body;
  w.termLines.push({ type: termType || 'output', text: text || '' });
  if (w.termLines.length > 200) w.termLines = w.termLines.slice(-100);
  broadcast({ type: 'term_write', workerId: w.id, termType: termType || 'output', text: text || '' });
  res.json({ success: true });
});

// Worker done
app.post('/api/worker/:id/done', (req, res) => {
  const w = state.workers[req.params.id];
  if (!w) return res.status(404).json({ error: 'worker not found' });
  w.state = 'finished';
  w.result = req.body.result || 'success';
  w.finishTime = Date.now();
  const duration = w.startTime ? Math.round((w.finishTime - w.startTime) / 100) / 10 : 0;

  historyIdCounter++;
  const entry = {
    id: `h${historyIdCounter}`,
    workerId: w.id, server: w.target, type: w.type, label: w.label,
    startTime: w.startTime || w.finishTime, endTime: w.finishTime,
    duration, result: w.result,
    termLines: [...w.termLines], summary: req.body.summary || '',
  };
  history.push(entry);
  if (history.length > HISTORY_MAX) history.splice(0, history.length - HISTORY_MAX);

  broadcast({ type: 'worker_done', workerId: w.id, result: w.result });
  broadcast({ type: 'history_add', entry });
  res.json({ success: true });
});

// Worker cancel
app.post('/api/worker/:id/cancel', (req, res) => {
  const w = state.workers[req.params.id];
  if (!w) return res.status(404).json({ error: 'worker not found' });
  w.state = 'finished';
  w.result = 'cancelled';
  w.finishTime = Date.now();
  w.bubble = '已取消';
  if (state.servers[w.target]) state.servers[w.target]._active = false;

  historyIdCounter++;
  const entry = {
    id: `h${historyIdCounter}`,
    workerId: w.id, server: w.target, type: w.type, label: w.label,
    startTime: w.startTime || w.finishTime, endTime: w.finishTime,
    duration: w.startTime ? Math.round((w.finishTime - w.startTime) / 100) / 10 : 0,
    result: 'cancelled', termLines: [...w.termLines], summary: '用户取消',
  };
  history.push(entry);
  if (history.length > HISTORY_MAX) history.splice(0, history.length - HISTORY_MAX);

  broadcast({ type: 'worker_done', workerId: w.id, result: 'error' });
  broadcast({ type: 'worker_say', workerId: w.id, text: '已取消' });
  broadcast({ type: 'history_add', entry });
  res.json({ success: true });
});

// Worker remove
app.post('/api/worker/:id/remove', (req, res) => {
  const w = state.workers[req.params.id];
  if (!w) return res.status(404).json({ error: 'worker not found' });
  w.state = 'walking_back';
  w.finishTime = w.finishTime || Date.now();
  if (state.servers[w.target]) state.servers[w.target]._active = false;
  broadcast({ type: 'worker_remove', workerId: w.id });
  res.json({ success: true });
});

// Operation banner
app.post('/api/operation', (req, res) => {
  state.operation = req.body.description ? req.body : null;
  broadcast({ type: 'operation', description: req.body.description || null, opType: req.body.type || '' });
  res.json({ success: true });
});

// Progress
app.post('/api/progress', (req, res) => {
  state.progress = req.body;
  broadcast({ type: 'progress', ...req.body });
  res.json({ success: true });
});

// Claude status
app.post('/api/claude/status', (req, res) => {
  state.claudeStatus = req.body.status || 'idle';
  broadcast({ type: 'claude_status', status: state.claudeStatus });
  res.json({ success: true });
});

// Get messages (for Claude to poll)
app.get('/api/messages', (_req, res) => {
  const messages = [...pendingMessages];
  pendingMessages = [];
  res.json({ messages });
});

// Post message to queue (for plugins/external scripts)
app.post('/api/messages', (req, res) => {
  const msg = req.body;
  if (!msg || !msg.type) {
    return res.status(400).json({ error: 'message must have a type field' });
  }
  msg.timestamp = msg.timestamp || Date.now();
  pendingMessages.push(msg);
  broadcast({ type: 'external_message', data: msg });
  res.json({ success: true });
});

// Clear messages
app.delete('/api/messages', (_req, res) => {
  pendingMessages = [];
  res.json({ success: true });
});

// ─── Plugin Status (dynamic discovery) ───

function checkPid(pidFile) {
  try {
    const pid = fs.readFileSync(pidFile, 'utf8').trim();
    process.kill(parseInt(pid), 0);
    return { running: true, pid };
  } catch { return { running: false, pid: null }; }
}

function discoverPlugins() {
  const pluginsDir = path.join(__dirname, '..', 'plugins');
  const plugins = [];
  try {
    const dirs = fs.readdirSync(pluginsDir, { withFileTypes: true }).filter(d => d.isDirectory() && !d.name.startsWith('_'));
    for (const d of dirs) {
      const manifestFile = path.join(pluginsDir, d.name, 'PLUGIN.md');
      try {
        const content = fs.readFileSync(manifestFile, 'utf8');
        const fm = content.match(/^---\n([\s\S]*?)\n---/)?.[1] || '';
        const name = fm.match(/name:\s*(.+)/)?.[1]?.trim() || d.name;
        const desc = fm.match(/description:\s*["']?(.+?)["']?\s*$/m)?.[1]?.trim() || '';
        const interval = parseInt(fm.match(/interval:\s*(\d+)/)?.[1] || '0');
        const pidFile = fm.match(/pid_file:\s*(.+)/)?.[1]?.trim() || `/tmp/claude-${d.name}.pid`;
        plugins.push({ name, dirName: d.name, description: desc, interval, pidFile });
      } catch {}
    }
  } catch {}
  return plugins;
}

// Plugin status — all background plugins
app.get('/api/cron/status', (_req, res) => {
  const plugins = discoverPlugins();
  const poll = checkPid('/tmp/claude-dashboard-poll.pid');

  const tasks = plugins.map(p => {
    const status = checkPid(p.pidFile);
    return {
      name: p.name, type: p.dirName, running: status.running,
      pid: status.pid, interval: p.interval,
    };
  });

  tasks.push({ name: 'Dashboard 轮询', type: 'dashboard-poll', running: poll.running, pid: poll.pid, interval: 3 });
  res.json({ tasks });
});

// ─── Knowledge Base API ───

app.get('/api/knowledge', (_req, res) => {
  const knowledgeDir = path.join(__dirname, '..', 'memory', 'knowledge');
  const files = [];
  try {
    const entries = fs.readdirSync(knowledgeDir).filter(f => f.endsWith('.md') && f !== '_index.md');
    for (const f of entries) {
      const stat = fs.statSync(path.join(knowledgeDir, f));
      files.push({ name: f.replace('.md', ''), file: f, lastModified: stat.mtime.toISOString() });
    }
  } catch {}
  res.json({ files });
});

app.get('/api/knowledge/:topic', (req, res) => {
  const knowledgeFile = path.join(__dirname, '..', 'memory', 'knowledge', `${req.params.topic}.md`);
  try {
    const content = fs.readFileSync(knowledgeFile, 'utf8');
    res.json({ topic: req.params.topic, content });
  } catch {
    res.status(404).json({ error: 'knowledge file not found' });
  }
});

// ─── Memory / Skills / History APIs ───

app.get('/api/memory', (_req, res) => {
  const memDir = path.join(__dirname, '..', 'memory');
  const skip = ['_template.md', 'PROJECT_MEMORY.md'];
  const memories = [];

  try {
    const files = fs.readdirSync(memDir).filter(f => f.endsWith('.md') && !skip.includes(f));
    for (const f of files) {
      const alias = f.replace('.md', '');
      const content = fs.readFileSync(path.join(memDir, f), 'utf8');

      const lastProbe = content.match(/\*\*最后探测\*\*:\s*(.+)/)?.[1]?.trim() || null;
      const os = content.match(/\*\*操作系统\*\*:\s*(.+)/)?.[1]?.trim() || null;
      const cpuCores = content.match(/\*\*CPU 核心\*\*:\s*(.+)/)?.[1]?.trim() || null;
      const memTotal = content.match(/\*\*内存总量\*\*:\s*(.+)/)?.[1]?.trim() || null;

      const issueSection = content.match(/## 已知问题[^\n]*\n([\s\S]*?)(?=\n## |$)/)?.[1] || '';
      const issues = issueSection.match(/- \*\*(.+?)\*\*/g)?.map(m => m.replace(/- \*\*|\*\*/g, '')) || [];

      const opHistory = content.match(/## 操作历史[^\n]*\n[\s\S]*?\n\|[\s|:-]+\n([\s\S]*?)(?=\n## |$)/)?.[1] || '';
      const opLines = opHistory.trim().split('\n').filter(l => l.startsWith('|'));
      const lastOp = opLines.length > 0 ? opLines[opLines.length - 1].split('|').filter(Boolean).map(s => s.trim()).slice(0, 2).join(' ') : null;

      memories.push({ alias, lastProbe, os, cpuCores, memTotal, issues, lastOp });
    }
  } catch {}

  res.json({ memories });
});

app.get('/api/memory/:alias', (req, res) => {
  const memFile = path.join(__dirname, '..', 'memory', `${req.params.alias}.md`);
  try {
    const content = fs.readFileSync(memFile, 'utf8');
    res.json({ alias: req.params.alias, content });
  } catch {
    res.status(404).json({ error: 'memory file not found' });
  }
});

app.get('/api/skills', (_req, res) => {
  const skillsDir = path.join(__dirname, '..', 'skills');
  const skills = [];

  try {
    const dirs = fs.readdirSync(skillsDir, { withFileTypes: true }).filter(d => d.isDirectory() && !d.name.startsWith('_'));
    for (const d of dirs) {
      const skillFile = path.join(skillsDir, d.name, 'SKILL.md');
      try {
        const content = fs.readFileSync(skillFile, 'utf8');
        const fm = content.match(/^---\n([\s\S]*?)\n---/)?.[1] || '';
        const name = fm.match(/name:\s*(.+)/)?.[1]?.trim() || d.name;
        const desc = fm.match(/description:\s*(.+)/)?.[1]?.trim() || '';
        skills.push({ name, description: desc.slice(0, 100) });
      } catch {}
    }
  } catch {}

  res.json({ skills });
});

// Plugin list (for Dashboard skills panel)
app.get('/api/plugins', (_req, res) => {
  res.json({ plugins: discoverPlugins() });
});

app.get('/api/history', (req, res) => {
  let results = [...history];
  if (req.query.server) results = results.filter(h => h.server === req.query.server);
  if (req.query.type) results = results.filter(h => h.type === req.query.type);
  results.reverse();
  const limit = parseInt(req.query.limit) || 50;
  results = results.slice(0, limit);
  res.json({ history: results });
});

// ─── Plugin Route Mounting ───
(function mountPluginRoutes() {
  const pluginsDir = path.join(__dirname, '..', 'plugins');
  try {
    const dirs = fs.readdirSync(pluginsDir, { withFileTypes: true }).filter(d => d.isDirectory() && !d.name.startsWith('_'));
    for (const d of dirs) {
      const routesFile = path.join(pluginsDir, d.name, 'routes.js');
      if (fs.existsSync(routesFile)) {
        try {
          const router = require(routesFile);
          app.use(`/api/plugin/${d.name}`, router);
          console.log(`Plugin route mounted: /api/plugin/${d.name}`);
        } catch (e) {
          console.error(`Failed to mount plugin routes for ${d.name}:`, e.message);
        }
      }
    }
  } catch {}
})();

// ─── Worker Auto-Cleanup (every 30s) ───
setInterval(() => {
  const now = Date.now();
  for (const [id, w] of Object.entries(state.workers)) {
    if ((w.state === 'finished' || w.state === 'walking_back') && w.finishTime && (now - w.finishTime > 60000)) {
      delete state.workers[id];
    }
  }
}, 30000);

// ─── Plugin Status Broadcast (every 30s) ───
setInterval(() => {
  const plugins = discoverPlugins();
  const poll = checkPid('/tmp/claude-dashboard-poll.pid');
  const tasks = plugins.map(p => {
    const status = checkPid(p.pidFile);
    return { name: p.name, type: p.dirName, running: status.running, interval: p.interval };
  });
  tasks.push({ name: 'Dashboard 轮询', type: 'dashboard-poll', running: poll.running, interval: 3 });
  broadcast({ type: 'cron_status', tasks });
}, 30000);

// ─── Start ───
server.listen(PORT, () => {
  console.log(`Dashboard server running on http://localhost:${PORT}`);
  console.log(`WebSocket available at ws://localhost:${PORT}/ws`);
});
