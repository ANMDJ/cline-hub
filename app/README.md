# Cline Console · App（M2b）

Android 客户端（Web 只作桌面预览）。三个 Tab：**会话 / 命令 / 动态**，顶栏常驻 SSE 连接状态。

```
app/
├─ lib/
│  ├─ main.dart                     启动：读 SharedPreferences 里的连接配置
│  └─ src/
│     ├─ app.dart                   MaterialApp + 主题
│     ├─ models/models.dart         Hub v1 返回结构（全部容错解析）
│     ├─ data/hub_api.dart          HubApi 接口 + HttpHubApi（REST + SSE）
│     ├─ data/settings_store.dart   baseUrl / token / 默认设备 落盘
│     ├─ state/hub_store.dart       列表 + 分页游标 + 事件流 + 断线重连
│     ├─ util/format.dart           相对时间、时长
│     └─ ui/                        gate / setup / home_shell / 三个 Tab / 详情 / 设置
└─ test/                            fake_api + 模型、状态层、页面测试
```

## 跑起来

```bash
cd app
flutter pub get
flutter run -d android            # 真机 / 模拟器
flutter run -d chrome             # 桌面预览（Web 下没有 SSE，见下文）
flutter test                      # 19 个用例
flutter build apk --release       # 产物 build/app/outputs/flutter-apk/

# 可选：拿真实 Hub 跑一遍客户端（不设变量则这组自动跳过）
HUB_LIVE_URL='http://82.157.153.22/_h/<前缀>' HUB_LIVE_TOKEN='clh_...' \
  flutter test test/live_hub_test.dart
```

首次启动进向导，填两样东西（都来自你自己的 Hub）：

| 字段 | 取值 | 从哪拿 |
|---|---|---|
| Hub 地址 | `http://82.157.153.22/_h/<前缀>` | 仓库 `.secrets/hub-http-prefix.txt`；备案后换 `https://hub.littlewish.top` |
| App token | `clh_...` | `npm run create-device -- --id phone --role app --name Pixel`（只打印一次） |

向导里的「测试连接」会打一次 `/api/v1/health`，一次就能确认「前缀对不对」「token 有效没」「数据库活着没」。

## 用到的接口

| 页面 | 调用 |
|---|---|
| 启动 / 设置健康检查 | `GET /api/v1/health` |
| 会话列表（搜索 + 游标翻页） | `GET /api/v1/sessions?limit=&cursor=&q=` |
| 会话详情 | `GET /api/v1/sessions/:sessionId` |
| 命令列表 | `GET /api/v1/commands?limit=50` |
| 下发命令 | `POST /api/v1/commands`（角色必须是 `app`） |
| 动态 | `GET /api/v1/hooks?limit=50&beforeId=` |
| 实时更新 | `GET /api/v1/events?token=...`（SSE） |

SSE 四种事件都用上了：`session`（去抖 900ms 后刷新列表）、`hook`（插到动态顶部，按 id 去重）、
`command` / `command.update`（按 id 就地替换命令状态）。

## 几个刻意的取舍

- **零状态管理库**：`ChangeNotifier` + `ListenableBuilder`，没引 provider/riverpod。
  代价是 `HubStore` 一个类稍大，好处是「几年后 `flutter pub get` 还能跑」。
- **Web 端没有 SSE**：`package:http` 的 BrowserClient 会缓冲整个响应体，装不了流。
  所以 Web 下 `events()` 退化成 6 秒一次的 `tick`，由 `HubStore` 按节拍轮询；
  Android 上走真 SSE，25 秒一次 `: ping` 心跳，断线按 1/2/5/10/20s 退避重连。
- **退到后台主动断流**：监听生命周期，`paused/hidden` 取消订阅，回前台先 `refreshAll()` 再重连，
  避免复活在旧数据上。
- **token 明文存 SharedPreferences**：自建单人使用，换手机不用重新授权。
  真要多人，就得换成登录态 + 服务端会话，那是另一个项目。
- **`usesCleartextTraffic="true"`**：因为现在入口是 `http://IP/_h/<前缀>`（域名在等备案）。
  备案通过、切到 HTTPS 后应当把这个开关删掉。
- **命令是「下发」不是「终端」**：bridge 默认模板把 prompt 当 PowerShell 脚本跑，
  所以下发面板里明说了「想真的调 Cline，把 `config.commands.template` 改成 `cline --yolo "{prompt}"`」。

## Hub 侧注意

- 下发命令要求 `app` 角色（路由声明 `auth: 'app'`），用 device token 会拿到 `403 forbidden`。
- `GET /api/v1/health` 是 `auth: 'none'`：**它验不出 token 对不对**。所以向导里「测试连接」
  先打 health（验地址/前缀/数据库），再打一次 `sessions?limit=1`（验 token）。
  这一点是被 `test/live_hub_test.dart` 抓出来的，别改回去。
- 每 IP 有令牌桶限流（默认 120 突发 / 5 rps），轮询太猛会撞 `429 rate_limited`。
- 前缀即口令：地址里少了 `/_h/<前缀>` 会直接 404，Caddy 返回的是**空 body**
  （错误码 `http_404`），所以客户端把 404 统一翻译成「检查 baseUrl 是否包含 /_h/<前缀>」。
