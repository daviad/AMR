# sync_app_to_windows.ps1
# v5: 默认 robocopy /E —— 覆盖新增/更新文件，不删除目标侧独有文件；显式 -Purge 才改用 /MIR 做镜像清理。
# v4: robocopy 完成后，会把仓库根的两个 Windows 启动脚本（amr_start_windows.ps1 / amr_web_start.ps1）
#     一并复制到目标目录；它们不在 amr_app 里，robocopy 带不过来，且必须在同步之后复制。
param(
    [switch]$Check,
    [switch]$Purge,
    [string]$Source = '\\wsl.localhost\Ubuntu\home\dxw\amr\amr_app',
    [string]$Target = 'C:\Users\dxw\Documents\dev\amr_app',
    [string]$InfoName = 'SYNC_INFO.txt',
    [string]$GradleJvm = 'C:\Users\dxw\.jdks\jbr-21.0.11',
    [bool]$RunPubGet = $true
)
$ErrorActionPreference = 'Stop'
$script:Version = '5'
# .idea 仍然不进 robocopy：WSL 侧 .idea\libraries\Dart_SDK.xml 含 file:///home/... 绝对路径，
# 整体镜像会把 Windows 侧 AS 指到不存在的路径。安全的子集由 Initialize-IdeProject 单独落地。
$ExcludeDirs = @('.dart_tool', 'build', '.git', '.idea', '.gradle', 'ephemeral', '.vscode')
# local.properties 必须保护：WSL 侧写的是 flutter.sdk=/home/...，盖过来 Gradle 会找不到 SDK
# .flutter-plugins-dependencies / .flutter-plugins 是 pub 生成物：WSL 版本含 /home/dxw/.pub-cache 路径，
# 覆盖到 Windows 会让 flutter-plugin-loader 报 "Plugin directory does not exist: C:\home\dxw\..."
$ExcludeFiles = @('*.iml', '*.log', 'local.properties', '.flutter-plugins-dependencies', '.flutter-plugins', '*.bak*', '*.v2bak*', '*bak-*')
function Get-Fingerprint {
    param([string]$Root)

    $libDir = Join-Path $Root 'lib'
    if (-not (Test-Path -LiteralPath $libDir)) {
        return [pscustomobject]@{ LibFileCount = -1; LibHash = 'missing'; PubspecHash = 'missing'; LibFileHashes = @{} }
    }

    $files = @(Get-ChildItem -LiteralPath $libDir -Recurse -File | Sort-Object FullName)
    $sb = New-Object System.Text.StringBuilder
    $libFileHashes = @{}
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($libDir.Length).TrimStart('\', '/')
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        $libFileHashes[$rel] = $h
        [void]$sb.AppendLine("${rel}:${h}")
    }

    $libHash = ''
    if ($files.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
            $libHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
        } finally { $sha.Dispose() }
    }

    $pubPath = Join-Path $Root 'pubspec.yaml'
    $pubHash = if (Test-Path -LiteralPath $pubPath) {
        (Get-FileHash -LiteralPath $pubPath -Algorithm SHA256).Hash.ToLower()
    } else { 'missing' }

    [pscustomobject]@{
        LibFileCount  = $files.Count
        LibHash       = $libHash
        PubspecHash   = $pubHash
        LibFileHashes = $libFileHashes
    }
}

function Read-Info {
    param([string]$Root)
    $p = Join-Path $Root $InfoName
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $p) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $map[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
    }
    $map
}

