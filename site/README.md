# 开源落地页（`site/`）

纯静态：一个 HTML + 一个 CSS + 一个小脚本，**没有构建步骤、没有 CDN 依赖、没有外部字体**。
服务器上用 Caddy 的 `file_server` 直接吐文件（不引入 nginx）。

```
site/
  index.html     单页：为什么 / 特性 / 架构 / 快速开始 / 安全 / 进度 / FAQ
  styles.css     深色主题，`prefers-reduced-motion` 与移动端都照顾了
  app.js         代码块复制 + 导航高亮 + 未填链接提示（约 90 行，无依赖）
  favicon.svg
  robots.txt     顺手挡掉 /_h/
```

## 本地预览

```bash
cd site && python3 -m http.server 8080   # 或  npx --yes serve .
# 打开 http://127.0.0.1:8080/
```

## 自检

```bash
node site/check-site.mjs      # 标签配对 / CSS 括号 / 引用文件 / 锚点 id
```

它会提示所有外链资源（目前只有 GitHub 仓库地址），确认可接受即可。

## 部署

```bash
# 1. 打包上传（在仓库根目录）
tar czf /tmp/site.tgz -C site .
scp /tmp/site.tgz ubuntu@<server>:/tmp/

# 2. 服务器上解包到站点根目录（属主必须是 caddy）
sudo mkdir -p /var/www/cline-hub
sudo tar -xzf /tmp/site.tgz -C /var/www/cline-hub
sudo chown -R caddy:caddy /var/www/cline-hub
sudo find /var/www/cline-hub -type d -exec chmod 755 {} \;
sudo find /var/www/cline-hub -type f -exec chmod 644 {} \;
```

Caddy 侧只需要（见 `deploy/Caddyfile` 的 IP 站点）：

```
@site not path /_h/*
route @site {
    encode zstd gzip
    root * /var/www/cline-hub
    file_server
}
```

## 换成自己的域名

`deploy/Caddyfile` 里预留了域名版站点（注释状态）。到 DNS 加好：

```
@     A   <服务器 IP>
www   A   <服务器 IP>
```

然后取消那段注释、预建日志文件、reload：

```bash
sudo install -o caddy -g caddy -m 640 /dev/null /var/lib/caddy/site.log
sudo caddy validate --config /tmp/Caddyfile.new --adapter caddyfile
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%s)
sudo cp /tmp/Caddyfile.new /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

## 仓库地址（已填好）

`index.html` 里 3 处外链（顶栏 GitHub、CTA「看源码」、页脚 GitHub）已指向
`https://github.com/ANMDJ/cline-hub`；`app.js` 里 `[data-todo="repo"]` 的「地址还没填」提示保留，
fork 后若改回 `https://github.com/` 占位，点击仍会提示而不是跳错地方。

许可证已经定了：仓库根目录的 `LICENSE` 是 MIT，页脚文案与 `server/` / `bridge/` 的
`package.json` 都已对齐，换协议时这几处要一起改。
