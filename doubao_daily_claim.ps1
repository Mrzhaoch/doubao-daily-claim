<#
豆包每日自动领取积分/额度 v2（UI 自动化版）
------------------------------------------------------------------
原理：
  1) 确保豆包客户端在运行并激活窗口（这一步同时触发“当日首次登录”，自动发放每日免费积分）
  2) 点左下角头像，用 UI 自动化(AutomationElement)按“名字”读出当前可用额度
  3) 调用菜单项「免费用豆包工作」，打开额度页标签
  4) 在页面里按名字查找「签到」类按钮，能找到就点，找不到就记录状态
  5) 重新读一次可用额度，对比是否变化，全部写入日志并截图

相比 v1(OCR版)：不再依赖坐标+图像识别，按控件名匹配，界面小改动也不易失效。
退出码：0 = 已领取或今日已完成；2 = 页面没有可点的签到入口；1 = 没打开客户端/页面

运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File "doubao_daily_claim.ps1"
#>

$ErrorActionPreference = 'Stop'

# ================= 配置区 =================
$WinX = 158; $WinY = 162; $WinW = 1200; $WinH = 800   # 客户端窗口固定位置与大小
$AvatarRelX = 65; $AvatarRelY = 764                    # 头像在窗口内的相对坐标
$PageWait = 7                                          # 打开额度页后的等待秒数
$RestartClient = $false                                # $true = 每天先关掉再重开客户端，强制触发“当日首次登录”（每日免费积分靠首次登录发放）
$LogDir = Join-Path $PSScriptRoot 'logs'
# =========================================

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Write-Host $line
    [System.IO.File]::AppendAllText((Join-Path $LogDir ('doubao_claim_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))), $line + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- Win32 ----------
if (-not ('ClaimWin32' -as [type])) {
    Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class ClaimWin32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int m);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, int e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Runtime.WindowsRuntime

function Get-DoubaoWindow {
    $found = New-Object System.Collections.ArrayList
    $cb = [ClaimWin32+EnumProc]{ param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][ClaimWin32]::GetWindowText($h, $sb, 256)
        $t = $sb.ToString()
        if ($t -match '豆包' -and [ClaimWin32]::IsWindowVisible($h)) {
            $r = New-Object ClaimWin32+RECT
            [void][ClaimWin32]::GetWindowRect($h, [ref]$r)
            if (($r.Right - $r.Left) -gt 600) {
                [void]$found.Add([pscustomobject]@{ Hwnd = $h; Title = $t; Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom; W = ($r.Right - $r.Left) })
            }
        }
        return $true
    }
    [void][ClaimWin32]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

function Start-DoubaoClient {
    if (Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue) { return $true }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Doubao\Doubao.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Doubao\Doubao.exe'),
        (Join-Path $env:ProgramFiles 'Doubao\Doubao.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { Write-Log '未找到豆包客户端可执行文件，请手动启动。' 'ERROR'; return $false }
    Write-Log ('启动豆包客户端：' + $candidates[0])
    Start-Process -FilePath $candidates[0] | Out-Null
    for ($i = 0; $i -lt 45; $i++) { Start-Sleep -Seconds 1; if (Get-DoubaoWindow) { return $true } }
    return $false
}

function Save-Shot {
    param([string]$Name)
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap ($b.Width), ($b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $path = Join-Path $LogDir ('{0}_{1}.png' -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmssfff'))
    $bytes = $ms.ToArray(); $ms.Dispose()
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $fs.Write($bytes, 0, $bytes.Length); $fs.Flush(); $fs.Dispose()
    return $path
}

function Click-At {
    param([int]$X, [int]$Y)
    [void][ClaimWin32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 250
    [ClaimWin32]::mouse_event(0x0002, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 120
    [ClaimWin32]::mouse_event(0x0004, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 700
}

# ---------- UI 自动化辅助 ----------
function Get-Root { param($Hwnd) [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd) }

function Find-ByName {
    param($Root, [string]$Name, [switch]$Contains)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        try {
            $n = $e.Current.Name
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($Contains) { if ($n -cmatch $Name) { return $e } } else { if ($n -eq $Name) { return $e } }
        } catch {}
    }
    return $null
}

function Get-AllNamed {
    param($Root)
    $out = @()
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        try {
            $n = $e.Current.Name
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $out += [pscustomobject]@{ El = $e; Name = $n; Type = ($e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '') }
        } catch {}
    }
    return $out
}

function Invoke-Element {
    param($El)
    try {
        $p = $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke()
        return 'Invoke'
    } catch {
        try {
            $pt = $El.GetClickablePoint()
            Click-At -X ([int]$pt.X) -Y ([int]$pt.Y)
            return 'Click'
        } catch { return 'None' }
    }
}

function Get-CreditInfo {
    # 从头像弹出菜单里读“可用额度 X”与“N 次额度重置”
    param($Root)
    $info = [pscustomobject]@{ Credit = $null; Reset = $null }
    foreach ($it in (Get-AllNamed -Root $Root)) {
        if ($it.Name -match '^可用额度') { $info.Credit = $it.Name }
        elseif ($it.Name -match '额度重置') { $info.Reset = $it.Name }
    }
    return $info
}

# ================== 主流程 ==================
Write-Log '===== 豆包每日领取开始（v2 UI自动化） ====='

if (-not (Start-DoubaoClient)) { Write-Log '豆包客户端不可用，结束。' 'ERROR'; exit 1 }

if ($RestartClient) {
    Write-Log '按配置重启客户端，触发当日首次登录。'
    Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    if (-not (Start-DoubaoClient)) { Write-Log '重启后客户端不可用，结束。' 'ERROR'; exit 1 }
    Start-Sleep -Seconds 5
}
Start-Sleep -Seconds 2

$win = Get-DoubaoWindow | Sort-Object W -Descending | Select-Object -First 1
if (-not $win) { Write-Log '未找到豆包主窗口，结束。' 'ERROR'; exit 1 }

[void][ClaimWin32]::ShowWindow($win.Hwnd, 9)
[void][ClaimWin32]::MoveWindow($win.Hwnd, $WinX, $WinY, $WinW, $WinH, $true)
Start-Sleep -Milliseconds 600
[void][ClaimWin32]::SetForegroundWindow($win.Hwnd)
Start-Sleep -Seconds 1
Write-Log ('已激活客户端窗口：' + $win.Title)

$root = Get-Root $win.Hwnd

# 1) 先看当天首次打开客户端时是否弹出“签到”框（PC 端正牌入口就在这里）
$popupHit = $null
for ($i = 0; $i -lt 10; $i++) {
    foreach ($it in (Get-AllNamed -Root $root)) {
        if ($it.Name -notmatch '签到') { continue }
        if ($it.Name -match '项目主页|归档对话|^签到积分$') { continue }
        if ($it.Type -match 'Button|MenuItem|Hyperlink') { $popupHit = $it; break }
    }
    if ($popupHit) { break }
    Start-Sleep -Seconds 1
}
if ($popupHit) {
    Write-Log ('发现签到弹窗按钮：' + $popupHit.Name)
    [void](Invoke-Element -El $popupHit.El)
    Start-Sleep -Seconds 3
    Save-Shot 'popup_claimed' | Out-Null
    Write-Log '===== 已点击签到弹窗（成功） ====='
    exit 0
}
Write-Log '未出现签到弹窗，继续打开额度页核对状态。'

# 2) 点头像，读当前额度
Click-At -X ($WinX + $AvatarRelX) -Y ($WinY + $AvatarRelY)
Start-Sleep -Milliseconds 1400
$before = Get-CreditInfo -Root $root
if (-not $before.Credit) {
    Write-Log '第一次点头像未弹出菜单，重试一次。'
    Click-At -X ($WinX + $AvatarRelX) -Y ($WinY + $AvatarRelY)
    Start-Sleep -Milliseconds 1600
    $before = Get-CreditInfo -Root $root
}
Write-Log ('领取前：{0}；{1}。' -f $before.Credit, $before.Reset)

# 2) 打开“免费用豆包工作”额度页（必须点菜单项，不能选到同名标签页）
$entry = $null
foreach ($it in (Get-AllNamed -Root $root)) {
    if ($it.Name -eq '免费用豆包工作' -and $it.Type -eq 'MenuItem') { $entry = $it.El; break }
}
if (-not $entry) {
    # 标签页已存在时，菜单可能不在，退化为直接激活该标签页
    foreach ($it in (Get-AllNamed -Root $root)) {
        if ($it.Name -eq '免费用豆包工作' -and $it.Type -eq 'TabItem') {
            Write-Log '额度页标签已存在，直接激活。'
            [void](Invoke-Element -El $it.El)
            $entry = $it.El
            break
        }
    }
}
if (-not $entry) {
    Save-Shot 'menu_notfound' | Out-Null
    Write-Log '菜单里没有“免费用豆包工作”，可能未登录或界面改版。' 'ERROR'
    exit 1
}
$how = Invoke-Element -El $entry
Write-Log ('点击菜单项「免费用豆包工作」（' + $how + '）')
Start-Sleep -Seconds $PageWait

# 3) 确认额度页已打开
$page = $root
$opened = $null
for ($i = 0; $i -lt 3; $i++) {
    $opened = Find-ByName -Root $root -Name '从容开工.*额度天天送' -Contains
    if (-not $opened) { $opened = Find-ByName -Root $root -Name '签到领额度' -Contains }
    if ($opened) { break }
    Start-Sleep -Seconds 2
}
$shot = Save-Shot 'credit_page'
if (-not $opened) {
    Write-Log '额度页没有打开（未找到签到/额度区域），结束。' 'ERROR'
    Write-Log ('截图：' + $shot)
    exit 1
}
Write-Log '额度页已打开。'

# 4) 只在额度页文档范围内找签到入口（避免误点左侧栏里同名的项目/对话）
$doc = $null
try {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $opened
    for ($i = 0; $i -lt 15 -and $cur; $i++) {
        if ($cur.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document) { $doc = $cur; break }
        $cur = $walker.GetParent($cur)
    }
} catch {}
$scope = if ($doc) { $doc } else { $root }
if ($doc) { Write-Log ('已定位额度页文档，大小 {0}x{1}' -f [int]$doc.Current.BoundingRectangle.Width, [int]$doc.Current.BoundingRectangle.Height) }

$signBtn = $null
$signStates = @()
$doneFlag = $false
foreach ($it in (Get-AllNamed -Root $scope)) {
    if ($it.Name -notmatch '签到') { continue }
    $signStates += ('[{0}] {1}' -f $it.Type, $it.Name)
    if ($it.Name -match '已签到|已领取|明天再来') { $doneFlag = $true }
    if (-not $signBtn -and $it.Type -match 'Button|MenuItem|Hyperlink|Link' -and $it.Name -notmatch '项目主页|归档对话') { $signBtn = $it.El }
}
foreach ($s in $signStates) { Write-Log ('额度页签到相关节点：' + $s) }

if (-not $signBtn) {
    if ($doneFlag) { Write-Log '页面显示已签到/已领取，今日无需重复操作。' }
    else { Write-Log '额度页里没有可点的签到按钮（当前版签到区只有说明文字，可能需要手机端/活动页签到）。' 'WARN' }
    # 收尾：关闭该标签页，避免影响后续使用
    $close = $null
    foreach ($it in (Get-AllNamed -Root $root)) {
        if ($it.Name -match '关闭标签页' -and $it.Name -match '豆包工作') { $close = $it.El; break }
    }
    if ($close) { [void](Invoke-Element -El $close) }
    Write-Log ('截图：' + $shot)
    Write-Log '===== 结束（今日无签到按钮，已记录） ====='
    exit 2
}

Write-Log ('点击签到：' + $signBtn.Current.Name)
[void](Invoke-Element -El $signBtn)
Start-Sleep -Seconds 3
Save-Shot 'after_claim' | Out-Null

# 5) 复核额度是否变化
Click-At -X ($WinX + $AvatarRelX) -Y ($WinY + $AvatarRelY)
Start-Sleep -Milliseconds 1400
$after = Get-CreditInfo -Root $root
Write-Log ('领取后：{0}；{1}。' -f $after.Credit, $after.Reset)
[ClaimWin32]::keybd_event(0x1B, 0, 0, 0)
[ClaimWin32]::keybd_event(0x1B, 0, 2, 0)

Write-Log '===== 豆包每日领取结束 ====='
exit 0