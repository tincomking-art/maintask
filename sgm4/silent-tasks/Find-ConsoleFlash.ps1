<#
.SYNOPSIS
    抓出是谁在反复弹黑色控制台窗口。

.DESCRIPTION
    实时监听新进程（WMI Win32_ProcessStartTrace，短到几十毫秒的进程也抓得到），
    只记录「当前桌面会话里新开了控制台窗口」的那一类：
    控制台程序 + 父进程不是控制台程序（父进程是控制台的话会共用父窗口，不会新弹）。

    同时临时打开「任务计划程序」操作日志，用它把进程 PID 对回具体的计划任务名；
    结束时恢复日志原来的开关状态。

    按 Ctrl+C 或到时间后输出汇总，明细另存 CSV。

.EXAMPLE
    .\Find-ConsoleFlash.ps1
    监听 30 分钟（期间照常用电脑，等黑框出现几次）。

.EXAMPLE
    .\Find-ConsoleFlash.ps1 -Minutes 120
#>
#Requires -RunAsAdministrator
param(
    [int]$Minutes = 30,
    [string]$CsvPath = (Join-Path $PSScriptRoot ('console-flash-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date)))
)

$ErrorActionPreference = 'Stop'
$TaskLog = 'Microsoft-Windows-TaskScheduler/Operational'
$SourceId = 'ConsoleFlashWatch'

$subsystemCache = @{}
function Test-ConsoleExe([string]$Path) {
    if (-not $Path) { return $null }
    if ($subsystemCache.ContainsKey($Path)) { return $subsystemCache[$Path] }
    $r = $null
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object IO.BinaryReader($fs)
            if ($br.ReadUInt16() -eq 0x5A4D) {
                $fs.Position = 0x3C
                $pe = $br.ReadInt32()
                $fs.Position = $pe + 4 + 20 + 68                   # OptionalHeader.Subsystem
                $r = ($br.ReadUInt16() -eq 3)
            }
        } finally { $fs.Dispose() }
    } catch { }
    $subsystemCache[$Path] = $r
    return $r
}

function Get-ProcInfo([uint32]$Id, [string]$FallbackName) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
    $path = if ($p) { $p.ExecutablePath } else { $null }
    if (-not $path -and $FallbackName) {
        # 进程已经结束（闪一下就退出的正是这种），按名字在 PATH / System32 里找
        $cmd = Get-Command $FallbackName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $path = $cmd.Source }
    }
    [pscustomobject]@{
        Name        = if ($p) { $p.Name } else { $FallbackName }
        Path        = $path
        CommandLine = if ($p) { $p.CommandLine } else { $null }
    }
}

# 打开任务计划程序历史，用于把 PID 对应到任务名
$logCfg = Get-WinEvent -ListLog $TaskLog
$logWasEnabled = $logCfg.IsEnabled
if (-not $logWasEnabled) {
    $logCfg.IsEnabled = $true
    $logCfg.SaveChanges()
}

$started = Get-Date
$deadline = $started.AddMinutes($Minutes)
$records = New-Object Collections.Generic.List[object]
$ignore = 'conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe'

Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $SourceId
Write-Host "开始监听，持续 $Minutes 分钟（到 $($deadline.ToString('HH:mm:ss'))），按 Ctrl+C 提前结束并出汇总……" -ForegroundColor Cyan

try {
    while ((Get-Date) -lt $deadline) {
        $evt = Wait-Event -SourceIdentifier $SourceId -Timeout 2
        if (-not $evt) { continue }
        Remove-Event -EventIdentifier $evt.EventIdentifier
        $e = $evt.SourceEventArgs.NewEvent

        if ($e.SessionID -eq 0) { continue }                 # session 0 是后台，不可能有窗口
        if ($e.ProcessName -in $ignore) { continue }

        $child = Get-ProcInfo $e.ProcessID $e.ProcessName
        if ((Test-ConsoleExe $child.Path) -ne $true) { continue }

        $parent = Get-ProcInfo $e.ParentProcessID $null
        if ((Test-ConsoleExe $parent.Path) -eq $true) { continue } # 共用父进程的控制台，不会新弹窗
        if ($parent.Name -eq 'RunHidden.exe') { continue }          # 已经被 Hide-TaskWindows.ps1 处理过

        $rec = [pscustomobject]@{
            Time              = $evt.TimeGenerated
            ProcessId         = $e.ProcessID
            Process           = $e.ProcessName
            CommandLine       = $child.CommandLine
            ParentId          = $e.ParentProcessID
            Parent            = $parent.Name
            ParentCommandLine = $parent.CommandLine
            ScheduledTask     = $null
        }
        $records.Add($rec)
        Write-Host ('[{0:HH:mm:ss}] {1}  <-  {2}   {3}' -f $rec.Time, $rec.Process, $rec.Parent, $rec.CommandLine) -ForegroundColor Yellow
    }
}
finally {
    Unregister-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $SourceId -ErrorAction SilentlyContinue | Remove-Event

    # 事件 129 = "Created Task Process"：记录了任务名和它启动的进程 PID
    $pidToTask = @{}
    try {
        Get-WinEvent -FilterHashtable @{ LogName = $TaskLog; Id = 129; StartTime = $started } -ErrorAction Stop |
            ForEach-Object {
                $d = @{}
                foreach ($n in ([xml]$_.ToXml()).Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
                if ($d.ProcessID) { $pidToTask[[string]$d.ProcessID] = $d.TaskName }
            }
    } catch { }

    if (-not $logWasEnabled) {
        $logCfg = Get-WinEvent -ListLog $TaskLog
        $logCfg.IsEnabled = $false
        $logCfg.SaveChanges()
    }

    foreach ($r in $records) {
        $r.ScheduledTask = $pidToTask[[string]$r.ProcessId]
        if (-not $r.ScheduledTask) { $r.ScheduledTask = $pidToTask[[string]$r.ParentId] }
    }

    if ($records.Count -eq 0) {
        Write-Host "`n监听期间没有抓到新弹出的控制台窗口。可以加长 -Minutes 再试。" -ForegroundColor Green
    } else {
        $records | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
        Write-Host "`n===== 汇总（明细已保存到 $CsvPath）=====" -ForegroundColor Cyan
        $records |
            Group-Object Process, Parent, ScheduledTask |
            ForEach-Object {
                $g = $_.Group
                $span = ($g[-1].Time - $g[0].Time).TotalMinutes
                [pscustomobject]@{
                    次数       = $_.Count
                    平均间隔   = if ($_.Count -gt 1) { '{0:N1} 分钟' -f ($span / ($_.Count - 1)) } else { '-' }
                    弹窗进程   = $g[0].Process
                    父进程     = $g[0].Parent
                    计划任务   = $g[0].ScheduledTask
                    命令行示例 = $g[0].CommandLine
                }
            } |
            Sort-Object 次数 -Descending |
            Format-Table -AutoSize -Wrap | Out-Host

        Write-Host '怎么看：'
        Write-Host '  「计划任务」有值         -> 运行 .\Hide-TaskWindows.ps1 -Apply -TaskName ''<任务名>'' 改成静默执行'
        Write-Host '  父进程是 svchost.exe     -> 基本是计划任务；任务列为空时先跑 .\Hide-TaskWindows.ps1 看列表'
        Write-Host '  父进程是某个常驻软件     -> 不是计划任务，是那个软件自己在调命令行，需要在该软件里关掉对应功能或升级'
        Write-Host '注意：有些软件用「无窗口」方式调用命令行，同样会被记下来但其实不弹窗；'
        Write-Host '      以「平均间隔」和你实际看到黑框的频率/时间点能对上的那一行为准。'
    }
}
