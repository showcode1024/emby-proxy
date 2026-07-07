#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="nginx"
IMAGE_NAME="nginx:latest"
TMP_CONTAINER=""

cleanup() {
  if [ -n "${TMP_CONTAINER:-}" ]; then
    docker rm -f "$TMP_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

read_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value
  read -r -p "${prompt} [${default_value}]: " value
  printf '%s' "${value:-$default_value}"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1"
    exit 1
  fi
}

is_valid_port() {
  local port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null
}

port_has_listener() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
    return $?
  fi

  return 1
}

check_host_port() {
  local port="$1"
  local label="$2"
  local conflicting_containers

  conflicting_containers="$(docker ps --filter "publish=$port" --format '{{.Names}}' | grep -vx "$CONTAINER_NAME" || true)"
  if [ -n "$conflicting_containers" ]; then
    echo "端口 ${port} 已被其他 Docker 容器占用："
    echo "$conflicting_containers"
    echo "请重新运行脚本，把 ${label} 换成其他端口，比如 18443、9443、8080。"
    exit 1
  fi

  if docker ps --filter "name=${CONTAINER_NAME}" --filter "publish=$port" --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    return 0
  fi

  if port_has_listener "$port"; then
    echo "端口 ${port} 已被系统进程占用。"
    echo "请重新运行脚本，把 ${label} 换成其他端口，比如 18443、9443、8080。"
    exit 1
  fi
}

require_command docker

if [ "$(id -u)" -ne 0 ]; then
  echo "提示：脚本会创建 /docker/nginx。如遇到权限不足，请用 sudo 运行。"
fi

EMBY_HOST="$(read_with_default "请输入 Emby 地址/域名，不要带 http:// 或 https://" "server3.cn2gias.uk")"
EMBY_PORT="$(read_with_default "请输入 Emby 端口" "443")"
UPSTREAM_SCHEME="$(read_with_default "请输入 Emby 协议：http 或 https" "https")"
HOST_HTTP_PORT="$(read_with_default "请输入宿主机 HTTP 端口" "80")"
HOST_PROXY_PORT="$(read_with_default "请输入宿主机反代端口" "8443")"
BASE_DIR="$(read_with_default "请输入 nginx 挂载目录" "/docker/nginx")"

case "$UPSTREAM_SCHEME" in
  http|https) ;;
  *)
    echo "协议只能填写 http 或 https。"
    exit 1
    ;;
esac

if [ -z "$EMBY_HOST" ] || [ -z "$EMBY_PORT" ] || [ -z "$HOST_HTTP_PORT" ] || [ -z "$HOST_PROXY_PORT" ]; then
  echo "Emby 地址、Emby 端口、宿主机端口不能为空。"
  exit 1
fi

if ! is_valid_port "$EMBY_PORT"; then
  echo "Emby 端口不合法：$EMBY_PORT"
  exit 1
fi

if ! is_valid_port "$HOST_HTTP_PORT"; then
  echo "宿主机 HTTP 端口不合法：$HOST_HTTP_PORT"
  exit 1
fi

if ! is_valid_port "$HOST_PROXY_PORT"; then
  echo "宿主机反代端口不合法：$HOST_PROXY_PORT"
  exit 1
fi

if [ "$HOST_HTTP_PORT" = "$HOST_PROXY_PORT" ]; then
  echo "宿主机 HTTP 端口和反代端口不能相同。"
  exit 1
fi

check_host_port "$HOST_HTTP_PORT" "宿主机 HTTP 端口"
check_host_port "$HOST_PROXY_PORT" "宿主机反代端口"

mkdir -p \
  "$BASE_DIR/conf/conf.d" \
  "$BASE_DIR/log" \
  "$BASE_DIR/html" \
  "$BASE_DIR/ssl"

echo "拉取 nginx 镜像..."
docker pull "$IMAGE_NAME" >/dev/null

TMP_CONTAINER="nginx_config_init_$$"
docker create --name "$TMP_CONTAINER" "$IMAGE_NAME" >/dev/null
docker cp "$TMP_CONTAINER:/etc/nginx/nginx.conf" "$BASE_DIR/conf/nginx.conf"
docker cp "$TMP_CONTAINER:/usr/share/nginx/html/index.html" "$BASE_DIR/html/index.html"
docker rm -f "$TMP_CONTAINER" >/dev/null
TMP_CONTAINER=""

tee "$BASE_DIR/conf/conf.d/default.conf" >/dev/null <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      '';
}

upstream emby1 {
    server ${EMBY_HOST}:${EMBY_PORT};
    keepalive 64;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
        charset utf-8;
    }

    # rewrite ^(.*) https://\$server_name\$1 permanent;
}

server {
    listen ${HOST_PROXY_PORT} default_server;
    listen [::]:${HOST_PROXY_PORT} default_server;

    server_name _;

    client_max_body_size 0;
    gzip off;
    access_log off;

    http2 on;

    location / {
        proxy_pass ${UPSTREAM_SCHEME}://emby1;
        proxy_http_version 1.1;

        # 上游 Host / SNI，保证访问目标 Emby 正常识别
        proxy_set_header Host ${EMBY_HOST};
        proxy_ssl_server_name on;
        proxy_ssl_name ${EMBY_HOST};

        # TLS 设置
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_session_reuse on;
        proxy_ssl_verify off;
        # proxy_ssl_trusted_certificate /docker/nginx/ssl/ip.crt;

        # 保留真实客户端 UA，不统一伪装
        proxy_set_header User-Agent \$http_user_agent;

        # 清理真实 IP / 代理链相关 Header，阻断真实身份泄露
        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Forwarded-Proto "";
        proxy_set_header X-Forwarded-Host "";
        proxy_set_header X-Forwarded-Server "";
        proxy_set_header Forwarded "";
        proxy_set_header Via "";
        proxy_set_header X-Original-Forwarded-For "";
        proxy_set_header X-Client-IP "";
        proxy_set_header X-Cluster-Client-IP "";
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header True-Client-IP "";
        proxy_set_header Referer "";
        proxy_set_header Origin "";

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # 视频断点续传 / Range 请求支持
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;

        # 长连接，适合流媒体
        proxy_connect_timeout 30s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        send_timeout 3600s;

        # 视频流传输优化
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_socket_keepalive on;
        proxy_redirect off;
    }
}
EOF

echo "检查 nginx 配置..."
docker run --rm --entrypoint nginx \
  -v "$BASE_DIR/html:/usr/share/nginx/html:ro" \
  -v "$BASE_DIR/conf/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$BASE_DIR/conf/conf.d:/etc/nginx/conf.d:ro" \
  -v "$BASE_DIR/log:/var/log/nginx" \
  "$IMAGE_NAME" -t

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "删除旧容器：$CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker run \
  --restart always \
  --name "$CONTAINER_NAME" \
  -v "$BASE_DIR/html:/usr/share/nginx/html" \
  -v "$BASE_DIR/conf/nginx.conf:/etc/nginx/nginx.conf" \
  -v "$BASE_DIR/conf/conf.d:/etc/nginx/conf.d" \
  -v "$BASE_DIR/log:/var/log/nginx" \
  -p "${HOST_HTTP_PORT}:80" \
  -p "${HOST_PROXY_PORT}:${HOST_PROXY_PORT}" \
  -d "$IMAGE_NAME" >/dev/null

echo "完成。"
echo "容器名称：$CONTAINER_NAME"
echo "静态页面：http://127.0.0.1:${HOST_HTTP_PORT}/"
echo "Emby 反代：http://127.0.0.1:${HOST_PROXY_PORT}/"
echo "配置文件：$BASE_DIR/conf/conf.d/default.conf"