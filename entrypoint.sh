#!/bin/bash
# dsh entrypoint：在一个容器里跑 dsh web + Caddy token 桥接。
#
#   dsh（loopback :3081，需要 launch token）
#     <- Caddy（:3080，自动跳转，把无 token 的访问带到 token 链接）
#       <- 宿主机 Caddy / nginx（绑定域名 + 终止 TLS）
#
# 容器不处理域名和证书：在宿主机上把域名反代到本容器的 3080 端口即可，
# 用户全程感知不到 token。
#
# 反代时请保留 Host 头（Caddy 默认行为）并传 X-Forwarded-Proto，跳转就会
# 用正确的 scheme + 域名。容器内会把 Host 改写为 127.0.0.1 再转发给 dsh，
# 因此不需要在容器里配置任何域名。
set -u

DSH_PORT="${DSH_PORT:-3081}"
BRIDGE_PORT="${BRIDGE_PORT:-3080}"
BRIDGE_BIND="${BRIDGE_BIND:-0.0.0.0}"

log() { echo "dsh: $*"; }

# ---- 启动 dsh --------------------------------------------------------------
# dsh 的 --host 只接受具体 IP（拒绝通配地址），所以绑 127.0.0.1；
# 对外由 Caddy 桥接。
cd /workspace || { log "错误：/workspace 不存在"; exit 1; }
dsh web --no-open --port "$DSH_PORT" --host 127.0.0.1 > /tmp/dsh.log 2>&1 &
DSH_PID=$!
log "dsh 启动中（pid $DSH_PID，监听 127.0.0.1:$DSH_PORT）"
tail -F /tmp/dsh.log 2>/dev/null &
TAIL_PID=$!

shutdown() {
  kill "${DSH_PID:-}" ${CADDY_PID:-} ${TAIL_PID:-} 2>/dev/null || true
}
trap shutdown TERM INT

# ---- 等 dsh 就绪 -----------------------------------------------------------
# 不带 token 访问 / 返回 401 也算就绪（401 正说明 dsh 在正常要求认证）。
READY=0
for _i in $(seq 1 60); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    "http://127.0.0.1:${DSH_PORT}/" 2>/dev/null || true)
  if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
    log "dsh 已就绪（HTTP $CODE）"
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" != "1" ]; then
  log "错误：dsh 在 60 秒内没有响应，最近日志："
  tail -40 /tmp/dsh.log >&2
  shutdown
  exit 1
fi

# ---- 从日志里取 launch token ----------------------------------------------
# dsh 启动时会打印：dsh web: http://127.0.0.1:3081/?token=XXXX
TOKEN=""
for _i in $(seq 1 30); do
  TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' /tmp/dsh.log 2>/dev/null \
    | tail -1 | cut -d= -f2 || true)
  [ -n "$TOKEN" ] && break
  sleep 1
done
if [ -z "$TOKEN" ]; then
  log "错误：dsh 日志里没有 launch token，无法启动 token 桥接。日志："
  tail -40 /tmp/dsh.log >&2
  shutdown
  exit 1
fi
log "已取得 launch token（${#TOKEN} 字符）"

# ---- 生成 Caddyfile --------------------------------------------------------
# 只替换占位符，不做条件分支：容器内永远只有一种桥接模式。
TPL=$(cat /etc/caddy/Caddyfile.tpl)
CADDYFILE="${TPL//\{DSH_PORT\}/$DSH_PORT}"
CADDYFILE="${CADDYFILE//\{BRIDGE_PORT\}/$BRIDGE_PORT}"
CADDYFILE="${CADDYFILE//\{BRIDGE_BIND\}/$BRIDGE_BIND}"
CADDYFILE="${CADDYFILE//\{TOKEN\}/$TOKEN}"
printf '%s' "$CADDYFILE" > /etc/caddy/Caddyfile

if ! validate_out=$(caddy validate --config /etc/caddy/Caddyfile \
      --adapter caddyfile 2>&1); then
  log "错误：生成的 Caddyfile 校验失败："
  echo "$validate_out" >&2
  cat /etc/caddy/Caddyfile >&2
  shutdown
  exit 1
fi

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile > /tmp/caddy.log 2>&1 &
CADDY_PID=$!
log "Caddy 启动中（pid $CADDY_PID，桥接 ${BRIDGE_BIND}:${BRIDGE_PORT}）"

# ---- 等桥接生效 ------------------------------------------------------------
# 无 token 访问桥接的 / 应返回 302（跳到 token 链接）。
BRIDGE_OK=0
for _i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    "http://127.0.0.1:${BRIDGE_PORT}/" 2>/dev/null || true)
  if [ "$CODE" = "302" ]; then
    log "桥接已就绪（:${BRIDGE_PORT} 返回 302）"
    BRIDGE_OK=1
    break
  fi
  sleep 1
done
if [ "$BRIDGE_OK" != "1" ]; then
  log "警告：桥接没有返回 302（最后状态 HTTP ${CODE:-000}），Caddy 日志："
  tail -30 /tmp/caddy.log >&2
fi

log "就绪：宿主机把域名反代到本容器 :${BRIDGE_PORT} 即可（无需配置域名）"

# ---- 进程监护 --------------------------------------------------------------
wait -n "$DSH_PID" "$CADDY_PID"
EXIT=$?
log "有进程退出（$EXIT），正在关闭"
shutdown
exit "$EXIT"
