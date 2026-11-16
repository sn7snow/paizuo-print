#!/usr/bin/env bash
# ============================================================================
# make-cert.sh — 内网 HTTPS 证书一键脚本（自建根 CA + 带 IP SAN 的服务器证书）
#
# 用法（root / sudo）：
#   sudo bash make-cert.sh                     # 自动探测本机 IP，建 CA + 签发 + 安装
#   sudo bash make-cert.sh --ip 10.1.2.3       # 指定员工浏览器里输入的地址
#   sudo bash make-cert.sh --ip 10.1.2.3 --dns paizuo.local
#   sudo bash make-cert.sh --renew             # 强制重签服务器证书（根 CA 不动）
#   sudo bash make-cert.sh --force             # 重建根 CA（作废所有已下发的 ca.crt！）
#
# 参数：
#   --ip <addr>     证书绑定的 IP（必须等于员工浏览器地址栏里的地址）
#   --dns <name>    附加域名 SAN，可重复；127.0.0.1 / localhost 已自动包含
#   --days <n>      服务器证书有效期（天），默认 730
#   --ca-days <n>   根 CA 有效期（天），默认 3650
#   --renew         强制重新签发服务器证书（根 CA 保持不变，客户端无需重装根证书）
#   --force         删除并重建根 CA（所有装过旧 ca.crt 的终端都会失效）
#   --no-install    只生成文件，不写入 /etc/nginx/ssl
#   -h, --help      显示帮助
#
# 产物：
#   /root/paizuo-pki/root/paizuo-root-ca.crt   根证书  ← 分发给员工安装（公开）
#   /root/paizuo-pki/root/paizuo-root-ca.key   根 CA 私钥（700，切勿外传；删掉就无法续签）
#   /etc/nginx/ssl/paizuo.crt                  服务器证书
#   /etc/nginx/ssl/paizuo.key                  服务器私钥（600）
#   /etc/nginx/ssl/paizuo-chain.crt            服务器证书 + 根证书 —— nginx 引用这个
#
# 幂等：重复运行会复用已存在的根 CA 与仍然有效的服务器证书，只有 IP/域名变化、
#       证书快到期或传了 --renew/--force 时才重新签发。
# ============================================================================
set -euo pipefail
umask 077

PKI_DIR=/root/paizuo-pki
ROOT_DIR=$PKI_DIR/root
SRV_DIR=$PKI_DIR/server
CA_KEY=$ROOT_DIR/paizuo-root-ca.key
CA_CRT=$ROOT_DIR/paizuo-root-ca.crt
CA_SRL=$ROOT_DIR/paizuo-root-ca.srl
SRV_KEY=$SRV_DIR/paizuo.key
SRV_CRT=$SRV_DIR/paizuo.crt
SRV_CSR=$SRV_DIR/paizuo.csr
NGX_DIR=/etc/nginx/ssl

SERVER_IP=""
EXTRA_DNS=()
DAYS=730
CA_DAYS=3650
FORCE=0
RENEW=0
INSTALL=1

usage() {
  cat <<'USAGE'
make-cert.sh — 内网 HTTPS 证书一键脚本（自建根 CA + 带 IP SAN 的服务器证书）

用法：
  sudo bash make-cert.sh                     自动探测本机 IP，建 CA + 签发 + 安装
  sudo bash make-cert.sh --ip 10.1.2.3       指定员工浏览器里输入的地址
  sudo bash make-cert.sh --ip 10.1.2.3 --dns paizuo.local
  sudo bash make-cert.sh --renew             强制重签服务器证书（根 CA 不动）
  sudo bash make-cert.sh --force             重建根 CA（作废所有已下发的 ca.crt！）

参数：
  --ip <addr>     证书绑定的 IP（必须等于员工浏览器地址栏里的地址）
  --dns <name>    附加域名 SAN，可重复；127.0.0.1 / localhost 已自动包含
  --days <n>      服务器证书有效期（天），默认 730
  --ca-days <n>   根 CA 有效期（天），默认 3650
  --renew         强制重新签发服务器证书（客户端无需重装根证书）
  --force         删除并重建根 CA（所有装过旧 ca.crt 的终端都会失效）
  --no-install    只生成文件，不写入 /etc/nginx/ssl
  -h, --help      显示本帮助
USAGE
}

