# 容器内的 token 桥接。不处理 TLS —— 证书和域名都由宿主机上的 Caddy 负责。
#
# 工作方式：
#   1. 请求已带 ?token=...  -> 直接透传给 dsh（dsh 会用它换 cookie 并 303 跳转）
#   2. 请求没有 token 且 dsh 返回 401 -> 302 到带 token 的绝对 URL，
#      浏览器拿到 cookie 后落到应用页面。用户全程不用碰 token。
#   3. 其余请求（含已带 cookie 的）直接透传。
#
# 两个关键点（都经过实测）：
#   * 跳转目标必须是**绝对 URL**。在 handle_response 里用相对地址
#     （/?token=...）时，Caddy 会返回空 200 而不是 302。
#   * 反代时把 Host 改写成 127.0.0.1:{DSH_PORT} 并删除 Origin/Referer，
#     这样 dsh 的 /api 浏览器信任栅栏才会放行。否则宿主机传来的外部域名
#     会让 /api 一律 403 —— 这意味着**用户不需要在容器里配任何域名**。
{
	admin off
	auto_https off
}

:{BRIDGE_PORT} {
	# 绑定地址用 bind 指定（写成 0.0.0.0:port 会被当成 Host 匹配器，外部域名就匹配不上了）。
	bind {BRIDGE_BIND}
	# 已带 token：直接透传，让 dsh 自己换 cookie。
	@has_token query token=*
	handle @has_token {
		reverse_proxy 127.0.0.1:{DSH_PORT} {
			header_up Host 127.0.0.1:{DSH_PORT}
			header_up -Origin
			header_up -Referer
		}
	}

	# 无 token：dsh 会 401，此时跳到带 token 的绝对 URL。
	handle {
		reverse_proxy 127.0.0.1:{DSH_PORT} {
			header_up Host 127.0.0.1:{DSH_PORT}
			header_up -Origin
			header_up -Referer
			@unauthorized status 401
			handle_response @unauthorized {
				@tls header X-Forwarded-Proto https
				handle @tls {
					redir https://{http.request.hostport}/?token={TOKEN} 302
				}
				handle {
					redir http://{http.request.hostport}/?token={TOKEN} 302
				}
			}
		}
	}
}
