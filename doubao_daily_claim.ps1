<#
豆包每日自动领取积分/额度 v3（UI 自动化版 + 领后自动核对额度）
------------------------------------------------------------------
v3 相对 v2 的改动（2026-11-21）：
  1) 【新增】点完签到后自动复核额度：点头像读「可用额度 X」，和最近一次日志里的数值对比，
     把“上次 8905 → 本次 9105（+200）”这样的证据直接写进日志；读不到则记 WARN，不算失败。
  2) 【修复】头像不再靠固定坐标：用 UI 自动化定位名字含「套餐」的账号按钮，再用真实鼠标点击它的中心
     （Electron 的账号菜单对 InvokePattern 没反应，实测只有真实点击才弹出）；找不到才退回相对坐标。
  3) 【修复】窗口识别：排除“豆包浏览器/[AIEP]”窗口（之前按“标题含豆包 + 最宽”会误选浏览器），
     并要求进程名为 Doubao。
  4) 【增强】窗口可能枚举不到（缩到托盘/会话切换），改为带重试的查找 + 自动把隐藏窗口恢复出来；
     读额度最多重试 N 次；日志首行会打印“脚本所在会话/客户端所在会话”，用于排查会话隔离。
  5) 签到入口先扫“当日首次打开客户端的签到弹窗”，扫不到再走额度页；两条路径都带额度复核。

退出码：
  0 = 已领取（或今日已完成）
  2 = 没找到可点的签到入口（已记录状态，需人工看一眼）
  1 = 客户端窗口/额度页打不开

运行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File "doubao_daily_claim.ps1"
#>

$ErrorActionPreference = 'Stop'

# ================= 配置区 =================
$WinX = 158; $WinY = 162; $WinW = 1200; $WinH = 800   # 客户端窗口固定位置与大小
$AvatarRelX = 65; $AvatarRelY = 764                    # 头像在窗口内的相对坐标（仅作兜底）
$PageWait = 7                                          # 打开额度页后的等待秒数
$PopupWait = 12                                        # 等待“签到弹窗”出现的最长秒数
$CreditRetries = 4                                     # 读额度（点头像）最多尝试次数
$VerifyCredit = $true                                  # 领取后是否复核额度并写日志
$RestartClient = $false                                # $true = 每天先关掉再重开客户端，强制触发“当日首次登录”
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

