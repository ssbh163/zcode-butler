$host.ui.RawUI.WindowTitle = 'stats-widget-stop'
# v0.2.1:与 widget/stop.ps1 同机制(旧版窗口枚举式废弃 —— 只覆盖「窗口活着」状态,
# 启动早期未建窗/窗口已毁进程未退时假阴性报 not running;详见开发日志 v0.2.1)
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
Stop-ButlerInstance -Kind 'stats' -ProcessMatch 'stats-widget\.ps1'
