# =============================================================================
# amr_web_start.ps1 — AMR Web 大屏一键脚本（flutter build web + 静态服务）
# 位置：/home/dxw/amr/amr_web_start.ps1 （与 amr_start.sh 同目录）
#
# 用法（Windows PowerShell 5.1 普通窗口执行）：
#   powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\amr_web_start.ps1"
#   .\amr_web_start.ps1 -Profile            # 构建 profile 版（默认 release）
#   .\amr_web_start.ps1 -NoBuild            # 直接用已有 build/web，只起服务
#   .\amr_web_start.ps1 -Port 8091 -Open    # 换端口并打开浏览器（8080/8081 被网关占用）
#   .\amr_web_start.ps1 -NetMode nat        # NAT：AMR_HOST 用 WSL IP，浏览器也用该 IP
#   .\amr_web_start.ps1 -DryRun             # 只打印，不构建/不起服务
#   .\amr_web_start.ps1 -Help
#
# 说明：静态服务优先 WSL 侧 python3（后台留在当前终端前台运行，Ctrl+C 停止）；
#       WSL 不可用时回退 Windows python。端口被占用会明确报错，不会假装成功。
# 退出码：0 成功 / 2 参数错误 / 3 前置缺失 / 4 构建失败 / 5 端口或服务失败
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('mirrored', 'nat')] [string]$NetMode = 'mirrored',
    [string]$WslIp = '',
    [int]$Port = 8090,
    [int]$GatewayHttpPort = 8080,
    [int]$GatewayWsPort = 8081,
    [int]$HlsPort = 18888,
    [switch]$Profile,
    [switch]$NoBuild,
    [switch]$Open,
    [switch]$DryRun,
    [switch]$Help,
    [ValidateSet('auto', 'wsl', 'windows')] [string]$Server = 'auto',
    [string]$Project = 'C:\Users\dxw\Documents\dev\amr_app',
    [string]$Flutter = 'C:\Users\dxw\fvm\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Continue'

function Info($m) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Ok($m)   { Write-Host ('[{0}] [ OK ] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('[{0}] [警告] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Yellow }
function Err($m)  { Write-Host ('[{0}] [错误] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Red }
function Section($m) { Write-Host ''; Write-Host ('===== ' + $m + ' =====') -ForegroundColor Cyan }

function Show-Help {
    Write-Host @'
用法：.\amr_web_start.ps1 [选项]

  （无参数）            flutter build web --release → 起静态服务（WSL python3 优先）
  -Profile              构建 profile 版
  -NoBuild              跳过构建，直接服务已有 build/web
  -Port <n>             静态服务端口（默认 8090；不要用网关的 8080/8081）
  -Open                 构建/起服务后自动打开浏览器
  -NetMode mirrored     默认；AMR_HOST=localhost
  -NetMode nat          AMR_HOST 用 WSL IP（-WslIp 覆盖自动探测），浏览器也用该 IP
  -Server auto|wsl|windows  静态服务运行位置（默认 auto：先 WSL python3，再 Windows python）
  -GatewayHttpPort <n>  业务网关 HTTP 端口（默认 8080，仅做连通性提示）
  -GatewayWsPort <n>    业务网关 WS 端口（默认 8081，仅做连通性提示）
  -HlsPort <n>          HLS 视频端口（默认 18888，仅做连通性提示）
  -Project <path>       Windows 副本目录（默认 C:\Users\dxw\Documents\dev\amr_app）
  -Flutter <path>       flutter.bat 路径
  -DryRun               只打印将要执行的命令
  -Help                 显示本帮助

端口被占用 / 无 python 时会明确报错；服务在前台运行，Ctrl+C 停止。
退出码：0 成功 / 2 参数错误 / 3 前置缺失 / 4 构建失败 / 5 端口或服务失败
'@
}

if ($Help) { Show-Help; exit 0 }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = '', [switch]$AllowFail)
    if ($DryRun) {
        if ($WorkingDirectory) { Info ('[dry-run] cd ' + $WorkingDirectory + ' && ' + $Exe + ' ' + ($Arguments -join ' ')) }
        else { Info ('[dry-run] ' + $Exe + ' ' + ($Arguments -join ' ')) }
        return 0
    }
    $oldPref = $ErrorActionPreference
    $oldLoc = (Get-Location).Path
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        & $Exe @Arguments 2>&1 | Out-String -Stream | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 1 }
    } finally {
        Set-Location -LiteralPath $oldLoc
        $ErrorActionPreference = $oldPref
    }
    if ($code -ne 0 -and -not $AllowFail) { Err ("命令失败(exit $code)：" + $Exe + ' ' + ($Arguments -join ' ')) }
    return $code
}

