' 开机自启 Cline Bridge（无窗口）
' 用法：复制到 %APPDATA%\Microsoft\Windows\Start Menu\Programs\StartUp\ClineBridge.vbs
' 日志：bridge\logs\bridge.log
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge"
sh.Run "node ""C:\Users\alice\.cline\data\workspaces\chat\cline-hub\bridge\src\index.js""", 0, False