function Get-DoubaoWindows {
    # 统一收集“豆包进程的大窗口”；可见性与标题由调用方筛选（单一代码路径，避免两条枚举逻辑不一致）
    param([int]$MinW = 600, [int]$MinH = 400)
    $items = New-Object System.Collections.ArrayList
    $cb = [ClaimWin32+EnumProc]{ param($h, $l)
        $pv = 0
        [void][ClaimWin32]::GetWindowThreadProcessId($h, [ref]$pv)
        if (-not $pv) { return $true }
        $pn = ''
        try { $pn = (Get-Process -Id $pv -ErrorAction Stop).ProcessName } catch { return $true }
        if ($pn -ne 'Doubao') { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        [void][ClaimWin32]::GetWindowText($h, $sb, 256)
        $ttl = $sb.ToString()
        $r = New-Object ClaimWin32+RECT
        [void][ClaimWin32]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
        if ($w -lt $MinW -or $ht -lt $MinH) { return $true }
        [void]$items.Add([pscustomobject]@{
            Hwnd = $h; Title = $ttl; Pid = $pv; Vis = [ClaimWin32]::IsWindowVisible($h)
            Left = $r.Left; Top = $r.Top; W = $w; Ht = $ht
        })
        return $true
    }
    [void][ClaimWin32]::EnumWindows($cb, [IntPtr]::Zero)
    return $items
}

function Test-ClientWindow {
    param($W)
    if (-not $W.Vis) { return $false }
    if ([string]::IsNullOrWhiteSpace($W.Title)) { return $false }
    if ($W.Title -notmatch '豆包') { return $false }
    if ($W.Title -match '浏览器|AIEP') { return $false }
    return $true
}

function Select-DoubaoWindow {
    param([int]$Retries = 8)
    for ($i = 0; $i -lt $Retries; $i++) {
        $wins = Get-DoubaoWindows
        $strict = @($wins | Where-Object { Test-ClientWindow $_ })
        if ($strict.Count -gt 0) {
            $best = $null
            foreach ($w in $strict) { if ($w.Title -match '-\s*豆包$') { $best = $w; break } }
            if (-not $best) { $best = $strict | Sort-Object W -Descending | Select-Object -First 1 }
            return $best
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Restore-DoubaoWindow {
    # 找不到可见窗口时：把客户端隐藏/最小化的窗口恢复出来（不重启进程，避免打断正在用的会话）
    param([int]$Wait = 8)
    $wins = Get-DoubaoWindows
    if (-not $wins -or $wins.Count -eq 0) {
        Write-Log '备选扫描：没有找到任何豆包客户端窗口。' 'WARN'
        return $null
    }
    foreach ($lw in $wins) { Write-Log ('备选窗口：hwnd={0} pid={1} vis={2} {3}x{4} 标题="{5}"' -f $lw.Hwnd, $lw.Pid, $lw.Vis, $lw.W, $lw.Ht, $lw.Title) }

    $pick = $null
    foreach ($lw in $wins) { if ($lw.Title -match '-\s*豆包$') { $pick = $lw; break } }
    if (-not $pick) {
        foreach ($lw in $wins) { if ($lw.W -ge 900 -and $lw.W -le 1400 -and $lw.Ht -ge 600 -and $lw.Ht -le 900) { $pick = $lw; break } }
    }
    if (-not $pick) { $pick = $wins | Sort-Object W -Descending | Select-Object -First 1 }
    Write-Log ('选中恢复窗口：hwnd={0} {1}x{2} 标题="{3}"' -f $pick.Hwnd, $pick.W, $pick.Ht, $pick.Title)

    [void][ClaimWin32]::ShowWindow([IntPtr]$pick.Hwnd, 9)    # SW_RESTORE
    Start-Sleep -Milliseconds 500
    [void][ClaimWin32]::ShowWindow([IntPtr]$pick.Hwnd, 5)    # SW_SHOW
    [void][ClaimWin32]::MoveWindow([IntPtr]$pick.Hwnd, $WinX, $WinY, $WinW, $WinH, $true)
    [void][ClaimWin32]::SetForegroundWindow([IntPtr]$pick.Hwnd)

    $again = Select-DoubaoWindow -Retries $Wait
    if ($again) { Write-Log '窗口已恢复并重新枚举成功。'; return $again }
    Write-Log '窗口已恢复，但严格枚举仍未命中，直接使用该窗口继续。' 'WARN'
    return $pick
}
function Find-ClientExe {
    $proc = Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return $proc.Path }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Doubao\Doubao.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Doubao\Doubao.exe'),
        (Join-Path $env:ProgramFiles 'Doubao\Doubao.exe'),
        'C:\Sofaware\Doubao\app\Doubao.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates) { return $candidates[0] }
    return $null
}


function Start-DoubaoClient {
    if (Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue) { return $true }
    $exe = Find-ClientExe
    if (-not $exe) { Write-Log '未找到豆包客户端可执行文件，请手动启动。' 'ERROR'; return $false }
    Write-Log ('启动豆包客户端：' + $exe)
    Start-Process -FilePath $exe | Out-Null
    for ($i = 0; $i -lt 45; $i++) { Start-Sleep -Seconds 1; if (Select-DoubaoWindow -Retries 1) { return $true } }
    return $false
}

function Ensure-ClientWindow {
    # 窗口枚举偶尔会失败（客户端缩到托盘/窗口被销毁重建）：重新唤起单实例客户端，再找一次
    param([int]$Retries = 15)
    $win = Select-DoubaoWindow -Retries 6
    if ($win) { return $win }
    $exe = Find-ClientExe
    if ($exe) {
        Write-Log ('未枚举到窗口，重新唤起客户端：' + $exe)
        try { Start-Process -FilePath $exe | Out-Null } catch { Write-Log ('唤起失败：' + $_.Exception.Message) 'WARN' }
    } else {
        Write-Log '找不到客户端可执行文件，无法唤起。' 'WARN'
    }
    return (Select-DoubaoWindow -Retries $Retries)
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

function Close-Menu {
    [ClaimWin32]::keybd_event(0x1B, 0, 0, 0)
    [ClaimWin32]::keybd_event(0x1B, 0, 2, 0)
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
    # 只认菜单里的短小节点（宽<320、高<80），避免把右侧对话正文里的“可用额度/额度重置”当成菜单项
    param($Root)
    $info = [pscustomobject]@{ Credit = $null; Reset = $null }
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        try {
            $n = $e.Current.Name
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($n.Length -gt 60) { continue }
            $r = $e.Current.BoundingRectangle
            if ($r.IsEmpty) { continue }
            if ($r.Width -gt 320 -or $r.Height -gt 80) { continue }

            if ($n -match '^可用额度') {
                if ($n -match '^可用额度\s*([0-9][0-9,，]*)') {
                    $info.Credit = '可用额度 ' + $Matches[1]
                } else {
                    # 菜单里常见“可用额度”标签 + 数值是两个节点：从兄弟节点里取数字
                    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
                    $parent = $walker.GetParent($e)
                    if ($parent) {
                        $pn = $parent.Current.Name
                        if ($pn -and $pn -match '可用额度\s*([0-9][0-9,，]*)') { $info.Credit = '可用额度 ' + $Matches[1] }
                    }

                }
            }
            elseif ($n -match '([0-9]+)\s*次额度重置' -or $n -match '^额度重置') {
                $info.Reset = $n
            }
        } catch {}
    }
    return $info
}

function Find-AvatarButton {
    # 账号按钮：窗口左下角、名字含“套餐”（实测为「奔走四方 标准套餐」）
    param($Root, $Win)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $fallback = $null
    foreach ($e in $all) {
        try {
            if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
            $r = $e.Current.BoundingRectangle
            if ($r.IsEmpty) { continue }
            if ($r.Y -lt ($Win.Top + $Win.Ht - 220)) { continue }
            if ($r.X -gt ($Win.Left + 400)) { continue }
            $n = $e.Current.Name
            if ($n -and $n -match '套餐') { return $e }
            if (-not $fallback -and $r.Height -le 60 -and $r.Width -ge 150) { $fallback = $e }
        } catch {}
    }
    return $fallback
}

function Test-CreditOk {
    param($Info)
    if ($Info.Credit -and ($Info.Credit -match '[0-9]')) { return $true }
    if ($Info.Reset -and ($Info.Reset -match '[0-9]')) { return $true }
    return $false
}

function Read-Credit {
    # 点头像读额度，带重试；读不到返回空值，不抛错
    # 注意：Electron 的账号菜单只对真实鼠标点击有反应，InvokePattern 常常点不开，所以这里用坐标点击。
    param($Hwnd, $Win, [int]$Retries = 3)
    $root = Get-Root $Hwnd
    for ($i = 1; $i -le $Retries; $i++) {
        $info = Get-CreditInfo -Root $root
        if (Test-CreditOk $info) { Close-Menu; return $info }

        $av = Find-AvatarButton -Root $root -Win $Win
        if ($av) {
            try {
                $r = $av.Current.BoundingRectangle
                $cx = [int]($r.X + $r.Width / 2)
                $cy = [int]($r.Y + $r.Height / 2)
                Click-At -X $cx -Y $cy
                Write-Log ('第 {0} 次读额度：点击头像按钮中心（{1},{2}）' -f $i, $cx, $cy)
            } catch {
                Write-Log ('第 {0} 次读额度：头像按钮取坐标失败，改用相对坐标' -f $i) 'WARN'
                Click-At -X ($Win.Left + $AvatarRelX) -Y ($Win.Top + $AvatarRelY)
            }
        } else {
            Click-At -X ($Win.Left + $AvatarRelX) -Y ($Win.Top + $AvatarRelY)
            Write-Log ('第 {0} 次读额度：按相对坐标点头像' -f $i)
        }
        Start-Sleep -Milliseconds 1600
        $info = Get-CreditInfo -Root $root
        if (Test-CreditOk $info) { Close-Menu; return $info }
        Close-Menu
        Start-Sleep -Milliseconds 700
    }
    return ([pscustomobject]@{ Credit = $null; Reset = $null })
}

function ConvertTo-CreditNumber {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '([0-9][0-9,，]*)')
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value -replace '[,，]', ''
    try { return [int]$v } catch { return $null }
}

function Get-LastLoggedCredit {
    # 从历史日志里取最近一次的“可用额度”数值，用于计算今天的变化
    $files = Get-ChildItem -Path $LogDir -Filter 'doubao_claim_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try { $text = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        $ms = [regex]::Matches($text, '可用额度\s*([0-9][0-9,，]*)')
        if ($ms.Count -gt 0) {
            $val = $ms[$ms.Count - 1].Groups[1].Value -replace '[,，]', ''
            try { return [pscustomobject]@{ Value = [int]$val; File = $f.Name } } catch { continue }
        }
    }
    return $null
}

function Write-CreditCheck {
    param($Hwnd, $Win, [string]$Tag)
    $last = Get-LastLoggedCredit
    $after = Read-Credit -Hwnd $Hwnd -Win $Win -Retries $CreditRetries
    if (-not $after.Credit) {
        Write-Log ($Tag + '未能读到额度（头像菜单没有弹出），本次只记录签到动作。') 'WARN'
        return $null
    }
    $num = ConvertTo-CreditNumber -Text $after.Credit
    if ($num -ne $null -and $last) {
        $delta = $num - $last.Value
        Write-Log ('{0}可用额度 {1}（上次记录 {2}，变化 {3:+0;-0;0}）' -f $Tag, $after.Credit, $last.Value, $delta)
    } else {
        Write-Log ('{0}可用额度 {1}' -f $Tag, $after.Credit)
    }
    if ($after.Reset) { Write-Log ($Tag + '额度重置：' + $after.Reset) }

    if ($num -eq $null) {
        # 调试：菜单弹出了但没解析到数字，把附近的小节点打印出来，便于下次按真实结构取数
        Write-Log ($Tag + '菜单已弹出但没解析到数值，附近节点如下：') 'WARN'
        try {
            $root2 = Get-Root $Hwnd
            $all2 = $root2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $cnt = 0
            foreach ($e2 in $all2) {
                try {
                    $nm = $e2.Current.Name
                    if ([string]::IsNullOrWhiteSpace($nm)) { continue }
                    if ($nm.Length -gt 60) { continue }
                    $r = $e2.Current.BoundingRectangle
                    if ($r.IsEmpty) { continue }
                    if ($r.Width -gt 340 -or $r.Height -gt 90) { continue }
                    if ($nm -notmatch '额度|套餐|重置|次|[0-9]') { continue }
                    $ct = $e2.Current.ControlType.ProgrammaticName.Replace('ControlType.','')
                    Write-Log ('  节点：[{0}] "{1}" rect=({2},{3}) {4}x{5}' -f $ct, $nm, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
                    $cnt++
                    if ($cnt -ge 25) { break }
                } catch {}
            }
        } catch {}
    }
    return $num
}
function Find-SignButton {
    # 签到类可点节点（排除左侧栏同名项目/对话）
    param($Root)
    $out = @()
    foreach ($it in (Get-AllNamed -Root $Root)) {
        if ($it.Name -notmatch '签到') { continue }
        if ($it.Name -match '项目主页|归档对话|^签到积分$') { continue }
        if ($it.Type -notmatch 'Button|MenuItem|Hyperlink|Link') { continue }
        $out += $it
    }
    return $out
}

# ================== 主流程 ==================
Write-Log '===== 豆包每日领取开始（v3 UI自动化 + 额度复核） ====='

$mySid = 0
try { $mySid = (Get-Process -Id $PID).SessionId } catch {}
$cliSids = ''
try { $cliSids = ((Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SessionId -Unique) -join ',') } catch {}
Write-Log ('脚本所在会话=' + $mySid + '；客户端进程所在会话=' + $cliSids)

if (-not (Start-DoubaoClient)) { Write-Log '豆包客户端不可用，结束。' 'ERROR'; exit 1 }

if ($RestartClient) {
    Write-Log '按配置重启客户端，触发当日首次登录。'
    Get-Process -Name 'Doubao' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    if (-not (Start-DoubaoClient)) { Write-Log '重启后客户端不可用，结束。' 'ERROR'; exit 1 }
    Start-Sleep -Seconds 5
}
Start-Sleep -Seconds 2

$win = Select-DoubaoWindow -Retries 8
if (-not $win) {
    Write-Log '严格枚举没找到可见窗口，尝试恢复客户端窗口。'
    $win = Restore-DoubaoWindow -Wait 8
}
if (-not $win) { $win = Ensure-ClientWindow -Retries 10 }
if (-not $win) { Write-Log ('未找到豆包主窗口（枚举 20 次均失败）。脚本会话=' + $mySid + '，客户端会话=' + $cliSids + '。若两者不一致，说明脚本跑在了另一个登录会话里，看不到客户端的窗口。') 'ERROR'; exit 1 }

[void][ClaimWin32]::ShowWindow($win.Hwnd, 9)
[void][ClaimWin32]::MoveWindow($win.Hwnd, $WinX, $WinY, $WinW, $WinH, $true)
Start-Sleep -Milliseconds 600
[void][ClaimWin32]::SetForegroundWindow($win.Hwnd)
Start-Sleep -Seconds 1
Write-Log ('已激活客户端窗口：' + $win.Title + ('（pid=' + $win.Pid + '）'))

$root = Get-Root $win.Hwnd
$win = [pscustomobject]@{ Hwnd = $win.Hwnd; Title = $win.Title; Pid = $win.Pid; Left = $WinX; Top = $WinY; W = $WinW; Ht = $WinH }

# 1) 当天首次打开客户端时弹出的“签到”框（PC 端最可靠的入口）
$popupHit = $null
for ($i = 0; $i -lt $PopupWait; $i++) {
    $cands = Find-SignButton -Root $root
    if ($cands.Count -gt 0) { $popupHit = $cands[0]; break }
    Start-Sleep -Seconds 1
}

if ($popupHit) {
    Write-Log ('发现签到按钮：' + $popupHit.Name)
    [void](Invoke-Element -El $popupHit.El)
    Start-Sleep -Seconds 3

    $still = Find-SignButton -Root $root
    if ($still.Count -gt 0) {
        Write-Log ('点击后签到入口仍在：' + $still[0].Name + '（可能没点中，或已签到显示为对勾）') 'WARN'
    } else {
        Write-Log '点击后签到入口已消失（签到生效）。'
    }
    $shot = Save-Shot 'popup_claimed'
    Write-Log ('截图：' + $shot)

    if ($VerifyCredit) { [void](Write-CreditCheck -Hwnd $win.Hwnd -Win $win -Tag '签到后') }

    Write-Log '===== 已点击签到（成功） ====='
    exit 0
}
Write-Log ('{0} 秒内未出现签到弹窗，继续打开额度页核对状态。' -f $PopupWait)

# 2) 读当前额度
$before = $null
if ($VerifyCredit) { $before = Write-CreditCheck -Hwnd $win.Hwnd -Win $win -Tag '领取前' }
else { Write-Log '已关闭额度复核（$VerifyCredit=$false）。' }

# 3) 打开“免费用豆包工作”额度页（必须点菜单项，不能选到同名标签页）
$entry = $null
foreach ($it in (Get-AllNamed -Root $root)) {
    if ($it.Name -eq '免费用豆包工作' -and $it.Type -eq 'MenuItem') { $entry = $it.El; break }
}
if (-not $entry) {
    # 菜单没弹出时先点头像；标签页已存在则直接激活
    $av = Find-AvatarButton -Root $root -Win $win
    if ($av) { [void](Invoke-Element -El $av); Start-Sleep -Milliseconds 1500 } else { Click-At -X ($win.Left + $AvatarRelX) -Y ($win.Top + $AvatarRelY) }
    foreach ($it in (Get-AllNamed -Root $root)) {
        if ($it.Name -eq '免费用豆包工作' -and $it.Type -eq 'MenuItem') { $entry = $it.El; break }
        if ($it.Name -eq '免费用豆包工作' -and $it.Type -eq 'TabItem' -and -not $entry) { $entry = $it.El }
    }
    if ($entry) { Close-Menu }
}
if (-not $entry) {
    $shot = Save-Shot 'menu_notfound'
    Write-Log '菜单里没有“免费用豆包工作”，可能未登录或界面改版。' 'ERROR'
    Write-Log ('截图：' + $shot)
    exit 1
}
$how = Invoke-Element -El $entry
Write-Log ('点击菜单项「免费用豆包工作」（' + $how + '）')
Start-Sleep -Seconds $PageWait

# 4) 确认额度页已打开
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

# 5) 只在额度页文档范围内找签到入口（避免误点左侧栏同名项目/对话）
$doc = $null
try {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $opened
    for ($i = 0; $i -lt 15 -and $cur; $i++) {
        if ($cur.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document) { $doc = $cur; break }
        $cur = $walker.GetParent($cur)
    }
} catch {}
$scope = $root
if ($doc) {
    $scope = $doc
    Write-Log ('已定位额度页文档，大小 {0}x{1}' -f [int]$doc.Current.BoundingRectangle.Width, [int]$doc.Current.BoundingRectangle.Height)
}

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
    else { Write-Log '额度页里没有可点的签到按钮（当前版签到区只有说明文字）。' 'WARN' }
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

# 6) 复核额度是否变化
if ($VerifyCredit) { [void](Write-CreditCheck -Hwnd $win.Hwnd -Win $win -Tag '领取后') }

Write-Log '===== 豆包每日领取结束 ====='
exit 0
