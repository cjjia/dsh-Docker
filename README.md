# dsh-Docker

把 [DeepSeek Harness](https://github.com/deepseek-ai)（`dsh`）打包成单个 Docker 镜像，
**自动处理 launch token**，让你用域名直接访问、完全不用管 token。

域名和 HTTPS 证书都在容器外由你自己已有的 Caddy / nginx 负责 —— 容器只暴露一个
普通 HTTP 端口，把它反代过去就行。

```
浏览器
  │  https://dsh.example.com
  ▼
宿主机 Caddy / nginx          ← 绑定域名、申请证书、终止 TLS（你来配）
  │  http://127.0.0.1:3080
  ▼
dsh-Docker 容器
  ├── Caddy   :3080           ← 自动 token 跳转（无感登录）
  └── dsh     :3081 (loopback)
```

## 为什么需要它

`dsh web` 每次启动都会生成一个一次性的 launch token，并要求用
`http://host:port/?token=...` 访问才能拿到登录 cookie。这在本地用没什么问题，
但一旦挂到域名后面就很别扭：token 每次重启都变，你还得去容器日志里翻。

这个镜像把这一步自动化了：

1. 启动 `dsh`，从它的启动日志里读出当次的 launch token
2. 生成一段 Caddy 配置，监听 `3080`
3. 访问者打开 `https://你的域名/` 时，容器发现请求没有 token，就 `302` 跳到
   `https://你的域名/?token=<当次token>`
4. `dsh` 校验通过，下发 30 天有效的登录 cookie，再 `303` 回到干净的 `/`
5. 之后浏览器只带 cookie，**再也不会看到 token**

整个过程对访问者是透明的：输入域名，回车，直接进应用。

## 快速开始

### 1. 用预构建镜像

```bash
mkdir dsh && cd dsh
curl -fsSLO https://raw.githubusercontent.com/cjjia/dsh-Docker/main/docker-compose.yml
docker compose up -d
```

容器起来后，本机 `http://127.0.0.1:3080/` 就应该会跳转并进入应用。

### 2. 或者自己构建

```bash
git clone https://github.com/cjjia/dsh-Docker.git
cd dsh-Docker
docker build -t dsh-docker .
docker run -d --name dsh -p 3080:3080 \
  -v "$PWD/data:/root/.dsh" -v "$PWD/workspace:/workspace" \
  dsh-docker
```

## 在宿主机上绑定域名

容器不碰 TLS，你只需要把域名反代到容器的 `3080` 端口。

### Caddy（推荐，自动申请证书）

```caddyfile
dsh.example.com {
    reverse_proxy 127.0.0.1:3080
}
```

就这两行。Caddy 会自动申请 Let's Encrypt 证书、自动续期、自动把 HTTP 跳到 HTTPS。

> **不要**手动写 `header_up Host {host}`。Caddy 的 `{host}` 会丢掉非标准端口，
> 而默认的 `reverse_proxy` 已经会透传原始 `Host`（含端口），不需要额外配置。

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;

        # 用 $http_host 而不是 $host —— $host 会丢掉非标准端口。
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # dsh 的终端/实时输出需要 WebSocket。
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

### 用别的端口

容器默认用 `3080`。想换端口，改 `.env` 里的 `BRIDGE_PORT`，然后反代到新端口：

```bash
# .env
BRIDGE_PORT=8080
```

```bash
docker compose up -d
```

## 配置

所有变量都有默认值，不建 `.env` 也能直接跑。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BRIDGE_PORT` | `3080` | 对外暴露的端口，宿主机反代到这里 |
| `BRIDGE_BIND` | `0.0.0.0` | 容器内监听地址 |
| `DSH_PORT` | `3081` | dsh 自身端口，只在容器内 loopback 监听 |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `DSH_HOME` | `/root/.dsh` | dsh 的配置与会话目录 |

数据持久化在 `./data`（dsh home）和 `./workspace`（工作目录）两个目录。

## 镜像

预构建镜像发布在 GitHub Container Registry：

```
ghcr.io/cjjia/dsh-docker:latest
```

每周一 02:00 UTC 会自动从零重建一次（不带缓存），这样 `dsh`、Caddy 和基础镜像
都能跟上最新版本。每次构建也会打上 `sha-` 前缀的标签和日期标签。

CI 里包含端到端冒烟测试：拉取镜像、启动容器、验证 `302 → 303 + cookie → 200`
整条链路，任何一环不对构建就会失败。

## 安全说明

- **不要把 `3080` 直接暴露到公网。** 建议在 compose 里把端口映射改成
  `127.0.0.1:3080:3080`，只让本机的反向代理访问。
- **launch token 会出现在两个地方**：容器内的 Caddyfile，以及 `docker logs`
  （entrypoint 需要从 dsh 日志里读它）。它不会长期有效 —— 每次容器重启都会重新生成，
  且浏览器拿到 cookie 后就不再发送。如果在意，可以关掉反向代理 access log 里的
  query 记录，并限制谁能读 `docker logs`。
- **容器内会把转发给 dsh 的 `Host` 改写成 `127.0.0.1`**，并删除 `Origin` /
  `Referer` 头。这是为了通过 dsh 的 `/api` 浏览器信任校验 —— 副作用是你换任何域名
  都不用改容器配置。
- 本仓库不含任何密钥。`.env` 和运行时数据都已被 `.gitignore` 忽略。

## 工作方式（实现细节）

想了解为什么这么写，可以看这几个文件：

- `entrypoint.sh` — 启动 dsh、等它就绪、抓 launch token、渲染 Caddyfile、
  启动桥接、监护两个进程
- `Caddyfile.tpl` — token 桥接模板，50 行
- `Dockerfile` — `node:24-trixie` + Caddy 二进制，没有多余依赖

几个踩过的坑，都写在注释里了：

1. **跳转必须是绝对 URL。** 在 `handle_response` 里用相对路径（`/?token=...`），
   Caddy 会返回一个空的 `200` 而不是 `302`。
2. **`0.0.0.0:3080` 不能直接当监听地址。** Caddy 会把它当成 Host 匹配器，
   外部域名就匹配不上了。要用 `:3080` 加 `bind 0.0.0.0`。
3. **`{http.request.host}` 会丢掉非标准端口。** 用 `{http.request.hostport}`。
4. **`dsh --host` 只接受具体 IP**，不接受 `0.0.0.0` 这类通配地址。

## 许可

[MIT](LICENSE)
