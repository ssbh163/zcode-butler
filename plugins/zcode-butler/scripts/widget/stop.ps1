$host.ui.RawUI.WindowTitle = 'butler-widget-stop'
# v0.2.1:逻辑收编到 lib/widget-common.ps1(stamp 精确杀 → 命令行兜底 → 清孤儿 node)
. (Join-Path $PSScriptRoot '..\lib\widget-common.ps1')
Stop-ButlerInstance -Kind 'widget' -ProcessMatch 'butler-widget\.ps1' -NodeMatch 'zcode-plugins-personal\\zcode-butler'
