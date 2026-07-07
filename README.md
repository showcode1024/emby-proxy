# Emby Proxy 一键安装脚本

这是一个基于 Docker + Nginx 的 Emby 反向代理部署脚本。运行后会自动创建挂载目录、生成 Nginx 配置、检查配置，并启动一个名为 `nginx` 的容器。

## 一键运行

在 Linux 服务器上执行下面这一行：

```bash
curl -fsSL -o install_nginx_emby_proxy.sh https://raw.githubusercontent.com/showcode1024/emby-proxy/main/install_nginx_emby_proxy.sh && chmod +x install_nginx_emby_proxy.sh && sudo ./install_nginx_emby_proxy.sh
```

脚本需要你在运行时输入 Emby 地址、端口和本机反代端口，所以不要使用 `curl ... | bash` 这种方式运行。

## 运行前准备

请先确认服务器已经安装并启动 Docker：

```bash
docker --version
```

如果当前用户没有 Docker 权限，请使用 `sudo` 运行脚本。

## 脚本会询问的内容

运行脚本后，会依次提示输入：

```text
Emby 地址/域名：例如 server3.cn2gias.uk，不要带 http:// 或 https://
Emby 端口：例如 443、8096、8920
Emby 协议：http 或 https
是否开启 80 端口首页入口：默认 y，输入 n 则不开启
宿主机反代端口：默认 8443，建议用 18443、9443、8088 等未占用端口
Nginx 挂载目录：默认 /docker/nginx
```

直接回车会使用默认值。

## 80 首页入口和反代端口是什么意思

`80 端口首页入口` 只是普通 Nginx 首页入口。开启后可以访问：

```text
http://服务器IP/
```

`宿主机反代端口` 才是 Emby 代理入口。比如你填写 `18443`，访问地址就是：

```text
http://服务器IP:18443/
```

如果你不需要普通首页，脚本询问“是否开启 80 端口首页入口”时输入 `n` 即可。

## 默认目录结构

脚本默认会创建这些目录：

```text
/docker/nginx/conf/conf.d
/docker/nginx/log
/docker/nginx/html
/docker/nginx/ssl
```

生成的主要配置文件在：

```text
/docker/nginx/conf/conf.d/default.conf
```

## 启动后的访问地址

假设你开启了 80 首页入口，并把反代端口填写为 `18443`：

```text
Nginx 静态页：http://服务器IP/
Emby 反代：http://服务器IP:18443/
```

如果你关闭了 80 首页入口，就只使用 Emby 反代端口访问。

## 脚本做了什么

- 拉取 `nginx:latest` 镜像
- 创建 `/docker/nginx` 挂载目录
- 从官方 Nginx 镜像提取默认 `nginx.conf` 和首页文件
- 生成 Emby 反代配置 `default.conf`
- 启动前检查宿主机端口是否被占用
- 支持 WebSocket、Range 断点续传和长连接
- 隐藏常见真实 IP / 代理链请求头
- 启动 `--restart always` 的 Nginx 容器

## 常用命令

查看容器状态：

```bash
docker ps
```

查看 Nginx 日志：

```bash
docker logs nginx
```

重启 Nginx：

```bash
docker restart nginx
```

修改配置后检查并重启：

```bash
docker exec nginx nginx -t && docker restart nginx
```

## 常见问题

### 端口已经被占用

如果看到类似提示：

```text
Bind for 0.0.0.0:8443 failed: port is already allocated
```

说明宿主机的 `8443` 端口已经被其他程序或容器占用。重新运行脚本，在“宿主机反代端口”那里不要直接回车，改填一个没被占用的端口，例如：

```text
18443
9443
8088
```

然后用新端口访问：

```text
http://服务器IP:新端口/
```

查看哪些容器正在占用端口：

```bash
docker ps
```

### 80 端口被占用

如果脚本提示 `80` 被占用，但你不需要普通 Nginx 首页，重新运行脚本时在这里输入 `n`：

```text
是否开启 80 端口首页入口 [y]: n
```

这样脚本不会映射宿主机 `80` 端口，只保留 Emby 反代端口。

### read-only file system 提示

旧版本脚本在检查配置时，可能会看到：

```text
can not modify /etc/nginx/conf.d/default.conf (read-only file system?)
```

这不是配置失败的原因。新版脚本已经调整检查方式，正常情况下不会再出现这个干扰提示。

## 注意事项

脚本会删除并重建同名容器 `nginx`。如果你的服务器上已经有重要的 `nginx` 容器，请先改脚本里的 `CONTAINER_NAME`，或者备份现有容器配置后再运行。

`80` 端口只用于可选的普通首页入口，Emby 反代端口请填写其他端口，比如 `18443`、`9443` 或 `8088`。

默认反代配置里的 `proxy_ssl_verify off;` 表示不校验上游证书。如果你有完整 CA 证书链，可以自行改成证书校验模式。