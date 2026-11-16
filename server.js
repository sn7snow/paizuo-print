// server.js —— 零依赖，node server.js 运行；由 nginx 反向代理到本服务
//
// 监听方式（二者择一，优先 Unix socket）：
//   · SOCKET_PATH=/run/paizuo/paizuo.sock  →  Unix domain socket，不占用任何 TCP 端口（生产推荐）
//   · 不设 SOCKET_PATH                      →  回退到 127.0.0.1:PORT（仅本机调试用）
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SOCKET_PATH = process.env.SOCKET_PATH || '';   // 优先：unix socket 文件路径
const PORT = process.env.PORT || 3000;               // 回退：本机 TCP 端口（不对外）
const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, 'data');

const FILES = {
  seats: path.join(DATA_DIR, 'seats.txt'),
  tables: path.join(DATA_DIR, 'tables.txt'),
  roster: path.join(DATA_DIR, 'roster.txt'),
  huiyiSeats: path.join(DATA_DIR, 'huiyi-seats.txt'),
  huiyiRoster: path.join(DATA_DIR, 'huiyi-roster.txt'),
  auth: path.join(DATA_DIR, 'auth.json')
};

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.ico': 'image/x-icon'
};

// 初始化目录与数据文件
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
['seats', 'tables', 'roster', 'huiyiSeats', 'huiyiRoster'].forEach(k => {
  if (!fs.existsSync(FILES[k])) fs.writeFileSync(FILES[k], '', 'utf8');
});

// 认证配置 data/auth.json：
// { "salt": "<随机盐>", "admin": "<sha256(salt+密码A)>", "viewer": "<sha256(salt+密码B)>" }
// 均为小写 hex；hash 由登录页计算后提交，服务器只做比对
let authCfg = null;
try {
  const cfg = JSON.parse(fs.readFileSync(FILES.auth, 'utf8'));
  if (cfg && cfg.salt && (cfg.admin || cfg.viewer)) authCfg = cfg;
} catch (e) { /* ignore */ }
if (!authCfg) {
  console.error('[警告] 缺少或无法解析 ' + FILES.auth + '，登录将不可用');
  console.error('       格式：{"salt":"...","admin":"<sha256(salt+密码A)>","viewer":"<sha256(salt+密码B)>"}');
}

// token -> { role, issuedAt, lastSeen }（内存态，进程重启后失效，前端会自动跳回登录页）
// 过期策略：滑动过期 + 绝对上限（可通过环境变量覆盖，便于测试）
const IDLE_TTL_MS = Number(process.env.PAIZUO_IDLE_TTL_MS) || 12 * 3600 * 1000;   // 无操作 12 小时失效
const ABSOLUTE_TTL_MS = Number(process.env.PAIZUO_ABSOLUTE_TTL_MS) || 7 * 24 * 3600 * 1000; // 登录后最长 7 天
const tokens = new Map();
const LOGIN_FAIL_DELAY_MS = 600; // 口令错误时延迟响应，轻度防爆破

// 取 token 信息；已过期则删除并返回 null，未过期刷新 lastSeen（滑动续期）
function getTokenInfo(req) {
  const t = tokens.get(String(req.headers['x-auth-token'] || ''));
  if (!t) return null;
  const now = Date.now();
  if (now - t.issuedAt > ABSOLUTE_TTL_MS || now - t.lastSeen > IDLE_TTL_MS) {
    tokens.delete(req.headers['x-auth-token']);
    return null;
  }
  t.lastSeen = now;
  return t;
}

// 定时清理过期 token，避免 Map 无限膨胀
setInterval(() => {
  const now = Date.now();
  for (const [k, t] of tokens) {
    if (now - t.issuedAt > ABSOLUTE_TTL_MS || now - t.lastSeen > IDLE_TTL_MS) tokens.delete(k);
  }
}, 10 * 60 * 1000).unref();

function readText(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch (e) { return ''; }
}

