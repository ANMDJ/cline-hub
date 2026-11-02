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
│     ├─ data/notifier.dart         系统通知：HubNotifier 接口 + Android / Noop 实现
│     ├─ data/link_launcher.dart    用系统浏览器打开下载地址（原生 MethodChannel）
│     ├─ data/settings_store.dart   baseUrl / token / 默认设备 / 通知开关 落盘
│     ├─ state/hub_store.dart       列表 + 分页游标 + 事件流 + 断线重连
│     ├─ util/format.dart           相对时间、时长
│     └─ ui/                        gate / setup / home_shell / 三个 Tab / 详情 / 工作区 / 设置
│                                   （详情页：右上角「概览」弹层 + 顶部「会话开头」+ 回到最新）
│                                   （session_tile 是列表与工作区页共用的卡片）
└─ test/                            fake_api + 模型、状态层、页面测试
```

## 跑起来

```bash
cd app
flutter pub get
flutter run -d android            # 真机 / 模拟器
flutter run -d chrome             # 桌面预览（Web 下没有 SSE，见下文）
flutter test                      # 51 个用例（含通知去重 / 回前台补发 / 打开下载页）
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
| 会话列表（扁平、最新优先 + 游标翻页） | `GET /api/v1/sessions?limit=&before=&q=` |
| 工作区页（按项目分组） | `GET /api/v1/sessions?limit=&project=` |
| 会话详情（概览弹层 / 会话开头 / PLAN·ACT 续聊） | `GET /api/v1/sessions/:sessionId` + `GET …/messages?after=-1&limit=12` + `POST /api/v1/commands` |
| 命令列表 | `GET /api/v1/commands?limit=50` |
| 下发命令 | `POST /api/v1/commands`（角色必须是 `app`） |
| 动态 | `GET /api/v1/hooks?limit=50&beforeId=` |
| 实时更新 | `GET /api/v1/events?token=...`（SSE） |

SSE 四种事件都用上了：`session`（去抖 900ms 后刷新列表）、`hook`（插到动态顶部，按 id 去重）、
`command` / `command.update`（按 id 就地替换命令状态）。

工作区页的分组键会抹平路径写法差异（`C:\a` / `C:/a` / 重复或尾部斜杠 / 大小写），
同一个目录只显示一组；`HubStore._pathKey()` 只用于比较，展示值仍是服务端原样（ADR-44）。

## 系统通知（1.1.2 起）

| 触发 | 来源 | 说明 |
|---|---|---|
| 命令完成 / 失败 / 取消 | SSE `command.update` 的 active → 终态 | 正文优先 `errorText`，其次 `resultText`；去 ANSI 后截 160 字 |
| 会话完成 / 失败 / 中断 | SSE `hook` 的 `session_done` / `session_failed` / `session_cancelled` | 只认 bridge 合成的三个；`agent_*` 不弹（ntfy 已覆盖） |
| 后台期间结束的命令 | 回前台 `resume()` 后补拉 | 只补「退后台时还在跑」的那些，避免打开 App 刷屏 |

实现：`MainActivity` 注册 `top.littlewish.cline_console/notify`（`ensurePermission` / `show`），
通道 `cline_hub_events`，小图标 `ic_stat_hub`；Dart 侧是 `data/notifier.dart` 的 `HubNotifier`。
通知本身**没有引入额外 pub 依赖**（见 ADR-35）：原生系统 API 足够，也少一个 Gradle desugaring 的失败点。
（1.1.4 起确实多了第三个依赖 `flutter_markdown_plus`，但那是 P8 的 Markdown 渲染，与通知无关，见 ADR-42。）
设置页「通知」卡片可分别关掉命令 / 会话通知，并手动请求 `POST_NOTIFICATIONS`（Android 13+）。

边界：App 退到后台会断 SSE 省电，这期间收不到事件（可靠通道仍是 ntfy）；
这里的通知是「App 还活着时的即时提醒」，不是推送。同一个 `commandId:status` / `hook:<id>` 只弹一次。

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
- **`usesCleartextTraffic="true"`**：方便局域网 / 自托管用户直接用 `http://<IP>:3100` 起步；
  公网入口当前是 `https://hub.littlewish.top:8443`。只用 HTTPS 的话可以删掉这个开关。
- **命令是「下发」不是「终端」**：bridge 的 `commands.runner` 决定怎么执行 —— `cline`（仓库里的取值）
  会把这句话交给 Cline CLI，在目标 workspace 里**新建一个会话**（`cline -c <workspace> -p "..."`）；
  续会话（`--id`）要求 TTY，无头 bridge 用不了，所以 App 的「继续对话」实际是新开会话；
  只有 `shell` 才是「prompt 当脚本跑」。App 侧不用感知这个差别，`mode` 一直是 `plan` / `act`。
- **耗时靠自己走表**：`CommandItem.duration` 是 getter，但列表只在数据变化时重建，SSE 空闲时
  秒数会停住。`ElapsedText` 在「执行中」时挂一个 1 秒 `Timer.periodic`，翻成终态立刻停。
