# sgm4 黑框闪现：自动任务改为后台静默执行

现象：桌面上时不时闪一下黑色终端窗口，马上又消失，而且比较频繁。

原因：几乎都是**计划任务**（或常驻软件）定时调用 `cmd` / `powershell` / `python` / `.bat` 这类控制台程序。
任务设置成「只在用户登录时运行」时，Windows 每次都会给它在桌面上建一个控制台窗口；
程序跑完窗口就关，看起来就是「闪一下」。
在命令里加 `-WindowStyle Hidden` **没用**——窗口是先建好再交给 PowerShell 隐藏的，照样会闪。

这里的两个脚本：

| 脚本 | 作用 |
|------|------|
| [`Find-ConsoleFlash.ps1`](./Find-ConsoleFlash.ps1) | 实时监听，抓出每次弹黑框的是哪个程序、父进程是谁、对应哪个计划任务，最后按次数和间隔汇总 |
| [`Hide-TaskWindows.ps1`](./Hide-TaskWindows.ps1) | 扫描所有会弹黑框的计划任务，一键改为后台静默执行；自动备份，可一键还原 |

## 使用步骤

以**管理员**身份打开 PowerShell（开始菜单右键 → 终端(管理员)），进入脚本所在目录：

```powershell
# 从网上下载的脚本先解除锁定，并允许本窗口运行脚本
Get-ChildItem *.ps1 | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
```

### 1. 看看有哪些任务会弹窗（只读，不改任何东西）

```powershell
.\Hide-TaskWindows.ps1
```

列出所有「控制台程序 + 只在用户登录时运行」的计划任务，按触发频率从高到低排，
`Trigger` 一列里的 `每 00:05:00` 就是每 5 分钟跑一次——最频繁的那几个基本就是元凶。
默认跳过 `\Microsoft\` 下的系统任务，需要一起看就加 `-IncludeMicrosoft`。

### 2. 不确定是哪个？抓现行

```powershell
.\Find-ConsoleFlash.ps1              # 默认监听 30 分钟，Ctrl+C 可提前结束
.\Find-ConsoleFlash.ps1 -Minutes 120
```

期间照常用电脑，等黑框出现几次。结束后输出汇总：

- **计划任务** 一列有值 → 就是这个任务，下一步用 `-TaskName` 精确处理。
- 父进程是 `svchost.exe` → 基本也是计划任务。
- 父进程是某个常驻软件（代理客户端、同步盘、开发工具等） → 不是计划任务，是软件自己在调命令行，
  到该软件的设置里关掉对应功能或升级到新版本。

有些软件用「无窗口」方式调用命令行，也会被记下来但其实不弹窗，
以「平均间隔」和你实际看到黑框的频率对得上的那一行为准。明细另存为同目录下的 CSV。

### 3. 改成后台静默执行

```powershell
.\Hide-TaskWindows.ps1 -Apply                          # 处理第 1 步列出的全部任务
.\Hide-TaskWindows.ps1 -Apply -TaskName '\MyTask'       # 只处理某一个（「路径+名称」，支持通配符）
.\Hide-TaskWindows.ps1 -Apply -TaskName '\Scripts\*', '*sync*'
```

做了什么：

1. 用系统自带的 .NET Framework 编译器生成一个极小的启动器
   `C:\ProgramData\RunHidden\RunHidden.exe`（源码就在脚本里，几十行，没有窗口）。
2. 把任务的「程序」换成 `RunHidden.exe`，原程序和参数原样放到后面：
   `powershell.exe -File x.ps1` → `RunHidden.exe "powershell.exe" -File x.ps1`。
3. `RunHidden` 以不建窗口的方式启动原程序，等它结束并返回它的退出码。

所以任务的触发时间、运行账户、工作目录、权限、网络/代理环境、「上次运行结果」都**和原来一样**，只是不再弹窗。
修改前会把每个任务的原始 XML 备份到 `C:\ProgramData\RunHidden\backup\`。

改完可以再跑一次 `.\Hide-TaskWindows.ps1`，列表应为空；或者再跑一遍 `Find-ConsoleFlash.ps1` 确认。

### 还原

```powershell
.\Hide-TaskWindows.ps1 -Restore                     # 全部还原
.\Hide-TaskWindows.ps1 -Restore -TaskName '\MyTask'  # 只还原某个
```

## 注意

- 任务如果本来就需要**显示界面让人操作**（例如会弹出输入提示的脚本），静默后就看不到了，这类任务不要处理，用 `-TaskName` 排除即可。
- 以后新建的计划任务想后台运行，直接把程序写成 `C:\ProgramData\RunHidden\RunHidden.exe`，
  参数写 `"原程序" 原参数` 即可；或者在任务属性里勾选「不管用户是否登录都要运行」（任务会跑在后台会话里，同样不弹窗，但需要输入账户密码）。
- 某个任务是软件自己创建的，软件升级时可能把任务改回去，届时重跑一次 `-Apply` 即可。
