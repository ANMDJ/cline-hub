# 文档索引

> 目标：**5 分钟内知道该读哪篇、该干什么**。不确定就看表格第一行。

## 按处境找文档

| 你的处境 | 读这篇 | 大约耗时 |
|---|---|---|
| 刚打开仓库，不知道要干什么 | [`status.md`](status.md) §0「现在要做什么」 | 2 分钟 |
| 想把整套东西从零部署起来（手机 + 电脑闭环） | [`self-host.md`](self-host.md) | 30 分钟 |
| 要给现有 Hub 加第二台 / 第三台电脑 | [`new-device.md`](new-device.md) | 15 分钟 |
| 想知道现在线上是什么状态 | [`status.md`](status.md) §1 基线快照 | 1 分钟 |
| 想知道某个版本改了什么 | [`../CHANGELOG.md`](../CHANGELOG.md) | 2 分钟 |
| 要改 Hub 接口 / 写客户端 | [`api.md`](api.md) | 10 分钟 |
| 要改 bridge 的采集或执行 | [`bridge-notes.md`](bridge-notes.md) + `../bridge/README.md` | 15 分钟 |
| 想推翻某个设计 | [`decisions.md`](decisions.md)（55 条 ADR，只追加） | 按条查 |
| 收到外部安全审计 / 漏洞报告 | [`security-review.md`](security-review.md)（先核事实再采纳） | 10 分钟 |
| 要重启 / 停掉 bridge | [`interruptions.md`](interruptions.md)（先停任务、再杀进程） | 3 分钟 |
| 换服务器 / 从零重建 | [`server-prep.md`](server-prep.md) + `../deploy/README.md` | 30 分钟 |
| 改手机端 UI | `../app/README.md` | 10 分钟 |
| 改落地页 | `../site/README.md` | 5 分钟 |

## 维护规则

1. **`status.md` 每轮都改**：§0 的勾、§1 的实测值、§8 的日志 —— 至少改一处。
2. **`decisions.md` 只追加**：ADR 编号递增，不修改旧条目；推翻旧决定就写新 ADR 并引用旧号。
3. **`api.md` 先改后写码**：契约先定，客户端/服务端再实现，避免两边各写一版。
4. **`bridge-notes.md` 只记实测事实**：命令、路径、报错原文；推测写进 ADR 而不是这里。
5. 文档里的路径一律用**绝对路径或仓库相对路径**，不要写「我本机那个目录」。
6. 任何 token / 口令**不进文档**，只写变量名和获取方式。

## 文档地图

| 文件 | 内容 |
|---|---|
| [`status.md`](status.md) | 现状、待办、坑、自检、变更日志 |
| [`../CHANGELOG.md`](../CHANGELOG.md) | 版本更新日志（按版本，面向变更本身） |
| [`api.md`](api.md) | Hub v1 契约（鉴权 / 错误码 / 请求响应） |
| [`self-host.md`](self-host.md) | 从零自托管：服务器 / 手机 / 多台电脑的完整闭环 |
| [`new-device.md`](new-device.md) | 接入第二台 Windows（bridge + device token） |
| [`bridge-notes.md`](bridge-notes.md) | Windows 端实测：数据位置、`messages.json` 结构、安全排查 |
| [`decisions.md`](decisions.md) | ADR：为什么这么做 |
| [`security-review.md`](security-review.md) | 外部安全审计的逐条复核结论 + 采纳计划（P40–P43） |
| [`interruptions.md`](interruptions.md) | 主动中断记录：为什么杀 bridge / 影响了谁 / 怎么恢复 |
| [`server-prep.md`](server-prep.md) | 服务器从零准备 |
| [`../AGENTS.md`](../AGENTS.md) | 给新会话的入口页（30 秒看懂 + 开工三条命令） |
| [`../README.md`](../README.md) | 项目介绍、手机端用法、功能清单 |