need_val() {
  [[ -n "${2:-}" ]] || { echo "错误：$1 需要一个值"; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)         need_val "$@"; SERVER_IP="$2"; shift 2 ;;
    --dns)        need_val "$@"; EXTRA_DNS+=("$2"); shift 2 ;;
    --days)       need_val "$@"; DAYS="$2"; shift 2 ;;
    --ca-days)    need_val "$@"; CA_DAYS="$2"; shift 2 ;;
    --renew)      RENEW=1; shift ;;
    --force)      FORCE=1; RENEW=1; shift ;;
    --no-install) INSTALL=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "错误：未知参数 $1（-h 看用法）"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "错误：请用 root / sudo 运行"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "错误：未找到 openssl（apt install -y openssl）"; exit 1; }
[[ $DAYS =~ ^[0-9]+$ && $CA_DAYS =~ ^[0-9]+$ ]] || { echo "错误：--days / --ca-days 必须是数字"; exit 1; }

# openssl 1.1.1 才支持 -addext / -checkip；Debian 10+ / Ubuntu 20.04+ 均满足
if ! openssl req -help 2>&1 | grep -q -- '-addext'; then
  echo "错误：openssl 版本过低（需要 1.1.1+，当前 $(openssl version)）"
  exit 1
fi

detect_ip() {
  local ip=""
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1) || true
  fi
  printf '%s' "$ip"
}

if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP=$(detect_ip)
  [[ -n "$SERVER_IP" ]] || { echo "错误：探测不到本机 IP，请用 --ip 指定"; exit 1; }
  echo "==> 自动探测本机 IP：$SERVER_IP（如员工用别的地址访问，请改用 --ip 指定）"