function Get-WslIp {
    try {
        $out = (& wsl.exe -e bash -lc 'hostname -I') 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $ip = ($out -split '\s+')[0].Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
        }
    } catch { }
    return ''
}

function Test-Port {
    param([string]$TargetHost, [int]$Port)
    try {
        return (Test-NetConnection -ComputerName $TargetHost -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch { return $false }
}

function Test-PortBusy {
    param([int]$P)
    try {
        $c = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
        return [bool]$c
    } catch { return $false }
}

$webDirWin = Join-Path $Project 'build\web'
$drive = 'c'
if ($Project -match '^([A-Za-z]):') { $drive = $matches[1].ToLower() }
$restPath = ($Project -replace '^[A-Za-z]:', '') -replace '\\', '/'
$webDirWsl = '/mnt/' + $drive + $restPath + '/build/web'

# =============================================================================
# 0. 前置检查
# =============================================================================
Section '0. 前置检查'
$missing = @()
foreach ($f in @($Flutter, $Project)) {
    if (Test-Path -LiteralPath $f) { Ok $f } else { Err "缺少 $f"; $missing += $f }
}
if ($missing.Count -gt 0) {
    Err '修复建议：Flutter 缺失请确认 C:\Users\dxw\fvm\flutter；Windows 副本缺失请先跑同步脚本'
    exit 3
}

$hostForApp = 'localhost'
if ($NetMode -eq 'nat') {
    if (-not $WslIp) { $WslIp = Get-WslIp }
    if ($WslIp) { $hostForApp = $WslIp }
    else { Warn 'nat 模式但取不到 WSL IP，请用 -WslIp 指定' }
}
Section '网络模式判定'
Info ("-NetMode={0} → Web 端 AMR_HOST={1}，访问地址 http://{2}:{3}/#/dashboard" -f $NetMode, $hostForApp, $hostForApp, $Port)

# =============================================================================
# 1. 构建
# =============================================================================
if ($NoBuild) {
    Section '1. 构建 Web'
    Info '已指定 -NoBuild，跳过 flutter build web'
} else {
    Section '1. 构建 Web'
    $buildArgs = @('build', 'web')
    if ($Profile) { $buildArgs += '--profile' } else { $buildArgs += '--release' }
    $buildArgs += ('--dart-define=AMR_HOST=' + $hostForApp)
    $code = Invoke-Native $Flutter $buildArgs -WorkingDirectory $Project
    if ($code -ne 0) {
        # 已知坑：ios/Flutter/ephemeral/.swift_pm.lock 残留会让 build web 报
        # "Flutter failed to open a file ... cannot access the file or directory"，移走后重试一次。
        $swiftLock = Join-Path $Project 'ios\Flutter\ephemeral\.swift_pm.lock'
        if (Test-Path -LiteralPath $swiftLock) {
            Warn ('构建失败且存在 .swift_pm.lock，移走后重试一次：' + $swiftLock)
            if (-not $DryRun) {
                $staleName = '.swift_pm.lock.stale-' + (Get-Date -Format 'yyyyMMddHHmmss')
                $moved = $false
                try { Rename-Item -LiteralPath $swiftLock -NewName $staleName -Force -ErrorAction Stop; $moved = $true } catch { }
                if (-not $moved) { try { Remove-Item -LiteralPath $swiftLock -Force -ErrorAction Stop; $moved = $true } catch { } }
                if ($moved) { Ok ('已移走 .swift_pm.lock → ' + $staleName + '（0 字节锁文件，Flutter 会自动重建）') }
                else { Warn '移走残留锁失败（权限不足）：可手动改名该文件后重跑' }
            }
            $code = Invoke-Native $Flutter $buildArgs -WorkingDirectory $Project
        }
    }
    if ($code -ne 0) { Err 'flutter build web 失败（上方日志为准）'; exit 4 }
    Ok 'Web 构建完成'
}

if (-not (Test-Path -LiteralPath (Join-Path $webDirWin 'index.html'))) {
    Err "缺少 $webDirWin\index.html —— 需要先构建（去掉 -NoBuild），或检查 -Project 路径"
    exit 4
}

# =============================================================================
# 2. 选择静态服务
# =============================================================================
Section '2. 静态服务方式'
$wslPy = ''
$winPy = ''
$winPyArgs = @()
try { $null = (& wsl.exe -e bash -lc 'command -v python3') 2>$null; if ($LASTEXITCODE -eq 0) { $wslPy = 'python3' } } catch { }
try { $cmd = Get-Command python -ErrorAction SilentlyContinue; if ($cmd) { $winPy = $cmd.Source } } catch { }
if (-not $winPy) { try { $cmd = Get-Command py -ErrorAction SilentlyContinue; if ($cmd) { $winPy = $cmd.Source; $winPyArgs = @('-3') } } catch { } }

$chosen = ''
if ($Server -eq 'wsl') { $chosen = if ($wslPy) { 'wsl' } else { '' } }
elseif ($Server -eq 'windows') { $chosen = if ($winPy) { 'windows' } else { '' } }
else {
    if ($wslPy) { $chosen = 'wsl' } elseif ($winPy) { $chosen = 'windows' }
}
if (-not $chosen) {
    Err '没有可用的 python：WSL python3 与 Windows python 都不可用。'
    Err '  修复：WSL 里 sudo apt install python3；Windows 里安装 Python 并加入 PATH；或 -Server 指定'
    exit 3
}
Ok ("使用 {0} python 提供静态服务" -f $chosen)

if (Test-PortBusy $Port) {
    Err "端口 $Port 已被占用：换 -Port，或先停掉占用进程（Get-NetTCPConnection -LocalPort $Port）"
    exit 5
}

Section '3. 后端端口连通性（仅提示，不阻塞）'
$probeHost = $hostForApp
if ($probeHost -eq 'localhost') { $probeHost = '127.0.0.1' }
if (Test-Port $probeHost $GatewayHttpPort) { Ok ("网关 HTTP {0}:{1} 可连通（任务/地图）" -f $probeHost, $GatewayHttpPort) }
else { Warn ("网关 HTTP {0}:{1} 不通 —— 页面能打开但地图停在等待、指令不可用；请先在 WSL 执行 ./amr_start.sh" -f $probeHost, $GatewayHttpPort) }
if (Test-Port $probeHost $GatewayWsPort) { Ok ("网关 WS {0}:{1} 可连通（位姿/路径/扫描推送）" -f $probeHost, $GatewayWsPort) }
else { Warn ("网关 WS {0}:{1} 不通 —— Web 端看不到实时位姿/路径/扫描" -f $probeHost, $GatewayWsPort) }
if (Test-Port $probeHost $HlsPort) { Ok ("HLS {0}:{1} 可连通" -f $probeHost, $HlsPort) }
else { Warn ("HLS {0}:{1} 不通 —— Web 端视频会黑屏（需 WSL 侧 mediamtx 已起）" -f $probeHost, $HlsPort) }

$url = ('http://' + $hostForApp + ':' + $Port + '/#/dashboard')
Section '4. 启动静态服务'
Info ("访问地址: {0}" -f $url)
Info 'Ctrl+C 停止服务'

if (-not $DryRun -and $Open) {
    try { Start-Process $url; Ok '已尝试打开浏览器' } catch { Warn '打开浏览器失败，请手动复制访问地址' }
}

if ($DryRun) {
    if ($chosen -eq 'wsl') { Info ('[dry-run] wsl.exe -e bash -lc "cd {0} && python3 -m http.server {1} --bind 0.0.0.0"' -f $webDirWsl, $Port) }
    else { Info ('[dry-run] {0} {1} -m http.server {2} --directory "{3}"' -f $winPy, ($winPyArgs -join ' '), $Port, $webDirWin) }
    exit 0
}

if ($chosen -eq 'wsl') {
    $bashCmd = 'cd ' + $webDirWsl + ' && python3 -m http.server ' + $Port + ' --bind 0.0.0.0'
    & wsl.exe -e bash -lc $bashCmd
} else {
    & $winPy @winPyArgs -m http.server $Port --directory $webDirWin
}
if ($LASTEXITCODE -ne 0) { Err "静态服务退出(exit $LASTEXITCODE)"; exit 5 }

Ok '静态服务已停止'
exit 0
