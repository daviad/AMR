# sync_app_to_windows.ps1
param(
    [switch]$Check,
    [string]$Source = '\\wsl.localhost\Ubuntu\home\dxw\amr\amr_app',
    [string]$Target = 'C:\Users\dxw\Documents\dev\amr_app',
    [string]$InfoName = 'SYNC_INFO.txt'
)
$ErrorActionPreference = 'Stop'
$script:Version = '1'
$ExcludeDirs = @('.dart_tool', 'build', '.git', '.idea', '.gradle', 'ephemeral', '.vscode')
$ExcludeFiles = @('*.iml', '*.log')
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

    return ($changed.Count + $onlySrc.Count + $onlyDst.Count)
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
Write-Host 'WARNING: full mirror uses robocopy /MIR and will delete files in the target that are absent in the source.'
robocopy $Source $Target /MIR /XD $ExcludeDirs /XF $ExcludeFiles /R:1 /W:1 /NFL /NDL /NJH /NJS /MT:8
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    Write-Host "robocopy failed, exit code $rc"
    exit $rc
}

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