- **设备过滤在本地做**：`HubStore.visible*` 在已加载的 50–60 条上筛，不重新请求（分页游标会乱）。
  `DeviceFilterBar` 只在已知设备 ≥ 2 时渲染，单设备下界面与以前完全一样。
  设备候选来自 `GET /api/v1/devices`（ADR-47），并合并「设置里的 deviceId / 已加载数据」兜底；
  chip 显示 `clients.name`，设置页「已接入设备」卡片展示在线状态与计数。


## Hub 侧注意

- 下发命令要求 `app` 角色（路由声明 `auth: 'app'`），用 device token 会拿到 `403 forbidden`。
- `GET /api/v1/health` 是 `auth: 'none'`：**它验不出 token 对不对**。所以向导里「测试连接」
  先打 health（验地址/前缀/数据库），再打一次 `sessions?limit=1`（验 token）。
  这一点是被 `test/live_hub_test.dart` 抓出来的，别改回去。
- 每 IP 有令牌桶限流（默认 120 突发 / 5 rps），轮询太猛会撞 `429 rate_limited`。
- 前缀即口令：地址里少了 `/_h/<前缀>` 会直接 404，Caddy 返回的是**空 body**
  （错误码 `http_404`），所以客户端把 404 统一翻译成「检查 baseUrl 是否包含 /_h/<前缀>」。

## 消息展示、复制与更新（1.1.0 起）

| 能力 | 位置 | 说明 |
|---|---|---|
| 长文本折叠 | `ui/widgets.dart` 的 `MessageText` | 超过 900 字或 12 行折叠，点「展开全文」进 `TextViewerPage` |
| 消息复制 | 气泡右下角 / 命令条 | `CopyButton`，剪贴板写入后 snackbar 提示 |
| 复制整段对话 | 详情页 AppBar 的 `copy_all` | 按 `seq` 拼「用户/助手」，命令附 `$ cmd` |
| 截断提示 | 气泡 / 命令条 | `truncated=true` 时明确写「原文更长」，不假装完整 |
| 选择题 | `_QuestionBubble` | `ask_question` 的选项渲染成按钮；点选 = 带上下文**新开一条命令**（无头 CLI 不能中途注入） |
| 纯文本展示 | `util/format.dart` 的 `stripAnsi` / `inlinePreview` | 命令输出是终端回放，几乎每个词都被 `\u001b[2m` 包着；展示与复制前过滤（库里保留原字节）。会话列表预览由服务端 `plainPreview` 洗好 |
| Markdown 渲染 | `ui/widgets.dart` 的 `markdownSheetOf` / `MessageText` | 1.1.4 起会话正文 / 问题 / 结果按 Markdown 渲染（`flutter_markdown_plus`）；**命令输出不解析**（终端原文）。长文本折叠态仍是纯文本预览，展开页才渲染 |
| 取消命令 | `ui/commands_page.dart` 的 `_CancelCommandButton` | 只有 `pending/delivered/running/cancelling` 显示；二次确认后 `POST /commands/:id/cancel`；排队中立即 `cancelled`，执行中先 `cancelling`，终态由 SSE 推回 |
| 版本与更新 | `ui/settings_page.dart` | 版本号来自 `data/app_version.dart`；「检查更新」读 `GET /api/v1/app/latest`。有新版本时给两个入口：**「打开下载页」**（`data/link_launcher.dart` → 原生 `ACTION_VIEW`，直接用系统浏览器打开 APK 地址）与「复制链接」；打不开浏览器时自动退回复制 |
| 已接入设备 | `ui/settings_page.dart` | 读 `GET /api/v1/devices`：在线（2 分钟内有 `lastSeenAt`）/ 离线、会话数、待执行 / 执行中、最近上报；「设为默认」直接改默认下发设备 |

### 发版流程

1. 改 `pubspec.yaml` 的 `version: x.y.z+n` **和** `lib/src/data/app_version.dart` 的
   `kAppVersion` / `kAppBuild`（两处不一致时脚本会直接报错）。
2. 更新 `kChangelog`（App 内「更新日志」直接读它）。
3. `node scripts/release-apk.mjs --notes "a;b" --base-url https://hub.littlewish.top:8443/app`
   → `dist/cline-console-<version>.apk` + `dist/latest.json`。
   > `flutter build apk` 要 1~3 分钟，超过单条命令 30 秒的限制时，APK 往往已经产出；
   > 这时用 `--skip-build` 复用 `build/app/outputs/flutter-apk/app-release.apk`，
   > 只重新生成清单，不用再等一次全量构建。
4. 按脚本打印的 `scp`/`ssh` 命令上传：APK 进 `/var/www/cline-hub/app/`，
   清单进 `/srv/cline-hub/releases/latest.json`（docker-compose 只读挂载到容器里的
   `/app/releases`，Hub 每次请求现读，**不用重启**）。

> 本机工具链：SDK `%LOCALAPPDATA%\Android\Sdk`、JDK 17 `<JDK 17 路径>`、
> `GRADLE_USER_HOME=%USERPROFILE%\.gradle`。打包前必须设 `JAVA_HOME`（默认 PATH 上是 zulu-8，
> Gradle 9 直接拒绝）：`$env:JAVA_HOME='<JDK 17 路径>'`。
> `release` 用的是 debug 签名（模板默认），换机器重建会签名冲突、必须先卸载。

