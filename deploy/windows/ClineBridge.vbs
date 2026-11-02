' 开机自启 Cline Bridge（无窗口）
' 用法：把下面的 REPO 改成你本机 clone 出来的仓库路径（不要带 \bridge），再复制到
'       %APPDATA%\Microsoft\Windows\Start Menu\Programs\StartUp\ClineBridge.vbs
' 日志：bridge\logs\bridge.log
REPO = "C:\Users\you\projects\cline-hub"
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = REPO & "\bridge"
sh.Run "node """ & REPO & "\bridge\src\index.js""", 0, False
