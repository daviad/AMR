# =============================================================================
# amr_start_windows.ps1 — AMR Windows 侧（Android App / 模拟器）一键脚本
# 位置：/home/dxw/amr/amr_start_windows.ps1 （与 amr_start.sh 同目录）
#
# 用法（在 Windows PowerShell 5.1 普通窗口执行）：
#   powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\amr_start_windows.ps1"
#   .\amr_start_windows.ps1 -Mode attach          # 改用 flutter run（可热重载，占住终端）
#   .\amr_start_windows.ps1 -Mode build           # 只构建 APK
#   .\amr_start_windows.ps1 -NetMode nat          # WSL 为 NAT 模式（用 WSL IP 连业务网关 8080/8081）
#   .\amr_start_windows.ps1 -Clean -NoSync        # 先 flutter clean，且跳过同步
#   .\amr_start_windows.ps1 -DryRun               # 只打印要做的事，不执行
#   .\amr_start_windows.ps1 -Help
#
# 约定：默认 mirrored；默认先同步（-NoSync 关闭）；退出码 0=成功 2=参数 3=前置缺失
#       4=同步/构建失败 5=设备/端口失败。Ctrl+C 可随时中断，不会删除任何目录。
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('mirrored', 'nat')] [string]$NetMode = 'mirrored',
    [string]$WslIp = '',
    [string]$AmrHost = 'auto',
    [ValidateSet('install', 'attach', 'build')] [string]$Mode = 'install',
    [switch]$NoSync,
    [switch]$Clean,
    [switch]$NoAvd,
    [switch]$DryRun,
    [switch]$Help,
    [string]$Avd = 'Small_Phone',
    [int]$GatewayHttpPort = 8080,
    [int]$GatewayWsPort = 8081,
    [int]$WhepPort = 8889,
    [int]$RtspPort = 18554,
    [string]$Project = 'C:\Users\dxw\Documents\dev\amr_app',
    [string]$Flutter = 'C:\Users\dxw\fvm\flutter\bin\flutter.bat',
    [string]$SdkRoot = 'C:\Users\dxw\fvm\android-sdk',
    [string]$Jdk = 'C:\Users\dxw\.jdks\jbr-21.0.11',
    [string]$SyncScript = '\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1'
)

$ErrorActionPreference = 'Continue'

