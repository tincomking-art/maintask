<#
.SYNOPSIS
    找出会弹黑色控制台窗口的计划任务，改成后台静默执行（可一键还原）。

.DESCRIPTION
    计划任务里 cmd / powershell / python / .bat 这类「控制台程序」，
    只要任务是「只在用户登录时运行」，每次触发都会在桌面上闪一个黑框。
    加 -WindowStyle Hidden 也没用：窗口是 Windows 先建好再交给程序的，照样会闪一下。

    本脚本的做法：编译一个极小的无窗口启动器 RunHidden.exe（GUI 子系统，本身没有窗口），
    把任务的「程序」换成 RunHidden.exe，原来的程序和参数原样挪到它后面。
    RunHidden 用 CREATE_NO_WINDOW 启动原程序并等待它结束、透传退出码，
    所以任务的触发器、运行账户、工作目录、「上次运行结果」都跟原来一样，只是不再弹窗。

    不带参数运行只列出候选任务，不做任何修改。

.EXAMPLE
    .\Hide-TaskWindows.ps1
    只扫描并列出会弹窗的任务（按触发频率排序）。

.EXAMPLE
    .\Hide-TaskWindows.ps1 -Apply
    把列出的任务全部改成静默执行，修改前自动备份原始任务 XML。

.EXAMPLE
    .\Hide-TaskWindows.ps1 -Apply -TaskName '\MyScripts\*', '*sync*'
    只处理匹配的任务（匹配「路径+名称」，支持通配符）。

.EXAMPLE
    .\Hide-TaskWindows.ps1 -Restore
    从备份还原所有被本脚本改过的任务。
#>
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(ParameterSetName = 'Apply', Mandatory = $true)]
    [switch]$Apply,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore,

    # 只处理「路径+名称」匹配的任务，例如 '\MyScripts\*'、'*backup*'
    [string[]]$TaskName = @('*'),

    # 默认跳过 \Microsoft\ 下的系统任务
    [switch]$IncludeMicrosoft,

    [string]$InstallDir = (Join-Path $env:ProgramData 'RunHidden')
)

$ErrorActionPreference = 'Stop'
$Launcher = Join-Path $InstallDir 'RunHidden.exe'
$BackupDir = Join-Path $InstallDir 'backup'
$IndexFile = Join-Path $BackupDir 'index.json'

# ---------------------------------------------------------------------------
# 无窗口启动器源码。用法：RunHidden.exe "<程序>" [参数...]
# 只用 ASCII，避免 csc 读源码时的编码问题。
# ---------------------------------------------------------------------------
$LauncherSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;

static class RunHidden
{
    // Split a Windows command line into its first token (unquoted) and the raw remainder.
    static void SplitFirst(string line, out string first, out string rest)
    {
        line = line.TrimStart();
        int end;
        if (line.StartsWith("\""))
        {
            end = line.IndexOf('"', 1);
            if (end < 0) end = line.Length;
            first = line.Substring(1, Math.Max(0, end - 1));
            end = Math.Min(line.Length, end + 1);
        }
        else
        {
            end = 0;
            while (end < line.Length && !char.IsWhiteSpace(line[end])) end++;
            first = line.Substring(0, end);
        }
        rest = line.Substring(end).TrimStart();
    }

    [STAThread]
    static int Main()
    {
        string self, rest, file, args;
        SplitFirst(Environment.CommandLine, out self, out rest);
        if (rest.Length == 0) return 87; // ERROR_INVALID_PARAMETER
        SplitFirst(rest, out file, out args);
        file = Environment.ExpandEnvironmentVariables(file);

        string ext = Path.GetExtension(file).ToLowerInvariant();
        if (ext == ".bat" || ext == ".cmd")
        {
            args = "/d /s /c \"\"" + file + "\" " + args + "\"";
            file = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        }

        ProcessStartInfo psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = Environment.CurrentDirectory;
        try
        {
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Win32Exception e)
        {
            return e.NativeErrorCode != 0 ? e.NativeErrorCode : 1;
        }
    }
}
'@

