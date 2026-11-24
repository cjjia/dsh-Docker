# Contributing

欢迎提 issue 和 PR。

## 改代码前

```bash
git clone https://github.com/cjjia/dsh-Docker.git
cd dsh-Docker
docker build -t dsh-docker:dev .
```

改完 `entrypoint.sh` / `Caddyfile.tpl` 后建议先做本地验证：

```bash
bash -n entrypoint.sh                      # 语法检查
docker run -d --name dsh-dev -p 13080:3080 dsh-docker:dev
docker logs -f dsh-dev                     # 应该看到 302 就绪
```

然后测一遍完整链路：

```bash
# 1) 无 token -> 302，Location 带 token
curl -s -o /dev/null -D- -H "Host: dsh.example.com" \
  -H "X-Forwarded-Proto: https" http://127.0.0.1:13080/ | grep -i location

# 2) 带 token -> 303 + Set-Cookie
# 3) 带 cookie -> 200
```

## 约定

- `entrypoint.sh` 保持 `set -u`，任何失败都要打印可诊断的日志再退出。
- 容器内**不处理域名和 TLS**。域名相关的东西一律不写进容器。
- Caddyfile 模板里只做占位符替换（`{BRIDGE_PORT}` 等），不要加条件分支。
- 不要在容器里塞多余依赖。Caddy 直接用官方镜像的二进制。

## 不要提交

- 任何真实 token、API key、密码、证书私钥
- `data/` 和 `workspace/` 里的运行时数据
- `.env` 文件（配置直接写在 `docker-compose.yml` 里，不需要环境变量文件）

## 发布

推送到 `main` 会触发 CI 构建并发布到 `ghcr.io/cjjia/dsh-docker`。
每周一 02:00 UTC 有一次定时全量重建。

## 许可

提交的代码按 [MIT](LICENSE) 授权。
