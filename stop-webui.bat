@echo off
rem =====================================================================
rem  停止 IndexTTS-2.5 Web UI（Windows 双击入口）
rem
rem  以绕过执行策略的方式调用 stop-webui.ps1。
rem  可以附加额外选项，例如：
rem      stop-webui.bat -All
rem      stop-webui.bat -Port 7861
rem =====================================================================
setlocal
cd /d "%~dp0"

rem 部分机器的 HKCU\Console\%%Startup ScreenColors=0（黑底黑字）会让所有
rem cmd 窗口看起来像黑屏，尽管下面的脚本其实在正常运行。color 07 为本
rem 会话恢复"黑底浅灰字"。
color 07

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-webui.ps1" %*

if errorlevel 1 (
  echo.
  echo  *** 未找到 Web UI 进程。 ***
  pause
)
endlocal