function Install-Launcher {
    if (Test-Path $Launcher) { return }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw '找不到 .NET Framework 4 自带的 csc.exe，无法编译 RunHidden.exe。' }

    $src = Join-Path $InstallDir 'RunHidden.cs'
    [IO.File]::WriteAllText($src, $LauncherSource, [Text.Encoding]::ASCII)
    $out = & $csc /nologo /optimize+ /target:winexe "/out:$Launcher" $src 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Launcher)) {
        throw "编译 RunHidden.exe 失败：`n$($out -join "`n")"
    }
    Write-Host "已生成启动器：$Launcher" -ForegroundColor Green
}

# PE 头里的 Subsystem：3 = Windows 控制台程序（会建黑框），2 = GUI 程序（不会）
function Test-ConsoleSubsystem([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object IO.BinaryReader($fs)
            if ($br.ReadUInt16() -ne 0x5A4D) { return $false }      # 'MZ'
            $fs.Position = 0x3C
            $pe = $br.ReadInt32()
            $fs.Position = $pe
            if ($br.ReadUInt32() -ne 0x00004550) { return $false }  # 'PE\0\0'
            $fs.Position = $pe + 4 + 20 + 68                         # OptionalHeader.Subsystem
            return $br.ReadUInt16() -eq 3
        } finally { $fs.Dispose() }
    } catch { return $false }
}

function Resolve-TaskProgram([string]$Execute, [string]$WorkingDirectory) {
    $exe = [Environment]::ExpandEnvironmentVariables($Execute.Trim().Trim('"'))
    if (-not $exe) { return $null }
    $names = @($exe)
    if (-not [IO.Path]::GetExtension($exe)) { $names += "$exe.exe" }
    foreach ($n in $names) {
        if ([IO.Path]::IsPathRooted($n)) {
            if (Test-Path -LiteralPath $n -PathType Leaf) { return $n }
            continue
        }
        if ($WorkingDirectory) {
            $p = Join-Path ([Environment]::ExpandEnvironmentVariables($WorkingDirectory.Trim('"'))) $n
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
        $cmd = Get-Command -Name $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Test-ShowsConsole($Action) {
    if ($Action.CimClass.CimClassName -ne 'MSFT_TaskExecAction') { return $false }
    $path = Resolve-TaskProgram $Action.Execute $Action.WorkingDirectory
    if (-not $path) { return $false }
    if ([IO.Path]::GetFileName($path) -ieq 'RunHidden.exe') { return $false }
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -in '.bat', '.cmd') { return $true }
    return (Test-ConsoleSubsystem $path)
}

function Get-TriggerSummary($Task) {
    $minInterval = [TimeSpan]::MaxValue
    $parts = foreach ($t in $Task.Triggers) {
        if (-not $t.Enabled) { continue }
        $kind = $t.CimClass.CimClassName -replace '^MSFT_Task|Trigger$', ''
        switch ($kind) {
            'Logon'  { $iv = [TimeSpan]::MaxValue }
            'Boot'   { $iv = [TimeSpan]::MaxValue }
            'Daily'  { $iv = [TimeSpan]::FromDays([Math]::Max(1, [int]$t.DaysInterval)) }
            'Weekly' { $iv = [TimeSpan]::FromDays(7) }
            'Idle'   { $iv = [TimeSpan]::FromMinutes(10) }
            'Event'  { $iv = [TimeSpan]::FromMinutes(1) }   # 事件触发，可能非常频繁
            'SessionStateChange' { $iv = [TimeSpan]::FromHours(1) }  # 锁屏/解锁/远程连接
            ''       { $kind = 'Other'; $iv = [TimeSpan]::FromDays(1) }
            default  { $iv = [TimeSpan]::FromDays(1) }
        }
        $rep = $t.Repetition.Interval
        if ($rep) {
            $iv = [Xml.XmlConvert]::ToTimeSpan($rep)
            $kind += " 每 $($iv.ToString())"
        }
        if ($iv -lt $minInterval) { $minInterval = $iv }
        $kind
    }
    [pscustomobject]@{ Text = ($parts -join ', '); MinInterval = $minInterval }
}

function Get-TaskKey($Task) { $Task.TaskPath + $Task.TaskName }

function Read-Index {
    if (-not (Test-Path $IndexFile)) { return @() }
    # Windows PowerShell 5.1 的 ConvertFrom-Json 会把整个数组当成一个对象输出，这里手动展开
    return @((ConvertFrom-Json -InputObject (Get-Content -Raw -Encoding UTF8 $IndexFile)) | ForEach-Object { $_ })
}

function Write-Index($Entries) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    ConvertTo-Json -InputObject @($Entries) -Depth 3 | Set-Content -Encoding UTF8 $IndexFile
}

# ---------------------------------------------------------------------------
# 还原
# ---------------------------------------------------------------------------
if ($Restore) {
    $index = Read-Index
    if (-not $index) { Write-Host '没有找到备份，无需还原。'; return }
    $left = foreach ($e in $index) {
        $key = $e.TaskPath + $e.TaskName
        if (-not ($TaskName | Where-Object { $key -like $_ })) { $e; continue }
        try {
            $xml = Get-Content -Raw -LiteralPath (Join-Path $BackupDir $e.File)
            Register-ScheduledTask -Xml $xml -TaskPath $e.TaskPath -TaskName $e.TaskName -Force | Out-Null
            Remove-Item -LiteralPath (Join-Path $BackupDir $e.File)
            Write-Host "已还原：$key" -ForegroundColor Green
        } catch {
            Write-Warning "还原失败：$key —— $($_.Exception.Message)"
            $e
        }
    }
    Write-Index @($left)
    return
}

# ---------------------------------------------------------------------------
# 扫描
# ---------------------------------------------------------------------------
# 这几种登录类型跑在后台会话（session 0），本来就不会有窗口
$backgroundLogon = 'Password', 'S4U', 'ServiceAccount'

$candidates = foreach ($task in Get-ScheduledTask) {
    $key = Get-TaskKey $task
    if (-not $IncludeMicrosoft -and $task.TaskPath -like '\Microsoft\*') { continue }
    if (-not ($TaskName | Where-Object { $key -like $_ })) { continue }
    if ([string]$task.Principal.LogonType -in $backgroundLogon) { continue }

    $consoleActions = @($task.Actions | Where-Object { Test-ShowsConsole $_ })
    if (-not $consoleActions) { continue }

    $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    $trig = Get-TriggerSummary $task
    [pscustomobject]@{
        Task        = $key
        State       = $task.State
        Trigger     = $trig.Text
        LastRun     = if ($info -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime } else { $null }
        Command     = ($consoleActions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
        MinInterval = $trig.MinInterval
        Object      = $task
    }
}
$candidates = @($candidates | Sort-Object MinInterval, Task)

if (-not $candidates) {
    Write-Host '没有发现会弹控制台窗口的计划任务。' -ForegroundColor Green
    Write-Host '黑框可能来自常驻程序（非计划任务），请运行 .\Find-ConsoleFlash.ps1 抓取来源。'
    return
}

Write-Host "`n会弹黑框的计划任务（按触发频率从高到低）：" -ForegroundColor Yellow
$candidates | Format-Table -AutoSize -Wrap Task, State, Trigger, LastRun, Command | Out-Host

if (-not $Apply) {
    Write-Host '以上仅为扫描结果，未做修改。确认后运行：.\Hide-TaskWindows.ps1 -Apply  （可配合 -TaskName 只改部分）'
    return
}

# ---------------------------------------------------------------------------
# 修改
# ---------------------------------------------------------------------------
Install-Launcher
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$index = [Collections.ArrayList]@(Read-Index)

foreach ($c in $candidates) {
    $task = $c.Object
    try {
        # 只保留第一次的备份，那才是原始配置
        if (-not ($index | Where-Object { $_.TaskPath -eq $task.TaskPath -and $_.TaskName -eq $task.TaskName })) {
            $file = '{0:yyyyMMddHHmmss}_{1}.xml' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0, 8))
            Export-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName |
                Set-Content -Encoding Unicode -LiteralPath (Join-Path $BackupDir $file)
            [void]$index.Add([pscustomobject]@{ TaskPath = $task.TaskPath; TaskName = $task.TaskName; File = $file })
            Write-Index $index
        }

        $newActions = foreach ($a in $task.Actions) {
            if (-not (Test-ShowsConsole $a)) { $a; continue }
            $argLine = ('"{0}" {1}' -f $a.Execute.Trim().Trim('"'), $a.Arguments).Trim()
            $p = @{ Execute = $Launcher; Argument = $argLine }
            if ($a.WorkingDirectory) { $p.WorkingDirectory = $a.WorkingDirectory }
            New-ScheduledTaskAction @p
        }
        Set-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Action $newActions | Out-Null
        Write-Host "已改为静默执行：$($c.Task)" -ForegroundColor Green
    } catch {
        Write-Warning "修改失败：$($c.Task) —— $($_.Exception.Message)"
    }
}

Write-Host "`n完成。原始配置备份在 $BackupDir ，如需还原：.\Hide-TaskWindows.ps1 -Restore"
