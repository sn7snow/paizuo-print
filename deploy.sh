#!/usr/bin/env bash
# ============================================================
# 排座系统一键布置脚本
#
# 用法（在服务器上执行）：
#   sudo bash /home/html/deploy.sh                 # 首次最小部署（HTTP）
#   sudo bash /home/html/deploy.sh --nginx         # 部署 + 换成 nginx 站点配置（仍为 HTTP）
#   sudo bash /home/html/deploy.sh --tls           # 部署 + 自建证书 + 启用 HTTPS（推荐）
#   sudo bash /home/html/deploy.sh --tls --ip 10.1.2.3   # 指定员工访问用的 IP
#
# 可选参数：
#   --nginx         安装 nginx 站点配置 + snippet（纯 HTTP 版）
#   --tls           启用 HTTPS：自动生成/复用证书并安装 nginx-tls.conf（隐含 --nginx）
#   --ip <addr>     配合 --tls：证书绑定的 IP；不填则自动探测本机 IP
#   --renew-cert    配合 --tls：强制重新签发服务器证书（根 CA 不动，员工无需重装根证书）
#   --service       强制重装 systemd 服务单元（内嵌于本脚本，无需拷贝 paizuo.service）
#   --auth          同时更新 data/auth.json（仅在重新生成过登录密码时使用！）
#
# 服务运行用户：默认专用系统用户 paizuo（最小权限，与 nginx 的 www-data 彻底分离）。
# 想改回 www-data，改下面 SERVICE_USER 一个变量即可。
#
# 前置条件（脚本会检查，缺失时直接给出安装命令）：
#   · 已安装 nginx（apt install -y nginx）
#   · 已安装 node（apt install -y nodejs，且 command -v node 有输出）
#   · /home/html 下已放好：4 个页面 + server.js（必需），data/auth.json（首次部署必需）
#     --nginx / --tls 还需要：nginx-locations.conf + nginx-site.conf（或 nginx-tls.conf）
#     --tls 还需要：make-cert.sh、openssl（apt install -y openssl）
#
# 行为约定：
#   · 只同步白名单文件（4 个页面 + server.js），存在才拷，内容没变自动跳过
#   · server.js 有变化才重启 paizuo（纯 HTML 更新不重启，在线用户不掉线）
#   · 业务数据 /var/www/html/data/*.txt 永不覆盖（数据只在服务器上维护）
#   · 证书、脚本、data/ 都不进入部署目录（只放 4 页 + server.js）
#   · node 跑在 Unix socket /run/paizuo/paizuo.sock 上，不占任何 TCP 端口
#     （外部只能经 nginx 80/443 访问，nginx 用 unix socket 反代 /api/）
#   · 部署后自动自检：页面 / 静态 / 数据文件屏蔽 / 未登录 401 / socket 就绪 / 3000 无残留
# ============================================================
set -euo pipefail

SRC=/home/html          # 你放更新文件的位置
DST=/var/www/html       # 部署目标
SRV=paizuo              # systemd 服务名
SERVICE_USER=paizuo     # node 运行用户：专用最小权限账号（脚本自动创建）；可改回 www-data

# 部署白名单：存在才拷贝
FILES=(login.html index.html huiyi.html print-zhuoqian.html server.js)

DO_NGINX=0; DO_SERVICE=0; DO_AUTH=0
DO_TLS=0; DO_RENEW=0; CERT_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nginx)      DO_NGINX=1; shift ;;
    --tls)        DO_TLS=1; DO_NGINX=1; shift ;;
    --ip)         CERT_IP="${2:-}"; [[ -n "$CERT_IP" ]] || { echo "✗ --ip 需要一个地址"; exit 1; }; shift 2 ;;
    --renew-cert) DO_RENEW=1; DO_TLS=1; DO_NGINX=1; shift ;;
    --service)    DO_SERVICE=1; shift ;;
    --auth)       DO_AUTH=1; shift ;;
    -h|--help)    awk 'NR>2 && /^# =====/{exit} NR>2' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（可用：--nginx --tls [--ip 地址] [--renew-cert] --service --auth）"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "✗ 请用 root 运行：sudo bash $0 $*"
  exit 1
fi

[[ -d $SRC ]] || { echo "✗ 源目录 $SRC 不存在"; exit 1; }

# ---------- 前置检查（新服务器常见缺件）----------
if ! command -v node >/dev/null 2>&1; then
  echo "✗ 未安装 node。请先执行：apt install -y nodejs"
  exit 1
