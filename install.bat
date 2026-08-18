@echo off
rem =====================================================================
rem  IndexTTS-2.5 一键安装包（Windows 双击入口）
rem
rem  .ps1 无法直接双击（会在记事本里打开），所以用这个 .bat 包装，
rem  以绕过执行策略的方式调用 install.ps1。
rem  可以附加额外选项，例如：
rem      install.bat -CheckOnly
rem      install.bat -ModelSource huggingface
rem =====================================================================
setlocal
cd /d "%~dp0"

rem 部分机器的 HKCU\Console\%%Startup ScreenColors=0（黑底黑字）会让所有
rem cmd 窗口看起来像黑屏，尽管下面的脚本其实在正常运行。color 07 为本
rem 会话恢复"黑底浅灰字"。
color 07

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*

if errorlevel 1 (
  echo.
  echo  *** 安装失败 - 请查看上方错误信息。 ***
  pause
)
endlocal
