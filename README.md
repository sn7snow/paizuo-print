# 排座系统 · 部署与运维手册

> 面向系统操作者。所有命令均在服务器上以 root/sudo 执行（另有说明除外）。
> 更新日期：2026-11-16

---

## 1. 系统概览

```
员工浏览器 ──HTTP──▶ nginx :80 ──301──▶ HTTPS :443 ──┐
                                                     │ location /api/
                                     /etc/nginx/snippets/paizuo-locations.conf
                                                     │ proxy_pass (unix socket)
                                            /run/paizuo/paizuo.sock
                                                     ▼
                                        node server.js（服务名 paizuo）
                                                     ▼
                                    /var/www/html/data/*.txt（业务数据）
```

| 项目 | 值 |
|---|---|
| 对外端口 | 80（跳转）、443（HTTPS）；node **不占任何 TCP 端口** |
| 防火墙 | 只需放行 80、443/tcp |
| 服务 | `paizuo.service`（node），运行用户 `paizuo`（nologin 系统用户） |
| 登录 | 双口令：密码 A=管理员（可改写数据）、密码 B=访客（只读） |
| 会话 | 无操作 12 小时失效，登录后最长 7 天；**node 重启后全员掉线** |

---

## 2. 文件清单

### `/home/html`（更新源，手工维护，全部文件都要拷贝到服务器）

| 文件 | 说明 |
|---|---|
| `login.html / index.html / huiyi.html / print-zhuoqian.html` | 4 个页面 |
| `server.js` | 后端服务 |
| `deploy.sh` | 一键部署脚本 |
| `make-cert.sh` | 证书生成/续签脚本 |
| `nginx-site.conf` | nginx 配置（纯 HTTP 版） |
| `nginx-tls.conf` | nginx 配置（HTTPS 版） |
| `nginx-locations.conf` | nginx 公共 location 片段 |
| `data/auth.json` | 登录凭据（换密码时才需要） |

### 部署后服务器上的关键位置

| 位置 | 说明 |
|---|---|
| `/var/www/html/` | 4 页面 + server.js（root:root 644） |
| `/var/www/html/data/` | 业务数据 `*.txt` + `auth.json`（paizuo:paizuo，750/640） |
| `/etc/nginx/sites-available/paizuo` | 站点配置（改动前自动备份为 `.bak`） |
| `/etc/nginx/snippets/paizuo-locations.conf` | 公共 location（80/443 共用一份） |
| `/etc/nginx/ssl/` | `paizuo-chain.crt`、`paizuo.key`（nginx 引用） |
| `/root/paizuo-pki/` | 根 CA 私钥与证书（**目录 700，勿外传**） |
| `/etc/systemd/system/paizuo.service` | 服务单元 |
| `/run/paizuo/paizuo.sock` | node 监听的 unix socket（运行时自动创建/清理） |

> ⚠️ `credentials.txt`（口令明文）只保存在你自己的电脑上，**不要放到服务器**。

---

## 3. 首次部署（新服务器）

### 3.1 准备环境

```bash
apt update && apt install -y nginx nodejs openssl
```

### 3.2 放置文件

把第 2 节列出的全部文件放到服务器 `/home/html/`（保持目录结构，`data/auth.json` 必须就位，否则登录不可用）。

### 3.3 一键部署

```bash
sudo bash /home/html/deploy.sh --tls
```

脚本自动完成：创建运行用户 → 部署文件 → 引导登录凭据 → 生成根 CA 与证书（自动探测本机 IP）→ 安装 nginx 配置 → 安装 systemd 服务 → 重启 → 自检。**全部 ✓ 即部署成功。**

防火墙（如启用了 ufw）：

```bash
ufw allow 80/tcp && ufw allow 443/tcp
```

### 3.4 分发根证书（每台员工电脑一次）

1. 从服务器取 `/root/paizuo-pki/root/paizuo-root-ca.crt`，同时抄下脚本输出的 SHA-256 指纹供员工核对；
2. 员工双击安装 → 存入"受信任的根证书颁发机构"；
3. 之后浏览器访问 `https://<服务器IP>/` 不再有证书警告（不装也能用，每次需点"继续访问"）。

---

## 4. 日常更新

| 场景 | 操作 | 影响 |
|---|---|---|
| 改了页面（html） | 新文件覆盖 `/home/html/` → `sudo bash deploy.sh` | 不重启，在线用户不掉线 |
| 改了 server.js | 同上 | 自动重启服务，**全员需重新登录** |
| 改了 nginx 配置源文件 | 同上 → `sudo bash deploy.sh --nginx`（或 `--tls`） | reload，不掉线 |
| 换登录密码 | 见 4.1 | 重启服务，全员重新登录 |

> 业务数据（名单、排座结果）平时直接在网页上保存即可，存在服务器 `/var/www/html/data/*.txt`；部署脚本**永不覆盖**这些文件。

### 4.1 更换登录口令

在任意装了 node 的机器上生成新凭据（把两个密码换成新值）：

```bash
node -e '
const c=require("crypto");
const salt=c.randomBytes(16).toString("hex");
const sha=p=>c.createHash("sha256").update(salt+p).digest("hex");
console.log(JSON.stringify({salt, admin:sha("新的密码A"), viewer:sha("新的密码B")},null,2));
'
```