fi
if ! command -v nginx >/dev/null 2>&1; then
  echo "✗ 未安装 nginx。请先执行：apt install -y nginx"
  exit 1
fi
if [[ $DO_TLS -eq 1 ]]; then
  command -v openssl >/dev/null 2>&1 || { echo "✗ 未安装 openssl。请先执行：apt install -y openssl"; exit 1; }
  [[ -f "$SRC/make-cert.sh" ]] || { echo "✗ 缺少 $SRC/make-cert.sh（--tls 需要它生成证书）"; exit 1; }
fi
if [[ $DO_NGINX -eq 1 ]]; then
  [[ -f "$SRC/nginx-locations.conf" ]] || { echo "✗ 缺少 $SRC/nginx-locations.conf"; exit 1; }
  if [[ $DO_TLS -eq 1 ]]; then
    [[ -f "$SRC/nginx-tls.conf" ]] || { echo "✗ 缺少 $SRC/nginx-tls.conf"; exit 1; }
  else
    [[ -f "$SRC/nginx-site.conf" ]] || { echo "✗ 缺少 $SRC/nginx-site.conf"; exit 1; }
  fi
fi

# 新服务器可能还没有 web 根目录，自动创建
if [[ ! -d $DST ]]; then
  install -d -m 755 -o root -g root "$DST"
  echo "✓ 已创建部署目录 $DST"
fi

# 提前确保运行用户存在（--auth 和 data 目录属主都依赖它）
ensure_service_user() {
  id "$SERVICE_USER" >/dev/null 2>&1 && return 0
  if [[ "$SERVICE_USER" == "www-data" ]]; then
    echo "✗ 系统用户 www-data 不存在，环境异常"; exit 1
  fi
  useradd -r -s /usr/sbin/nologin -d /nonexistent "$SERVICE_USER"
  echo "✓ 已创建系统用户 $SERVICE_USER（nologin，仅用于运行 node）"
}
ensure_service_user

need_restart=0
copied=0; skipped=0

echo "=== ① 同步文件 $SRC → $DST ==="
for f in "${FILES[@]}"; do
  [[ -f "$SRC/$f" ]] || { echo "· $f（源目录中不存在，跳过）"; continue; }
  if [[ -f "$DST/$f" ]] && cmp -s "$SRC/$f" "$DST/$f"; then
    echo "· $f 无变化，跳过"
    skipped=$((skipped+1))
    continue
  fi
  install -m 644 -o root -g root "$SRC/$f" "$DST/$f"
  echo "✓ 已部署 $f"
  copied=$((copied+1))
  [[ "$f" == "server.js" ]] && need_restart=1
done

# 首次部署时确保 data 目录存在且属主正确（不覆盖里面任何文件）
if [[ ! -d "$DST/data" ]]; then
  install -d -m 750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DST/data"
  echo "✓ 已创建 $DST/data（750 $SERVICE_USER）"
fi

# 凭据：--auth 强制覆盖；否则首次部署自动引导（只补缺失，绝不覆盖已有密码）
if [[ $DO_AUTH -eq 1 ]]; then
  if [[ -f "$SRC/data/auth.json" ]]; then
    install -m 640 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SRC/data/auth.json" "$DST/data/auth.json"
    echo "✓ 已更新 $DST/data/auth.json（新密码生效需重启服务）"
    need_restart=1
  else
    echo "· $SRC/data/auth.json 不存在，跳过凭据更新"
  fi
elif [[ ! -f "$DST/data/auth.json" ]]; then
  if [[ -f "$SRC/data/auth.json" ]]; then
    install -m 640 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SRC/data/auth.json" "$DST/data/auth.json"
    echo "✓ 首次部署：已引导登录凭据 $DST/data/auth.json"
    need_restart=1
  else
    echo "⚠ 警告：$DST/data/auth.json 缺失，源目录也没有 —— 登录将不可用！"
    echo "        请把 auth.json 放到 $SRC/data/ 后重跑本脚本"
  fi
fi

# ---------- 可选：HTTPS 证书（必须先于 nginx 配置，否则 nginx -t 会因缺证书失败）----------
if [[ $DO_TLS -eq 1 ]]; then
  echo "=== ①' 准备 HTTPS 证书 ==="
  cert_args=()
  if [[ -n "$CERT_IP" ]]; then cert_args+=(--ip "$CERT_IP"); fi
  if [[ $DO_RENEW -eq 1 ]]; then cert_args+=(--renew); fi
  if ! bash "$SRC/make-cert.sh" ${cert_args[@]+"${cert_args[@]}"}; then
    echo "✗ 证书生成失败，已中止（nginx 配置未改动，服务不受影响）"
    exit 1
  fi
