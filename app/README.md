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

## 用 Android Studio 跑

**打开的是 `app/` 目录，不是仓库根目录**——根目录没有 `pubspec.yaml`，Flutter 插件不会激活，
只会当成一个普通文件夹，这就是「AS 认不出这个项目」的唯一原因。

1. `File → Open…` 选 `…/cline-hub/app`（有 `pubspec.yaml` 的那层）。
2. 首次打开会提示 SDK / 依赖：Android SDK 指到 `%LOCALAPPDATA%\Android\Sdk`（本机 `android/local.properties`
   已写好 `sdk.dir` / `flutter.sdk`，一般不用管）；`pub get` 会自动跑。
3. 右上角运行配置里已经有 **`app (debug)`**（来自版本库里的 `.run/app-debug.run.xml`，
   别处 pull 下来也直接可用），设备下拉选 `cline_pixel` 或真机，点 ▶ 即可。
4. 需要新模拟器：`Device Manager → Create Virtual Device`。本机镜像已装
   `system-images;android-36.1;google_apis_playstore;x86_64`，建的是 `Medium Phone`。

命令行等价写法（不依赖 IDE）：

```bash
$LOCALAPPDATA/Android/Sdk/emulator/emulator.exe -avd cline_pixel &
flutter devices
flutter run -d emulator-5554
```

> 模拟器第一次起来可能显示 `adb: unauthorized`：等几秒，或在模拟器窗口里点「允许 USB 调试」。
> `google_apis_playstore` 镜像的 adbd 与主机 `~/.android/adbkey` 首次握手要确认一次。

首次启动进向导，填两样东西（都来自你自己的 Hub）：

| 字段 | 取值 | 从哪拿 |
|---|---|---|
| Hub 地址 | `http://82.157.153.22/_h/<前缀>` | 仓库 `.secrets/hub-http-prefix.txt`；备案后换 `https://hub.littlewish.top` |
| App token | `clh_...` | `npm run create-device -- --id phone --role app --name Pixel`（只打印一次） |

向导里的「测试连接」会打一次 `/api/v1/health`，一次就能确认「前缀对不对」「token 有效没」「数据库活着没」。

### 手机只需要 App token

三种 token 别搞混，**手机上只填第二种**：

| 谁用 | 角色 / id | 存在哪 | 手机上要填吗 |
|---|---|---|---|
| Windows 采集器（bridge） | `role=device` / `localone` | `bridge/config.json` 的 `deviceToken` | ❌ 不用 |
| 安卓 App | `role=app` / `phone` | `.secrets/phone-token.txt` | ✅ 就填这个 |
| 管理接口 | `admin` | 服务器 `server/.env` 的 `HUB_ADMIN_TOKEN` | ❌ 不用 |

「设备 token」不需要另外激活：它已经在 `bridge/config.json` 里，采集器启动就带着它上报。
真要重新签发（丢了 / 要轮换）才用：

```bash
# 服务器上，重新签发 device（会 upsert，旧 token 立刻失效，记得同步改 bridge/config.json）
sudo docker compose -f /srv/cline-hub/server/docker-compose.yml exec hub \
  npm run create-device -- --id localone --name "LocalOne-Windows"

# 只换某个已存在设备的 token 而不改 id：
node server/scripts/rotate-token.mjs --id phone --out ../.secrets/phone-token.txt
```

### 联调清单（手机装好之后）

1. 打开 App；停在向导页就填两格（值都在仓库 `.secrets/`，**别贴进 issue 或截图**）：
   - Hub 地址：`http://82.157.153.22/_h/<前缀>` ← `.secrets/hub-http-prefix.txt`
   - App token：`clh_...` ← `.secrets/phone-token.txt`
2. 点「测试连接」→ 期望 `连通 cline-hub v0.1.0 · DB xx ms · token 有效`。
3. 点「保存并进入」→ 会话 / 命令两个 Tab 有历史，说明读链路通了。
4. 看顶栏徽标：绿色「实时」= SSE 已连上；一直是橙色「连接中」= 装的是旧包（重建见下）。
5. 测下发（要 Windows 采集器活着）：`cd bridge && npm run health` 有响应后，
   在命令 Tab 右下 FAB 写 `Write-Output hello-from-phone` 下发，
   期望 5 秒内 `pending → delivered → running → done`，结果文本回写进命令详情。

发到真机的话，`flutter install` **不会**重新编译，务必先 build：

```bash
cd app
flutter build apk --release     # → build/app/outputs/flutter-apk/app-release.apk，拷到手机装
# 或者开发用：flutter run -d <flutter devices 里的 id>
```

排查对照：

| 现象 | 原因 |
|---|---|
| `http_404` / 直接连不上 | 地址缺 `/_h/<前缀>` 或前缀写错（Caddy 返回空 body） |
| `401 invalid_token` | token 不对或已轮换，重新签发 |
| 「测试连接」通过但列表空 | Hub 没数据：采集器没上报，看 bridge 与 outbox |
| 命令一直 `pending` | bridge 没跑 / `commands.enabled=false` / 模式不在 `allowModes` |
| 顶栏一直「连接中」 | 旧构建；`flutter build` 后重装（本轮已修：`: connected` 首帧翻成 `open` 事件） |

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
- **命令是「下发」不是「终端」**：bridge 的 `commands.runner` 决定怎么执行 —— `cline`（仓库里的取值）
  会把这句话交给 Cline CLI，在目标 workspace 里**新建一个会话**（`cline -c <workspace> -p "..."`）；
  续会话（`--id`）要求 TTY，无头 bridge 用不了，所以 App 的「继续对话」实际是新开会话；
  只有 `shell` 才是「prompt 当脚本跑」。App 侧不用感知这个差别，`mode` 一直是 `plan` / `act`。


## Hub 侧注意

- 下发命令要求 `app` 角色（路由声明 `auth: 'app'`），用 device token 会拿到 `403 forbidden`。
- `GET /api/v1/health` 是 `auth: 'none'`：**它验不出 token 对不对**。所以向导里「测试连接」
  先打 health（验地址/前缀/数据库），再打一次 `sessions?limit=1`（验 token）。
  这一点是被 `test/live_hub_test.dart` 抓出来的，别改回去。
- 每 IP 有令牌桶限流（默认 120 突发 / 5 rps），轮询太猛会撞 `429 rate_limited`。
- 前缀即口令：地址里少了 `/_h/<前缀>` 会直接 404，Caddy 返回的是**空 body**
  （错误码 `http_404`），所以客户端把 404 统一翻译成「检查 baseUrl 是否包含 /_h/<前缀>」。
