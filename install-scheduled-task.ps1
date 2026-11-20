# 重装系统 / 换电脑后，一键重建计划任务
# 用法：右键“使用 PowerShell 运行”，或命令行执行：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-scheduled-task.ps1
# 参数：-ScriptPath 指定脚本路径（默认取同目录的 doubao_daily_claim.ps1）；-Time 指定触发时间（默认 07:10）

param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'doubao_daily_claim.ps1'),
    [string]$TaskName = '豆包每日自动领取积分',
    [string]$Time = '07:10'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { throw "找不到脚本：$ScriptPath" }

$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ScriptPath)
$trg = New-ScheduledTaskTrigger -Daily -At $Time
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
$prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $prn `
    -Description '每天自动打开豆包客户端并尝试领取积分' -Force | Out-Null

Write-Host "已注册计划任务：$TaskName（每天 $Time）"
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List NextRunTime, LastRunTime, LastTaskResult