fi

# nginx reload 是平滑重载：旧 worker 可能还在 accept 几秒，立即自检会撞上过渡期误报。
# 轮询等待"新配置真正接管"后再自检。
wait_nginx_ready() {
  local i url want code
  if [[ $DO_TLS -eq 1 ]]; then
    url="http://127.0.0.1/"; want="301"               # 80 变 301 ⇒ TLS 配置已接管
  else
    url="http://127.0.0.1/api/auth-info"; want="200"  # 反代链路通 ⇒ paizuo 配置生效（默认站点下是 404）
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null) || code="000"
    if [[ "$code" == "$want" ]]; then return 0; fi
    sleep 1
  done
  return 1
}

# ---------- 可选：安装 nginx 站点配置 ----------
if [[ $DO_NGINX -eq 1 ]]; then
  echo "=== ①'' 安装 nginx 站点配置 ==="
  if [[ $DO_TLS -eq 1 ]]; then
    conf_src="$SRC/nginx-tls.conf"; conf_kind="HTTPS 版（80 → 301 跳 443）"
  else
    conf_src="$SRC/nginx-site.conf"; conf_kind="HTTP 版（仅 80）"
  fi

  # 新装 nginx 自带 default 站点，与本配置的 default_server 冲突会导致 nginx 起不来
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    echo "✓ 已停用 nginx 默认站点软链（sites-available/default 仍保留）"
  fi

  install -d -m 755 /etc/nginx/snippets
  install -m 644 -o root -g root "$SRC/nginx-locations.conf" /etc/nginx/snippets/paizuo-locations.conf

  # 改动前备份，nginx -t 不通过时自动回滚，避免把线上打挂
  bak=/etc/nginx/sites-available/paizuo.bak
  rm -f "$bak"
  if [[ -f /etc/nginx/sites-available/paizuo ]] && ! cmp -s "$conf_src" /etc/nginx/sites-available/paizuo; then
    cp /etc/nginx/sites-available/paizuo "$bak"
  fi

  install -m 644 -o root -g root "$conf_src" /etc/nginx/sites-available/paizuo
  ln -sfn /etc/nginx/sites-available/paizuo /etc/nginx/sites-enabled/paizuo

  # 其它站点若也声明了 default_server，会和本配置撞车（nginx -t 报 duplicate default server）
  for f in /etc/nginx/sites-enabled/*; do
    [[ -e "$f" ]] || continue
    if [[ "$(basename "$f")" == "paizuo" ]]; then continue; fi
    if grep -qs 'default_server' "$f"; then
      echo "⚠ 注意：$(basename "$f") 里也声明了 default_server，可能与 paizuo 冲突"
      echo "   如 nginx -t 报 duplicate default server，请停用它：rm /etc/nginx/sites-enabled/$(basename "$f")"
    fi
  done

  if nginx -t; then
    systemctl reload nginx
    if wait_nginx_ready; then
      echo "✓ nginx 配置已安装（$conf_kind）并平滑重载（新配置已接管）"
    else
      echo "⚠ nginx 已重载，但 10 秒内未确认新配置接管；自检将继续验证，失败项可稍后重跑本脚本"
    fi
  else
    if [[ -f "$bak" ]]; then
      cp "$bak" /etc/nginx/sites-available/paizuo
      echo "✗ nginx -t 未通过，已回滚到上一版配置（新配置留在 $bak 供排查）"
    else
      echo "✗ nginx -t 未通过，请检查 /etc/nginx/sites-available/paizuo"
    fi
    exit 1
  fi
fi

# ---------- systemd 服务（单元内嵌于本脚本，无需拷贝 paizuo.service）----------
install_service() {
  local node_bin
  node_bin=$(command -v node 2>/dev/null || true)
  [[ -n "$node_bin" ]] || { echo "✗ 未找到 node，请先安装系统级 node（apt install nodejs）"; exit 1; }
  case "$node_bin" in
    /home/*) echo "⚠ node 位于用户目录 $node_bin，服务用户可能无权访问，建议改用系统级 node" ;;
  esac

  cat > /etc/systemd/system/$SRV.service <<EOF
[Unit]
Description=Node.js seat layout service (paizuo)
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=/var/www/html

# 监听 Unix domain socket（不占用 TCP 端口）；目录由 systemd 创建、停止时自动清理
Environment=SOCKET_PATH=/run/$SRV/$SRV.sock
RuntimeDirectory=$SRV
RuntimeDirectoryMode=0755

ExecStart=$node_bin /var/www/html/server.js
Restart=on-failure
RestartSec=3

# ---- 最小权限加固 ----
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  chown root:root /etc/systemd/system/$SRV.service
  chmod 644 /etc/systemd/system/$SRV.service

  # data 目录属主与运行用户对齐（只改属主与权限位，不碰文件内容）
  chown "$SERVICE_USER:$SERVICE_USER" "$DST/data"
  chmod 750 "$DST/data"
  find "$DST/data" -type f -exec chown "$SERVICE_USER:$SERVICE_USER" {} +
  find "$DST/data" -type f -exec chmod 640 {} +

  systemctl daemon-reload
  systemctl enable $SRV >/dev/null 2>&1 || true
  echo "✓ systemd 服务已安装（运行用户：$SERVICE_USER，开机自启，含权限加固）"
  need_restart=1
}

# 是否需要安装/重装：--service 强制；单元缺失；或运行用户与 SERVICE_USER 不一致
# （systemctl show 取不到时回退到读单元文件里的 User=，保证重复运行不无谓重启）
unit_user=""
if [[ -f /etc/systemd/system/$SRV.service ]]; then
  unit_user=$(awk -F= '/^User=/{print $2; exit}' /etc/systemd/system/$SRV.service)
fi
cur_svc_user=$(systemctl show $SRV -p User --value 2>/dev/null || true)

need_unit=0
if [[ $DO_SERVICE -eq 1 ]]; then
  need_unit=1
elif [[ ! -f /etc/systemd/system/$SRV.service ]]; then
  need_unit=1
elif ! grep -q '^Environment=SOCKET_PATH=' /etc/systemd/system/$SRV.service; then
  need_unit=1   # 旧版单元（TCP 端口模式）→ 升级为 unix socket 模式
elif [[ -n "$cur_svc_user" && "$cur_svc_user" != "$SERVICE_USER" ]]; then
  need_unit=1
elif [[ -z "$cur_svc_user" && "$unit_user" != "$SERVICE_USER" ]]; then
  need_unit=1
fi

if [[ $need_unit -eq 1 ]]; then
  install_service
else
  echo "· systemd 服务无需更新（运行用户：${cur_svc_user:-$SERVICE_USER}）"
fi

# 检查是否还残留用户级 systemd 服务（如 node_html_service.service）
for d in /home/* /root; do
  [[ -d "$d" ]] || continue
  if [[ -f "$d/.config/systemd/user/node_html_service.service" ]]; then
    owner=$(stat -c %U "$d")
    echo "⚠ 发现遗留的用户级服务：$d/.config/systemd/user/node_html_service.service（属主 $owner）"
    echo "   它仍会占用 3000 端口并对外提供旧版本服务，容易被误认为\"改了没生效\"。"
    echo "   建议以 $owner 身份执行后停用："
    echo "     systemctl --user disable --now node_html_service"
    echo "     rm ~/.config/systemd/user/node_html_service.service"
    echo "     sudo loginctl disable-linger $owner   # 如无其它用户级常驻服务"
  fi
done

# server.js / 凭据 / 服务单元有变化才重启，避免无谓打断在线用户
if [[ $need_restart -eq 1 ]]; then
  echo "=== ② 重启服务 ==="
  systemctl restart $SRV
  echo "✓ $SRV 已重启（所有登录会话已失效，需重新登录）"
else
  echo "=== ② 无需重启（本次没有 server.js 变化）==="
fi

echo "=== ③ 部署后自检 ==="
fail=0

check() {  # check <url> <期望状态码> <说明>
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${CURL_TLS[@]+"${CURL_TLS[@]}"} "$1") || code="000"
  if [[ "$code" == "$2" ]]; then
    echo "✓ $3 → $code"
  else
    echo "✗ $3 → $code（期望 $2）"
    fail=1
  fi
}

# nginx 站点配置是否已就位（首次不带 --nginx/--tls 时不存在，经 nginx 的检查无从谈起）
NGINX_READY=0
if [[ -e /etc/nginx/sites-enabled/$SRV ]]; then NGINX_READY=1; fi

# 探测 nginx 当前实际入口是 HTTP 还是 HTTPS，以服务器真实状态为准：
# 上次部署启用了 TLS、本次没带 --tls 时，80 已经是 301，若仍按 HTTP 判会全部误报
TLS_ACTIVE=$DO_TLS
if [[ $NGINX_READY -eq 1 && $TLS_ACTIVE -eq 0 ]]; then
  probe=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1/ 2>/dev/null) || probe="000"
  if [[ "$probe" == "301" ]]; then
    TLS_ACTIVE=1
    echo "ℹ 检测到 nginx 当前已是 HTTPS 入口（80 → 301），本次自检按 HTTPS 执行；要重签证书请加 --tls"
  fi
fi

if [[ $TLS_ACTIVE -eq 1 ]]; then
  BASE="https://127.0.0.1"
  CURL_TLS=(-k)        # 自检只看服务通不通；证书链另有专门一项校验
else
  BASE="http://127.0.0.1"
  CURL_TLS=()
fi

if [[ $NGINX_READY -eq 0 ]]; then
  echo "⚠ 未安装 nginx 站点配置（sites-enabled/$SRV 不存在），跳过经 nginx 的自检"
  echo "  首次完整部署请运行：sudo bash $0 --tls（推荐）或 --nginx"
else
  if [[ $TLS_ACTIVE -eq 1 ]]; then
    check "http://127.0.0.1/"  301 "80 跳转 HTTPS"
  fi
  check "$BASE/"               200 "登录页"
  check "$BASE/index.html"     200 "静态页面"
  check "$BASE/data/roster.txt" 404 "数据文件屏蔽"
  check "$BASE/api/data"       401 "未登录接口拦截"
  check "$BASE/api/auth-info"  200 "nginx→socket 反代链路"

  # HTTPS 专项：用证书链文件做真实校验（验证 SAN 含 127.0.0.1 且链条完整）
  if [[ $TLS_ACTIVE -eq 1 ]]; then
    chain=/etc/nginx/ssl/paizuo-chain.crt
    if [[ -f "$chain" ]] && curl -s -o /dev/null --fail --max-time 5 --cacert "$chain" "$BASE/" 2>/dev/null; then
      echo "✓ 证书链与 SAN 校验通过（curl --cacert 直连 443）"
    else
      echo "✗ 证书链校验未通过（检查 $chain 与证书里的 IP SAN）"
      fail=1
    fi
    if [[ -f /etc/nginx/ssl/paizuo.crt ]]; then
      echo "ℹ 服务器证书到期：$(openssl x509 -in /etc/nginx/ssl/paizuo.crt -noout -enddate 2>/dev/null | cut -d= -f2)"
    fi
  fi
fi

if systemctl is-active --quiet $SRV; then
  echo "✓ 服务状态：active"
else
  echo "✗ 服务状态：$(systemctl is-active $SRV)"
  fail=1
fi

# node 监听方式：unix socket（不占 TCP 端口）
sock="/run/$SRV/$SRV.sock"
if [[ -S "$sock" ]]; then
  echo "✓ node 监听：unix:$sock（不占用 TCP 端口，仅 nginx 可访问）"
else
  echo "✗ node 监听：未找到 socket $sock（看 journalctl -u $SRV -n 30）"
  fail=1
fi

# 确认旧的 TCP 端口模式已彻底退出
if ss -tln 2>/dev/null | grep -q ':3000 '; then
  echo "⚠ 仍有进程占用 3000 端口（旧服务没停干净，建议查一下）："
  ss -tlnp 2>/dev/null | grep ':3000 ' | sed 's/^/    /' || true
else
  echo "✓ 3000 端口无监听（TCP 端口模式已放弃）"
fi

# 新服务器业务数据为空时提示（server.js 会自动建空文件，页面显示"暂无数据"）
if [[ -d "$DST/data" ]] && ! find "$DST/data" -name '*.txt' -size +0c 2>/dev/null | grep -q .; then
  echo "ℹ 业务数据为空（data/*.txt 都是 0 字节）：需在新服务器重新录入名单，"
  echo "  或从旧服务器拷贝 data/ 下的 *.txt 过来（本脚本不会同步业务数据）"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "=== 部署完成：本次部署 $copied 个文件，跳过 $skipped 个未变化文件 ==="
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ $TLS_ACTIVE -eq 1 ]]; then
    echo "访问地址： https://${host_ip:-<本机IP>}/"
    echo "首次使用：把 /root/paizuo-pki/root/paizuo-root-ca.crt 发给员工安装一次（双击 → 受信任的根证书），"
    echo "          之后浏览器不再提示证书风险；不装也能用，只是每次提示。"
  else
    echo "访问地址： http://${host_ip:-<本机IP>}/"
    echo "想上 HTTPS：sudo bash $0 --tls   （会自动生成证书并切成 443）"
  fi
else
  echo "=== 部署完成，但自检有失败项，请按上方 ✗ 逐条排查（journalctl -u $SRV -n 30）==="
  exit 1
fi