function Show-Drift {
    param($SrcHashes, $DstHashes)

    $changed = @(); $onlySrc = @(); $onlyDst = @()
    foreach ($k in $SrcHashes.Keys) {
        if (-not $DstHashes.ContainsKey($k)) { $onlySrc += $k }
        elseif ($SrcHashes[$k] -ne $DstHashes[$k]) { $changed += $k }
    }
    foreach ($k in $DstHashes.Keys) {
        if (-not $SrcHashes.ContainsKey($k)) { $onlyDst += $k }
    }

    Write-Host ("changed: {0}  only-in-source: {1}  only-in-target: {2}" -f $changed.Count, $onlySrc.Count, $onlyDst.Count)
    foreach ($k in ($changed | Sort-Object | Select-Object -First 15)) { Write-Host "  M $k" }
    foreach ($k in ($onlySrc | Sort-Object | Select-Object -First 10)) { Write-Host "  + $k" }
    foreach ($k in ($onlyDst | Sort-Object | Select-Object -First 10)) { Write-Host "  - $k" }
    if ($onlyDst.Count -gt 0) { Write-Host ("  (target-only: {0} file(s) - copy pollution, not counted as stale)" -f $onlyDst.Count) }

    # 过期只看「源里有、副本没有」与「同名但内容不同」；副本多出来的文件不影响判定
    return ($changed.Count + $onlySrc.Count)
}
function Initialize-IdeProject {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$GradleJvm = ''
    )

    # 只落地“路径安全”的 .idea 子集：
    #   安全   = 内容全部使用 $PROJECT_DIR$ / $MODULE_DIR$ / $KOTLIN_BUNDLED$ 等宏
    #   不安全 = WSL 绝对路径（.idea\libraries\Dart_SDK.xml 里的 file:///home/...）
    #   已跳过 = .idea\workspace.xml（会覆盖 Windows 侧窗口状态）、.idea\caches
    $ideaDir = Join-Path $Target '.idea'
    if (-not (Test-Path -LiteralPath $ideaDir)) {
        New-Item -ItemType Directory -Path $ideaDir -Force | Out-Null
    }

    # 1) 根 Dart 模块描述：内容只含 $MODULE_DIR$，可安全复制
    $imlSrc = Join-Path $Source 'amr_app.iml'
    $imlDst = Join-Path $Target 'amr_app.iml'
    if ((Test-Path -LiteralPath $imlSrc) -and -not (Test-Path -LiteralPath $imlDst)) {
        Copy-Item -LiteralPath $imlSrc -Destination $imlDst -Force
        Write-Host 'ide: copied amr_app.iml'
    }

    # 2) modules.xml：仅缺失时生成，避免覆盖 AS 自己登记的 Gradle 模块
    $modulesPath = Join-Path $ideaDir 'modules.xml'
    if (-not (Test-Path -LiteralPath $modulesPath)) {
        $modulesXml = @(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<project version="4">',
            '  <component name="ProjectModuleManager">',
            '    <modules>',
            '      <module fileurl="file://$PROJECT_DIR$/amr_app.iml" filepath="$PROJECT_DIR$/amr_app.iml" />',
            '    </modules>',
            '  </component>',
            '</project>'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($modulesPath, $modulesXml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host 'ide: wrote .idea/modules.xml'
    }

    # 3) Flutter 运行配置：只引用 $PROJECT_DIR$，可安全复制
    $runSrc = Join-Path (Join-Path (Join-Path $Source '.idea') 'runConfigurations') 'main_dart.xml'
    $runDir = Join-Path $ideaDir 'runConfigurations'
    $runDst = Join-Path $runDir 'main_dart.xml'
    if ((Test-Path -LiteralPath $runSrc) -and -not (Test-Path -LiteralPath $runDst)) {
        if (-not (Test-Path -LiteralPath $runDir)) {
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $runSrc -Destination $runDst -Force
        Write-Host 'ide: copied .idea/runConfigurations/main_dart.xml'
    }

    # 4) gradle.xml：把 android/ 挂成 Gradle 工程，AS 打开即自动 sync，无需手点 Link Gradle Project
    $gradlePath = Join-Path $ideaDir 'gradle.xml'
    if (-not (Test-Path -LiteralPath $gradlePath)) {
        $jvm = if ($GradleJvm -and (Test-Path -LiteralPath $GradleJvm)) { $GradleJvm } else { '#GRADLE_LOCAL_JAVA_HOME' }
        $gradleXml = @(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<project version="4">',
            '  <component name="GradleSettings">',
            '    <option name="linkedExternalProjectsSettings">',
            '      <GradleProjectSettings>',
            '        <option name="externalProjectPath" value="$PROJECT_DIR$/android" />',
            '        <option name="gradleJvm" value="__GRADLE_JVM__" />',
            '        <option name="modules">',
            '          <set>',
            '            <option value="$PROJECT_DIR$/android" />',
            '            <option value="$PROJECT_DIR$/android/app" />',
            '          </set>',
            '        </option>',
            '        <option name="resolveExternalAnnotations" value="false" />',
            '      </GradleProjectSettings>',
            '    </option>',
            '  </component>',
            '</project>'
        ) -join "`r`n"
        $gradleXml = $gradleXml.Replace('__GRADLE_JVM__', [System.Security.SecurityElement]::Escape($jvm))
        [System.IO.File]::WriteAllText($gradlePath, $gradleXml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "ide: wrote .idea/gradle.xml (gradleJvm=$jvm)"
    }

    # 5) 保护 android/local.properties：绝不能被 WSL 路径覆盖
    $localProps = Join-Path $Target 'android\local.properties'
    if (Test-Path -LiteralPath $localProps) {
        $hit = Select-String -LiteralPath $localProps -Pattern '/home/|wsl' -Quiet
        if ($hit) {
            Write-Host 'ide: WARNING android/local.properties 含 WSL 路径，请在 Windows 侧执行 flutter pub get 修复'
        }
    }

    # 6) 自检：确认 .idea 里没有 WSL 绝对路径
    $files = @(Get-ChildItem -LiteralPath $ideaDir -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -gt 0) {
        $leak = Select-String -LiteralPath $files.FullName -Pattern 'file:///home/|/home/dxw' -ErrorAction SilentlyContinue
        if ($leak) {
            Write-Host 'ide: WARNING .idea 内检测到 WSL 绝对路径：'
            $leak | Select-Object -First 3 | ForEach-Object { Write-Host ("  - {0}" -f $_.Path) }
        } else {
            Write-Host 'ide: OK  .idea 无 WSL 绝对路径'
        }
    }
}
$srcFp = Get-Fingerprint -Root $Source
$dstFp = Get-Fingerprint -Root $Target
$info   = Read-Info -Root $Target

Write-Host "source        : $Source"
Write-Host "target        : $Target"
Write-Host ("source pubspec: {0}" -f $srcFp.PubspecHash)
Write-Host ("target pubspec: {0}" -f $dstFp.PubspecHash)
Write-Host ("source lib    : {0} files, {1}" -f $srcFp.LibFileCount, $srcFp.LibHash)
Write-Host ("target lib    : {0} files, {1}" -f $dstFp.LibFileCount, $dstFp.LibHash)

$stale = $false
$reasons = @()
if (-not $info) {
    $stale = $true
    $reasons += 'SYNC_INFO.txt missing'
} else {
    if ($info['pubspec_sha256'] -ne $srcFp.PubspecHash) { $stale = $true; $reasons += 'pubspec changed since last sync' }
    if ($info['lib_sha256'] -ne $srcFp.LibHash) { $stale = $true; $reasons += 'lib/ changed since last sync' }
    if ($info['lib_files'] -ne [string]$srcFp.LibFileCount) { $stale = $true; $reasons += 'lib/ file count changed' }
    if ($dstFp.PubspecHash -ne $srcFp.PubspecHash) { $stale = $true; $reasons += 'target pubspec differs from source' }
}

$driftCount = 0
if ($srcFp.LibFileHashes.Count -gt 0 -and $dstFp.LibFileHashes.Count -gt 0) {
    $driftCount = Show-Drift -SrcHashes $srcFp.LibFileHashes -DstHashes $dstFp.LibFileHashes
} elseif ($dstFp.LibFileCount -lt 0) {
    $reasons += 'target lib/ missing'
    $stale = $true
}

if ($Check) {
    Write-Host ''
    if ($stale -or $driftCount -gt 0) {
        Write-Host 'RESULT: STALE'
        foreach ($r in ($reasons | Select-Object -Unique)) { Write-Host "  - $r" }
        Write-Host 'STALE: copy is outdated, sync before building.'
        exit 1
    }
    Write-Host 'RESULT: UP-TO-DATE'
    exit 0
}

Write-Host ''
# 默认 /E：覆盖新增与更新，不删除目标侧源端不存在的文件；-Purge 才退回 /MIR 的镜像清理语义
$RoboMode = '/E'
if ($Purge) {
    $RoboMode = '/MIR'
    Write-Host 'WARNING: -Purge 已启用 robocopy /MIR，将删除目标侧源端不存在的文件。'
} else {
    Write-Host 'robocopy /E: 只覆盖新增/更新文件，保留目标侧独有文件（需要清理请显式加 -Purge）。'
}
robocopy $Source $Target $RoboMode /XD $ExcludeDirs /XF $ExcludeFiles /R:1 /W:1 /NFL /NDL /NJH /NJS /MT:8
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    Write-Host "robocopy failed, exit code $rc"
    exit $rc
}

# ── v4：把 Windows 侧启动脚本一并带到目标目录 ──
$RepoRoot = Split-Path -Parent $Source
foreach ($launcher in @('amr_start_windows.ps1', 'amr_web_start.ps1')) {
    $launcherSrc = Join-Path $RepoRoot $launcher
    if (Test-Path -LiteralPath $launcherSrc) {
        Copy-Item -LiteralPath $launcherSrc -Destination (Join-Path $Target $launcher) -Force
        Write-Host "launcher copied: $launcher"
    } else {
        Write-Host "WARNING: $launcher not found under $RepoRoot, skipped"
    }
}

# 同步后自动重建 Windows 侧的 pub 生成物（.flutter-plugins-dependencies 等），避免 WSL 路径残留
if ($RunPubGet) {
    $flutterExe = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterExe) {
        Write-Host 'post-sync: flutter pub get'
        Push-Location -LiteralPath $Target
        try {
            & $flutterExe.Source pub get
            if ($LASTEXITCODE -ne 0) {
                Write-Host "post-sync: WARNING flutter pub get 失败 (exit $LASTEXITCODE)，请手动执行"
            } else {
                Write-Host 'post-sync: flutter pub get OK'
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host 'post-sync: 未找到 flutter 命令，跳过 flutter pub get（请手动执行，或把 flutter 加入 PATH）'
    }
}

Initialize-IdeProject -Source $Source -Target $Target -GradleJvm $GradleJvm

$after = Get-Fingerprint -Root $Target
$infoText = @(
    "source=$Source",
    "synced_at=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "pubspec_sha256=$($srcFp.PubspecHash)",
    "lib_files=$($srcFp.LibFileCount)",
    "lib_sha256=$($srcFp.LibHash)",
    "script_version=$script:Version"
) -join "`r`n"
Set-Content -LiteralPath (Join-Path $Target $InfoName) -Value $infoText -Encoding ASCII

Write-Host ''
Write-Host ("SYNCED  pubspec={0}  lib={1} files  {2}" -f $after.PubspecHash, $after.LibFileCount, $after.LibHash)
Write-Host ("SYNC_INFO.txt written to {0}" -f (Join-Path $Target $InfoName))
exit 0