把输出保存为 `/home/html/data/auth.json`，然后：

```bash
sudo bash /home/html/deploy.sh --auth
```

（`--auth` 会覆盖服务器上的 auth.json 并重启服务。）

---

## 5. 证书运维

| 场景 | 命令 | 说明 |
|---|---|---|
| 查看到期时间 | 部署自检会打印；或 `openssl x509 -in /etc/nginx/ssl/paizuo.crt -noout -enddate` | 默认有效期 730 天 |
| 到期续签 | `sudo bash deploy.sh --tls --renew-cert` | 根 CA 不变，**员工无需重装根证书** |
| 服务器换了 IP | `sudo bash deploy.sh --tls --ip <新IP>` | 自动检测 IP 变化并重签 |
| 追加域名访问 | `sudo bash /home/html/make-cert.sh --dns <域名>` 后 `deploy.sh --nginx` | SAN 中会加入该域名 |
| 重建根 CA | `sudo bash /home/html/make-cert.sh --force` | ⚠ 所有装过旧根证书的员工都要重装 |

---

## 6. 日常运维命令

```bash
systemctl status paizuo nginx        # 服务状态
journalctl -u paizuo -n 50           # node 最近 50 行日志
journalctl -u paizuo -f              # 实时日志
systemctl restart paizuo             # 重启 node（⚠ 全员掉线）
systemctl reload nginx               # 重载 nginx（不掉线）
nginx -t                             # 检查 nginx 配置语法
```

**备份**（建议定期执行，如每周）：

```bash
tar czf /root/paizuo-backup-$(date +%F).tar.gz \
    /var/www/html/data /etc/nginx/ssl /root/paizuo-pki /etc/nginx/sites-available/paizuo
```

> `/root/paizuo-pki` 里是根 CA 私钥，备份文件同样要妥善保管，丢失 = 无法续签证书。

---

## 7. 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 页面打不开，`/api/*` 返回 502 | node 进程挂了 | `journalctl -u paizuo -n 30` 看原因，`systemctl restart paizuo` |
| 提示"未登录或登录已失效" | 12 小时无操作 / 超过 7 天 / node 重启过 | 重新登录即可 |
| 浏览器提示证书风险 | 员工没装根证书；或服务器换了 IP 而证书未更新 | 装根证书；或 `deploy.sh --tls --ip <新IP>` 重签 |
| 改了页面"没生效" | 浏览器缓存 | Ctrl+F5 强刷；仍不行检查 `/home/html` 的文件是否已上传并重跑 deploy.sh |
| `nginx -t` 失败 | 配置语法错误；或别的站点也声明了 `default_server` | 看报错行；deploy.sh 会自动回滚到 `.bak` |
| 部署自检有 ✗ | 按 ✗ 提示逐条排查 | 先看 `journalctl -u paizuo -n 30` |
| `ss -tlnp | grep 3000` 有输出 | 遗留了旧的用户级 node 服务 | `systemctl --user disable --now node_html_service` 后删除其单元文件 |
| 端口 3000 还能访问旧页面 | 同上 | 同上（新版架构下 3000 不应有任何监听） |

---

## 8. 安全要点

- **双口令**：密码 A 拥有改写权限，密码 B 只读。登录时客户端先做 SHA-256 加盐哈希再提交，网络上传的不是明文。
- **数据面**：`/var/www/html/data/`、`server.js`、`auth.json` 等被 nginx 与 node 双层屏蔽，无法通过 URL 直读。
- **最小权限**：node 以专用系统用户 `paizuo`（nologin）运行，systemd 加固（NoNewPrivileges / ProtectSystem / ProtectHome / PrivateTmp）。
- **密钥保管**：`/root/paizuo-pki/`（700）是信任根，`credentials.txt` 只留本地，两者都不要外传。
- **边界提醒**：本系统按"内网、非敏感数据"设计。若未来迁到公网，需重新评估：改用正式 CA 证书、增加登录失败锁定、考虑传输之外的存储加密与访问审计。

---

## 9. 命令速查

### deploy.sh

```bash
sudo bash /home/html/deploy.sh                  # 最小部署（文件+服务，不动 nginx）
sudo bash /home/html/deploy.sh --nginx          # + 纯 HTTP 站点配置
sudo bash /home/html/deploy.sh --tls            # + HTTPS（推荐，自动签证书）
sudo bash /home/html/deploy.sh --tls --ip 10.1.2.3   # 指定证书 IP
sudo bash /home/html/deploy.sh --tls --renew-cert    # 强制续签证书
sudo bash /home/html/deploy.sh --service        # 强制重装 systemd 单元
sudo bash /home/html/deploy.sh --auth           # 更新登录凭据（换密码后）
```

> 重复运行是幂等的：文件没变跳过、证书有效复用、服务无需更新就不重启。

### make-cert.sh（一般通过 deploy.sh --tls 间接调用，也可单独用）

```bash
sudo bash /home/html/make-cert.sh               # 自动探测 IP，建 CA + 签发 + 安装
sudo bash /home/html/make-cert.sh --ip 10.1.2.3 # 指定 IP
sudo bash /home/html/make-cert.sh --renew       # 只重签服务器证书
sudo bash /home/html/make-cert.sh --force       # 重建根 CA（作废所有已下发证书）
sudo bash /home/html/make-cert.sh --help        # 完整参数
```