function send(res, status, data, type) {
  let body;
  const ct = type || 'application/json; charset=utf-8';
  if (Buffer.isBuffer(data)) body = data;
  else if (typeof data === 'string') body = Buffer.from(data, 'utf8');
  else body = Buffer.from(JSON.stringify(data), 'utf8');
  res.writeHead(status, { 'Content-Type': ct, 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise(resolve => {
    let buf = '';
    req.on('data', c => {
      buf += c;
      if (buf.length > 2e6) req.destroy();
    });
    req.on('end', () => {
      try { resolve(JSON.parse(buf || '{}')); } catch (e) { resolve({}); }
    });
    req.on('error', () => resolve({}));
  });
}

// 从请求头取 token 并返回角色，未登录/已过期返回 null
function getRole(req) {
  const t = getTokenInfo(req);
  return t ? t.role : null;
}

// 数据/保存接口统一入口校验；校验失败时已直接响应
function requireAuth(req, res) {
  const role = getRole(req);
  if (!role) {
    send(res, 401, { ok: false, msg: '未登录或登录已失效' });
    return null;
  }
  return role;
}

// 静态服务不允许直接读到的文件（数据、凭据、配置、源码）
const DENY_PATHS = new Set([
  '/server.js', '/nginx.conf', '/nginx-site.conf', '/credentials.txt', '/auth.json'
]);
function isDenied(pathname) {
  return pathname === '/data' || pathname.startsWith('/data/') || DENY_PATHS.has(pathname);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  let pathname;
  try { pathname = decodeURIComponent(url.pathname); } catch (e) { pathname = '/'; }

  // 登录页取盐（公开）
  if (pathname === '/api/auth-info' && req.method === 'GET') {
    return send(res, 200, { ok: !!authCfg, salt: authCfg ? authCfg.salt : '' });
  }

  // 登录：提交 sha256(salt+password)，不传明文
  if (pathname === '/api/login' && req.method === 'POST') {
    const body = await readBody(req);
    if (!authCfg) return send(res, 200, { ok: false, msg: '服务器未配置口令文件' });
    const hash = String(body.hash || '').toLowerCase().trim();
    let role = null;
    if (authCfg.admin && hash === authCfg.admin) role = 'admin';
    else if (authCfg.viewer && hash === authCfg.viewer) role = 'viewer';
    if (role) {
      const token = crypto.randomBytes(24).toString('hex');
      const now = Date.now();
      tokens.set(token, { role, issuedAt: now, lastSeen: now });
      return send(res, 200, { ok: true, token, role });
    }
    return setTimeout(() => send(res, 200, { ok: false, msg: '口令不正确' }), LOGIN_FAIL_DELAY_MS);
  }

  // 退出登录
  if (pathname === '/api/logout' && req.method === 'POST') {
    const body = await readBody(req);
    tokens.delete(String(body.token || ''));
    return send(res, 200, { ok: true });
  }

  // 排座数据（任何已登录角色可读）
  if (pathname === '/api/data' && req.method === 'GET') {
    const role = requireAuth(req, res);
    if (!role) return;
    return send(res, 200, {
      seats: readText(FILES.seats),
      tables: readText(FILES.tables),
      roster: readText(FILES.roster)
    });
  }

  // 会议餐位数据（任何已登录角色可读）
  if (pathname === '/api/huiyi-data' && req.method === 'GET') {
    const role = requireAuth(req, res);
    if (!role) return;
    return send(res, 200, {
      seats: readText(FILES.huiyiSeats),
      roster: readText(FILES.huiyiRoster)
    });
  }

  // 保存排座数据（仅管理员）
  if (pathname === '/api/save' && req.method === 'POST') {
    const role = requireAuth(req, res);
    if (!role) return;
    if (role !== 'admin') return send(res, 403, { ok: false, msg: '需要管理员权限' });
    const body = await readBody(req);
    try {
      fs.writeFileSync(FILES.seats, String(body.seats || ''), 'utf8');
      fs.writeFileSync(FILES.tables, String(body.tables || ''), 'utf8');
      fs.writeFileSync(FILES.roster, String(body.roster || ''), 'utf8');
      return send(res, 200, { ok: true });
    } catch (e) {
      return send(res, 500, { ok: false, msg: '写入失败：' + e.message });
    }
  }

  // 保存会议餐位配置（仅管理员）
  if (pathname === '/api/huiyi-save' && req.method === 'POST') {
    const role = requireAuth(req, res);
    if (!role) return;
    if (role !== 'admin') return send(res, 403, { ok: false, msg: '需要管理员权限' });
    const body = await readBody(req);
    try {
      fs.writeFileSync(FILES.huiyiSeats, String(body.seats || ''), 'utf8');
      fs.writeFileSync(FILES.huiyiRoster, String(body.roster || ''), 'utf8');
      return send(res, 200, { ok: true });
    } catch (e) {
      return send(res, 500, { ok: false, msg: '写入失败：' + e.message });
    }
  }

  // 静态文件（屏蔽数据目录与敏感文件）
  const rel = pathname === '/' ? '/index.html' : pathname;
  if (isDenied(pathname)) return send(res, 404, 'Not Found', 'text/plain; charset=utf-8');
  const full = path.normalize(path.join(ROOT, rel));
  if (!full.startsWith(ROOT)) return send(res, 403, 'Forbidden', 'text/plain; charset=utf-8');
  if (isDenied('/' + path.relative(ROOT, full).split(path.sep).join('/'))) {
    return send(res, 404, 'Not Found', 'text/plain; charset=utf-8');
  }

  fs.readFile(full, (err, buf) => {
    if (err) return send(res, 404, 'Not Found', 'text/plain; charset=utf-8');
    send(res, 200, buf, MIME[path.extname(full).toLowerCase()] || 'application/octet-stream');
  });
});

// 启动：优先 unix socket（无端口），否则回退本机回环 TCP
function onListenError(err) {
  if (err && err.code === 'EADDRINUSE') {
    console.error('[启动失败] 监听地址已被占用：' + (SOCKET_PATH || ('127.0.0.1:' + PORT)));
    console.error('           若有旧的 node 进程在跑，先停掉它（systemctl stop paizuo / 或旧用户级服务）');
  } else {
    console.error('[启动失败] ' + (err && err.message));
  }
  process.exit(1);
}

if (SOCKET_PATH) {
  // 清理上次异常退出遗留的 socket 文件（systemd RuntimeDirectory 也会清，这里双保险）
  try { fs.unlinkSync(SOCKET_PATH); } catch (e) { /* 不存在则忽略 */ }
  server.on('error', onListenError);
  server.listen(SOCKET_PATH, () => {
    // nginx 以 www-data 运行，需要能连上这个 socket
    try { fs.chmodSync(SOCKET_PATH, 0o666); } catch (e) {
      console.error('[警告] 无法设置 socket 权限，nginx 可能连不上：' + e.message);
    }
    console.log('排座服务已启动：unix:' + SOCKET_PATH + '（不占用 TCP 端口，仅 nginx 可访问）');
    console.log('口令文件：' + FILES.auth + (authCfg ? '' : '（缺失！）'));
  });
} else {
  server.on('error', onListenError);
  server.listen(PORT, '127.0.0.1', () => {
    console.log('排座服务已启动：http://127.0.0.1:' + PORT + '（仅本机，外部须经 nginx 访问）');
    console.log('口令文件：' + FILES.auth + (authCfg ? '' : '（缺失！）'));
  });
}