fi
[[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "错误：IP 格式不正确：$SERVER_IP"; exit 1; }
echo

# 判断现有证书是否已包含指定 IP（老版本 openssl 没有 -checkip，用文本匹配兜底）
HAS_CHECKIP=0
if openssl x509 -help 2>&1 | grep -q -- '-checkip'; then HAS_CHECKIP=1; fi
cert_has_ip() {
  [[ -f "$SRV_CRT" ]] || return 1
  if [[ $HAS_CHECKIP -eq 1 ]]; then
    openssl x509 -in "$SRV_CRT" -noout -checkip "$1" >/dev/null 2>&1
  else
    openssl x509 -in "$SRV_CRT" -noout -text 2>/dev/null | grep -q "IP Address:$1"
  fi
}

# ----------------------------------------------------------------------------
# 根 CA
# ----------------------------------------------------------------------------
mkdir -p "$ROOT_DIR" "$SRV_DIR"
chmod 700 "$PKI_DIR" "$ROOT_DIR" "$SRV_DIR"

if [[ $FORCE -eq 1 ]]; then
  echo "==> --force：删除旧根 CA（所有已安装旧 ca.crt 的终端都需要重装）"
  rm -f "$CA_KEY" "$CA_CRT" "$CA_SRL"
fi

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "==> [1/4] 生成根 CA（RSA 4096，${CA_DAYS} 天）..."
  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  chmod 600 "$CA_KEY"
  openssl req -x509 -new -key "$CA_KEY" -sha256 -days "$CA_DAYS" -out "$CA_CRT" \
    -subj "/O=Paizuo Internal/CN=Paizuo Internal Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  chmod 644 "$CA_CRT"
  RENEW=1
else
  echo "==> [1/4] 复用已有根 CA：$CA_CRT"
fi

# ----------------------------------------------------------------------------
# 服务器证书：能复用就不重签（重签会让已装根证书的浏览器再次提示，没必要）
# ----------------------------------------------------------------------------
need_leaf=0
if [[ $RENEW -eq 1 || ! -f "$SRV_CRT" || ! -f "$SRV_KEY" ]]; then
  need_leaf=1
elif ! cert_has_ip "$SERVER_IP"; then
  need_leaf=1                                    # IP 变了（换了服务器/网段）
elif ! openssl x509 -in "$SRV_CRT" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
  need_leaf=1                                    # 剩余不足 30 天
elif ! openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null 2>&1; then
  need_leaf=1                                    # 证书与当前根 CA 不配套（重建过 CA）
fi
if [[ ${#EXTRA_DNS[@]} -gt 0 ]]; then
  for d in "${EXTRA_DNS[@]}"; do
    openssl x509 -in "$SRV_CRT" -noout -checkhost "$d" >/dev/null 2>&1 || need_leaf=1
  done
fi

if [[ $need_leaf -eq 1 ]]; then
  # 127.0.0.1 / localhost 始终包含：deploy.sh 自检和服务器本机访问都用它
  SAN="IP:$SERVER_IP"
  if [[ "$SERVER_IP" != "127.0.0.1" ]]; then SAN="$SAN, IP:127.0.0.1"; fi
  SAN="$SAN, DNS:localhost"
  if [[ ${#EXTRA_DNS[@]} -gt 0 ]]; then
    for d in "${EXTRA_DNS[@]}"; do
      SAN="$SAN, DNS:$d"
    done
  fi

  echo "==> [2/4] 生成服务器私钥与 CSR..."
  openssl genrsa -out "$SRV_KEY" 2048 2>/dev/null
  chmod 600 "$SRV_KEY"
  openssl req -new -key "$SRV_KEY" -out "$SRV_CSR" -subj "/O=Paizuo Internal/CN=$SERVER_IP"

  echo "==> [3/4] 用根 CA 签发（SAN: $SAN，${DAYS} 天）..."
  cat > "$SRV_DIR/ext.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $SAN
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl x509 -req -in "$SRV_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -CAserial "$CA_SRL" \
    -days "$DAYS" -sha256 -extfile "$SRV_DIR/ext.cnf" -out "$SRV_CRT"
  rm -f "$SRV_CSR" "$SRV_DIR/ext.cnf"
  chmod 644 "$SRV_CRT"
else
  echo "==> [2-3/4] 服务器证书无需重签（SAN 已含 $SERVER_IP，剩余有效期 > 30 天）"
fi

# ----------------------------------------------------------------------------
# 安装到 nginx
# ----------------------------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
  echo "==> [4/4] 安装到 $NGX_DIR 并校验证书链..."
  install -d -m 755 "$NGX_DIR"
  install -m 644 "$SRV_CRT" "$NGX_DIR/paizuo.crt"
  install -m 600 "$SRV_KEY" "$NGX_DIR/paizuo.key"
  # nginx 用「叶证书 + 根证书」拼接文件签发完整链（客户端未装根证书时也只多一次提示）
  cat "$SRV_CRT" "$CA_CRT" > "$NGX_DIR/paizuo-chain.crt"
  chmod 644 "$NGX_DIR/paizuo-chain.crt"
  openssl verify -CAfile "$CA_CRT" "$SRV_CRT"
else
  echo "==> [4/4] --no-install：跳过安装到 $NGX_DIR"
fi

# ----------------------------------------------------------------------------
# 结果
# ----------------------------------------------------------------------------
echo
echo "============================ 证书就绪 ============================"
echo "根证书（发给员工双击安装，或 IT 统一下发）："
echo "  $CA_CRT"
openssl x509 -in "$CA_CRT" -noout -fingerprint -sha256 | sed 's/^/  /'
openssl x509 -in "$CA_CRT" -noout -subject -enddate | sed 's/^/  /'
echo
echo "服务器证书："
openssl x509 -in "$SRV_CRT" -noout -subject -enddate | sed 's/^/  /'
openssl x509 -in "$SRV_CRT" -noout -ext subjectAltName | sed 's/^/  /'
echo
if [[ $INSTALL -eq 1 ]]; then
  echo "nginx 引用路径（nginx-tls.conf 已按此写好）："
  echo "  ssl_certificate     $NGX_DIR/paizuo-chain.crt"
  echo "  ssl_certificate_key $NGX_DIR/paizuo.key"
  echo
  echo "若 nginx 已在运行且配置已引用上述文件，执行下面一条命令即可生效："
  echo "  nginx -t && systemctl reload nginx"
fi
echo
echo "根 CA 私钥位置（本机 700 目录，可续签；拷走后请妥善保管）："
echo "  $CA_KEY"
echo "  续签服务器证书：sudo bash $0 --renew"
echo "  重建根 CA：      sudo bash $0 --force   ← 所有终端都要重装 ca.crt"
echo "=================================================================="
