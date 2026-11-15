# dsh-Docker：DeepSeek Harness 单容器镜像
#
#   dsh（容器内 loopback :3081，需要 launch token）
#     <- Caddy（容器内 :3080，自动 token 跳转）
#       <- 宿主机 Caddy / nginx（绑定域名 + 终止 TLS）
#
# 容器只做两件事：把 dsh 跑起来，让访问者完全感知不到 launch token。
# 域名和证书都在容器外处理 —— 在宿主机上把域名反代到本容器的 3080 端口即可，
# 容器内不需要配置任何域名。
#
# 转发给 dsh 的请求会把 Host 改写为 127.0.0.1，因此外部域名是什么都不影响
# dsh 的 /api 信任校验。
FROM node:24-trixie

ENV TZ=Asia/Shanghai \
    DSH_HOME=/root/.dsh \
    DEBIAN_FRONTEND=noninteractive

# curl 用于就绪探测；dsh 需要 Node 24。
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @deepseek-ai/dsh@next \
    && dsh --version

# Caddy 二进制取自官方镜像。容器内只做纯 HTTP token 桥接，
# 不编译任何 DNS 模块 —— TLS 由宿主机负责。
COPY --from=caddy:2-alpine /usr/bin/caddy /usr/bin/caddy

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/dsh-entrypoint.sh
COPY Caddyfile.tpl /etc/caddy/Caddyfile.tpl

RUN chmod +x /usr/local/bin/dsh-entrypoint.sh \
    && mkdir -p /root/.dsh /workspace \
    && caddy version

# 桥接端口：宿主机把域名反代到这里。
EXPOSE 3080

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint.sh"]