function Info($m) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Ok($m)   { Write-Host ('[{0}] [ OK ] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('[{0}] [警告] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Yellow }
function Err($m)  { Write-Host ('[{0}] [错误] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Red }
function Section($m) { Write-Host ''; Write-Host ('===== ' + $m + ' =====') -ForegroundColor Cyan }

function Show-Help {
    Write-Host @'
用法：.\amr_start_windows.ps1 [选项]

  （无参数）            同步 → 检查 → gradlew --stop → pub get → 启动/复用模拟器
                        → adb reverse → build apk --debug → install → 启动 App
  -Mode attach          改用 flutter run -d <设备>（可热重载，占住终端；Ctrl+C 退出）
  -Mode build           只 flutter build apk --debug，不碰设备
  -NetMode mirrored     默认；本机回环 + adb reverse（host 由 -AmrHost 决定）
  -NetMode nat          WSL 为 NAT；host 由 -AmrHost 决定（auto 取 eth0 IPv4）
  -WslIp <ip>           nat 模式回退用的 WSL IP（-AmrHost auto 优先 eth0）
  -AmrHost <ip|auto>    默认 auto：取 WSL eth0 IPv4（解析失败回退 127.0.0.1）；传 127.0.0.1 恢复旧行为
  -NoSync               跳过 Windows 侧的同步脚本
  -Clean                先执行 flutter clean（会删 build/ 与 .dart_tool/，耗时增加）
  -NoAvd                设备不在线时也不启动模拟器，直接失败
  -DryRun               只打印将要执行的命令，不产生副作用
  -Avd <name>           AVD 名（默认 Small_Phone）
  -Project <path>       Windows 副本目录（默认 C:\Users\dxw\Documents\dev\amr_app）
  -Flutter <path>       flutter.bat 路径
  -SdkRoot <path>       Android SDK（默认 C:\Users\dxw\fvm\android-sdk）
  -Jdk <path>           Gradle 用 JDK（默认 jbr-21.0.11；不存在时仅警告，继续用当前 JAVA_HOME）
  -GatewayHttpPort <n>  业务网关 HTTP 端口（默认 8080，App 任务/地图）
  -GatewayWsPort <n>    业务网关 WS 端口（默认 8081，App 位姿/路径/扫描/状态推送）
  -WhepPort <n>         默认 8889（WHEP 信令，做 adb reverse）
  -RtspPort <n>         默认 18554（RTSP 兜底视频，做 adb reverse）
  -Help                 显示本帮助

退出码：0 成功 / 2 参数错误 / 3 前置缺失 / 4 同步或构建失败 / 5 设备或端口异常
'@
}

if ($Help) { Show-Help; exit 0 }

# ---------- 原生程序调用（保证 ErrorActionPreference=Continue 且检查退出码） ----------
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

function Test-Port {
    param([string]$TargetHost, [int]$Port)
    try {
        return (Test-NetConnection -ComputerName $TargetHost -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch { return $false }
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

function Get-WslEth0Ip {
    # -AmrHost auto 用：取 WSL eth0 的 IPv4（镜像网络下 Windows 可直接访问；UDP 8189 无法 adb reverse）
    try {
        $out = (& wsl.exe -d Ubuntu -- ip -4 -o addr show eth0) 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            foreach ($line in $out) {
                if ($line -match 'inet\s+(\d+\.\d+\.\d+\.\d+)') { return $matches[1] }
            }
        }
    } catch { }
    return ''
}

function Get-Online-Device {
    param([string]$Adb)
    $lines = & $Adb devices 2>$null
    foreach ($l in $lines) {
        if ($l -match '^(\S+)\s+device\s*$') { return $matches[1] }
    }
    return ''
}

function Wait-Booted {
    param([string]$Adb, [string]$Serial, [int]$TimeoutSec = 240)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $p = & $Adb -s $Serial shell getprop sys.boot_completed 2>$null
        if ($p -and ($p -join '').Trim() -eq '1') { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ---------- 参数校验 ----------
if ($Mode -eq 'build') { Info '模式 build：只构建，不触碰设备' }

$apkPath = Join-Path $Project 'build\app\outputs\flutter-apk\app-debug.apk'
$adbExe = Join-Path $SdkRoot 'platform-tools\adb.exe'
$emuExe = Join-Path $SdkRoot 'emulator\emulator.exe'
$gradlew = Join-Path $Project 'android\gradlew.bat'
$localProps = Join-Path $Project 'android\local.properties'

# =============================================================================
# 0. 前置检查（只读）
# =============================================================================
Section '0. 前置检查'
$missing = @()
foreach ($f in @($Flutter, $adbExe, $Project)) {
    if (Test-Path -LiteralPath $f) { Ok $f } else { Err "缺少 $f"; $missing += $f }
}
if (Test-Path -LiteralPath $Jdk) { Ok "JDK: $Jdk" }
else { Warn "JDK 不存在：$Jdk（不影响继续；Gradle 会回退到当前 JAVA_HOME / Studio JBR）" }
if (Test-Path -LiteralPath $emuExe) { Ok "模拟器: $emuExe" }
else { Warn "缺少 $emuExe（-NoAvd 时可不处理；否则无法自动启动模拟器）" }

if ($missing.Count -gt 0) {
    Err '前置检查未通过。修复建议：'
    foreach ($m in $missing) {
        if ($m -eq $Flutter) { Err '  Flutter 缺失：确认 C:\Users\dxw\fvm\flutter 存在，或 -Flutter 指定 flutter.bat' }
        elseif ($m -eq $adbExe) { Err '  adb 缺失：Android SDK platform-tools 未装，或 -SdkRoot 路径不对' }
        elseif ($m -eq $Project) { Err '  Windows 副本缺失：先跑 tools/sync_app_to_windows.ps1，或 -Project 指定' }
    }
    exit 3
}

# 网络模式判定：-AmrHost 优先（auto 取 WSL eth0 IPv4）；auto 且在 nat 下才回退到 -WslIp 逻辑
$hostForApp = '127.0.0.1'
if ($AmrHost -eq 'auto') {
    $eth0Ip = Get-WslEth0Ip
    if ($eth0Ip) {
        $hostForApp = $eth0Ip
    } elseif ($NetMode -eq 'nat') {
        if (-not $WslIp) { $WslIp = Get-WslIp }
        if ($WslIp) { $hostForApp = $WslIp }
        else { Warn 'nat 模式但无法自动取 WSL IP，请用 -WslIp 指定；暂用 127.0.0.1 + adb reverse' }
    } else {
        Warn 'auto 无法解析 WSL eth0 IPv4，回退 127.0.0.1（配合 adb reverse）'
    }
} else {
    $hostForApp = $AmrHost
}
Section '网络模式判定'
Info ("-NetMode={0} / -AmrHost={1} → App 连接网关 HTTP {2}:{3} / WS {2}:{4}" -f $NetMode, $AmrHost, $hostForApp, $GatewayHttpPort, $GatewayWsPort)
if ($AmrHost -eq 'auto' -and $NetMode -eq 'mirrored') { Info '  auto + mirrored：取 WSL eth0 IPv4；adb reverse（含 8080/8081）仍会设置作为 TCP 兜底' }
elseif ($AmrHost -eq 'auto') { Info '  auto + nat：优先 eth0 IPv4，解析失败才用 WSL IPv4；adb reverse 一并设置作为兜底' }
else { Info ("  显式 -AmrHost={0}；adb reverse 仍会设置作为兜底" -f $AmrHost) }

# =============================================================================
# 1. 同步（默认执行，-NoSync 跳过）
# =============================================================================
Section '1. 同步 Windows 副本'
if ($NoSync) {
    Info '已指定 -NoSync，跳过'
} elseif (Test-Path -LiteralPath $SyncScript) {
    $syncCode = Invoke-Native 'powershell.exe' @('-ExecutionPolicy', 'Bypass', '-File', $SyncScript)
    if ($syncCode -ne 0) { Warn '同步脚本返回非 0（可继续，但请检查输出）' }
} else {
    Warn "同步脚本不可达：$SyncScript（WSL 未启动？）——跳过，继续用现有副本"
}

# =============================================================================
# 2. 构建环境清理：gradlew --stop + local.properties 自检
# =============================================================================
Section '2. 构建环境清理'
if (Test-Path -LiteralPath $Jdk) {
    $env:JAVA_HOME = $Jdk
    $jdkBin = Join-Path $Jdk 'bin'
    if ($env:PATH -notlike ($jdkBin + '*')) { $env:PATH = $jdkBin + ';' + $env:PATH }
    Info ("JAVA_HOME 设为 {0}（仅本进程；-Jdk 可覆盖）" -f $Jdk)
} else {
    Warn ("JDK 不存在：{0}，沿用当前 JAVA_HOME={1}；gradlew 若报 JAVA_HOME 未设置，用 -Jdk 指定" -f $Jdk, $env:JAVA_HOME)
}

if (Test-Path -LiteralPath $gradlew) {
    $null = Invoke-Native $gradlew @('--stop') -AllowFail -WorkingDirectory (Join-Path $Project 'android')
} else { Warn "找不到 $gradlew（跳过 --stop）" }

if (Test-Path -LiteralPath $localProps) {
    $lp = Get-Content -LiteralPath $localProps -Raw
    if ($lp -match '/home/|/mnt/c') {
        Warn 'local.properties 含 WSL 路径，正在改回 Windows 路径'
        Copy-Item -LiteralPath $localProps -Destination ($localProps + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        $flutterSdk = Split-Path -Parent (Split-Path -Parent $Flutter)
        $fixed = ('flutter.sdk=' + $flutterSdk + "`r`n" + 'sdk.dir=' + $SdkRoot + "`r`n")
        if ($DryRun) { Info '[dry-run] 将重写 local.properties' } else {
            [System.IO.File]::WriteAllText($localProps, $fixed)
            Ok 'local.properties 已修正'
        }
    } else { Ok 'local.properties 指向 Windows 路径' }
} else { Warn "缺少 $localProps（Gradle 会退回环境变量；可先跑一次 flutter pub get）" }

if ($Clean) { $null = Invoke-Native $Flutter @('clean') -WorkingDirectory $Project }
else { Info '未指定 -Clean，跳过 flutter clean' }

# =============================================================================
# 3. flutter pub get + 插件路径自检
# =============================================================================
Section '3. pub get 与插件路径自检'
$pubCode = Invoke-Native $Flutter @('pub', 'get') -WorkingDirectory $Project
if ($pubCode -ne 0) { Err 'flutter pub get 失败，终止'; exit 4 }

$fpd = Join-Path $Project '.flutter-plugins-dependencies'
if (Test-Path -LiteralPath $fpd) {
    $hit = (Select-String -LiteralPath $fpd -Pattern '/home/dxw' -Quiet)
    if ($hit) {
        Warn '.flutter-plugins-dependencies 仍含 /home/ 路径，重试一次 pub get'
        $null = Invoke-Native $Flutter @('pub', 'get') -WorkingDirectory $Project
        $hit2 = (Select-String -LiteralPath $fpd -Pattern '/home/dxw' -Quiet)
        if ($hit2) {
            Err '插件路径仍指向 WSL。请确认没有混用 WSL 的 pub-cache；必要时删除 .flutter-plugins-dependencies 后重跑'
            exit 4
        }
    }
    Ok '.flutter-plugins-dependencies 路径正常（无 /home/）'
} else { Warn '.flutter-plugins-dependencies 不存在（pub get 应已生成）' }

# =============================================================================
# 4. 设备 / 模拟器
# =============================================================================
Section '4. 设备与模拟器'
$serial = ''
if ($Mode -ne 'build') {
    $serial = Get-Online-Device $adbExe
    if ($serial) {
        Ok "已有在线设备：$serial"
    } else {
        if ($NoAvd) { Err '没有在线设备，且指定了 -NoAvd'; exit 5 }
        if (-not (Test-Path -LiteralPath $emuExe)) { Err "缺少 $emuExe，无法自动启动模拟器"; exit 5 }
        Info "启动模拟器 $Avd ..."
        if (-not $DryRun) {
            Start-Process -FilePath $emuExe -ArgumentList @('-avd', $Avd, '-no-snapshot-save') -WorkingDirectory (Join-Path $SdkRoot 'emulator')
            $null = & $adbExe wait-for-device 2>&1
            $serial = Get-Online-Device $adbExe
            if (-not $serial) { $serial = 'emulator-5554' }
            Info "等待 $serial 的 sys.boot_completed=1（最多 240s）..."
            if (-not (Wait-Booted $adbExe $serial 240)) { Err '模拟器未在超时内完成启动'; exit 5 }
        }
        $serial = Get-Online-Device $adbExe
        if (-not $serial -and -not $DryRun) { Err '仍没有在线设备'; exit 5 }
        Ok "设备就绪：$serial"
    }
} else {
    Info '模式 build：跳过设备检查'
}

# =============================================================================
# 5. 业务网关 / 视频端口与 adb reverse
# =============================================================================
Section '5. 端口与 adb reverse'
$gwHttpOpen = Test-Port $hostForApp $GatewayHttpPort
$gwWsOpen = Test-Port $hostForApp $GatewayWsPort
$whepOpen = Test-Port $hostForApp $WhepPort
$rtspOpen = Test-Port $hostForApp $RtspPort
if ($gwHttpOpen) { Ok ("网关 HTTP {0}:{1} 可连通（任务/地图）" -f $hostForApp, $GatewayHttpPort) }
else { Warn ("网关 HTTP {0}:{1} 不通 —— 请先在 WSL 执行 ./amr_start.sh；App 会显示 GW 离线、地图停在等待" -f $hostForApp, $GatewayHttpPort) }
if ($gwWsOpen) { Ok ("网关 WS {0}:{1} 可连通（位姿/路径/扫描推送）" -f $hostForApp, $GatewayWsPort) }
else { Warn ("网关 WS {0}:{1} 不通 —— App 能下任务但看不到实时位姿/路径" -f $hostForApp, $GatewayWsPort) }
if ($whepOpen) { Ok ("WHEP {0}:{1} 可连通（WebRTC 信令）" -f $hostForApp, $WhepPort) }
else { Warn ("WHEP {0}:{1} 不通 —— App 主视频会失败；WebRTC 的 UDP 8189 无法 adb reverse，手机需用 LAN IP 直连（-AmrHost）" -f $hostForApp, $WhepPort) }
if ($rtspOpen) { Ok ("RTSP {0}:{1} 可连通（视频兜底）" -f $hostForApp, $RtspPort) }
else { Warn ("RTSP {0}:{1} 不通 —— App 相机页切到 RTSP 也不会有画面" -f $hostForApp, $RtspPort) }

if ($Mode -ne 'build' -and $serial) {
    foreach ($p in @($GatewayHttpPort, $GatewayWsPort, $WhepPort, $RtspPort)) {
        $null = Invoke-Native $adbExe @('-s', $serial, 'reverse', ('tcp:' + $p), ('tcp:' + $p)) -AllowFail
    }
    if (-not $DryRun) {
        $rl = & $adbExe -s $serial reverse --list 2>$null
        if ($rl) { foreach ($x in $rl) { if ($x) { Info ('  reverse: ' + $x) } } }
        else { Warn 'adb reverse --list 为空：规则可能未生效，检查 adb server 是否被重启' }
    }
    Info ("已设置 adb reverse（TCP {0}/{1}/{2}/{3}）" -f $GatewayHttpPort, $GatewayWsPort, $WhepPort, $RtspPort)
}

# =============================================================================
# 6. 构建 / 安装 / 启动
# =============================================================================
Section '6. 构建与启动'
$dartDefine = '--dart-define=AMR_HOST=' + $hostForApp

if ($Mode -eq 'attach') {
    Info 'flutter run（占住终端；Ctrl+C 退出）'
    $null = Invoke-Native $Flutter @('run', '-d', $serial, $dartDefine) -WorkingDirectory $Project
} else {
    $buildCode = Invoke-Native $Flutter @('build', 'apk', '--debug', $dartDefine) -WorkingDirectory $Project
    if ($buildCode -ne 0) { Err 'flutter build apk --debug 失败（上方日志为准）'; exit 4 }
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $apkPath)) { Err "未生成 $apkPath"; exit 4 }
        $sizeMb = [Math]::Round((Get-Item -LiteralPath $apkPath).Length / 1MB, 1)
        Ok ("APK 已生成：{0}（{1} MB）" -f $apkPath, $sizeMb)
    }

    if ($Mode -eq 'install' -and $serial) {
        $installCode = Invoke-Native $adbExe @('-s', $serial, 'install', '-r', $apkPath)
        if ($installCode -ne 0) { Err 'adb install 失败'; exit 5 }
        $null = Invoke-Native $adbExe @('-s', $serial, 'shell', 'am', 'start', '-n', 'com.amr.amr_app/.MainActivity') -AllowFail
    }
}

# =============================================================================
# 7. 摘要
# =============================================================================
Section '7. 摘要'
if ($serial) { Info "设备: $serial（AVD $Avd）" } else { Info '设备: 未涉及（-Mode build）' }
Info ("业务网关: HTTP http://{0}:{1} / WS ws://{0}:{2}/ws（App 唯一业务出口）" -f $hostForApp, $GatewayHttpPort, $GatewayWsPort)
Info ("视频: RTSP {0}:{1} / WHEP {0}:{2} / HLS {0}:18888（直连 MediaMTX，不经网关）" -f $hostForApp, $RtspPort, $WhepPort)
if ($gwHttpOpen -and $gwWsOpen) { Ok '网关端口检查通过' } else { Warn '网关未连通：先跑 ./amr_start.sh，再执行本脚本' }
Info '提示：App 顶部 GW/WS 为红 → 先确认 WSL 侧 amr_start.sh 已启动网关（8080/8081）'
if ($hostForApp -eq '127.0.0.1') {
    Warn ('提示：当前 AMR_HOST=127.0.0.1，业务可用但 WebRTC/RTSP 视频不可用；看视频请用 -AmrHost <LAN IP> 或 -NetMode nat 配 -WslIp')
} else {
    Info ("提示：相机页不出画面 → 确认手机与 {0} 同网段且防火墙放行 8889/18554/18888/UDP 8189" -f $hostForApp)
}

exit 0
