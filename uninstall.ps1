#requires -Version 5.1
<#
.SYNOPSIS
    dsh-zen-desktop 卸载器 —— 移除代理插件与相关配置,恢复原始设置。

.DESCRIPTION
      - 删除 profiles\web\plugins\dsh-zen-proxy(junction 只删链接,不影响应用依赖树);
      - 从 cordis.patch.yml 移除 zen-proxy 注册;
      - 恢复 settings.yaml(若有 install.ps1 生成的 .dsh-zen-backup 备份);
      - 保留 .credentials.yaml 中的 OPENCODE_API_KEY(仅当提供了 -RemoveKey 才删除);
      - 移除自愈计划任务(若存在)。
#>
[CmdletBinding()]
param(
    [switch]$RemoveKey,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

function Get-HarnessHome {
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return $env:DSH_HOME }
    $cand = Join-Path $env:APPDATA "dsh-desktop\harness"
    if (Test-Path $cand) { return $cand }
    throw "找不到 dsh harness 目录"
}

function Get-DshExe {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\DSH Desktop.exe"),
        (Join-Path ${env:ProgramFiles} "DSH Desktop\DSH Desktop.exe")
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { return $proc.Path }
    return $null
}

$harness = Get-HarnessHome
$pluginDir = Join-Path $harness "profiles\web\plugins\dsh-zen-proxy"

if (Test-Path $pluginDir) {
    Remove-Item $pluginDir -Recurse -Force
    Write-Host "已删除插件目录: $pluginDir" -ForegroundColor Green
} else {
    Write-Host "插件目录不存在,跳过。" -ForegroundColor DarkYellow
}

$patchFile = Join-Path $harness "profiles\web\cordis.patch.yml"
if (Test-Path $patchFile) {
    $raw = [System.IO.File]::ReadAllText($patchFile)
    if ($raw -match "zen-proxy") {
        $lines = $raw -split "`r?`n"
        $out = New-Object System.Collections.Generic.List[string]
        $drop = $false
        foreach ($line in $lines) {
            if ($line -match "dsh-zen-desktop:") { $drop = $true }
            if ($drop -and $line -match "^\S" -and $line -notmatch "^- insert:") { $drop = $false }
            if (-not $drop) { $out.Add($line) }
        }
        $new = $out -join "`r`n"
        [System.IO.File]::WriteAllText($patchFile, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "已从 cordis.patch.yml 移除 zen-proxy 注册" -ForegroundColor Green
    } else {
        Write-Host "cordis.patch.yml 无 zen-proxy 注册,跳过。" -ForegroundColor DarkYellow
    }
}

$settingsFile = Join-Path $harness "settings.yaml"
$backup = "$settingsFile.dsh-zen-backup"
if (Test-Path $backup) {
    Copy-Item $backup $settingsFile -Force
    Remove-Item $backup -Force
    Write-Host "settings.yaml 已从备份恢复(原 opencode 直连 opencode.ai/zen/v1)" -ForegroundColor Green
} elseif (Test-Path $settingsFile) {
    $raw = [System.IO.File]::ReadAllText($settingsFile)
    if ($raw -match "(?m)^opencode:\s*$") {
        $new = $raw -replace "(?m)^(\s*)baseURL:\s*http://127\.0\.0\.1:\d+/v1\s*$", "`$1baseURL: https://opencode.ai/zen/v1"
        [System.IO.File]::WriteAllText($settingsFile, $new, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "settings.yaml baseURL 已恢复为 https://opencode.ai/zen/v1" -ForegroundColor Green
    }
}

if ($RemoveKey) {
    $credFile = Join-Path $harness ".credentials.yaml"
    $raw = [System.IO.File]::ReadAllText($credFile)
    $raw = [regex]::Replace($raw, "(?m)^OPENCODE_API_KEY\s*:\s*\S+\r?\n?", "")
    [System.IO.File]::WriteAllText($credFile, $raw, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已从 .credentials.yaml 移除 OPENCODE_API_KEY" -ForegroundColor Green
} else {
    Write-Host "已保留 .credentials.yaml 中的 OPENCODE_API_KEY(使用 -RemoveKey 可一并删除)" -ForegroundColor DarkYellow
}

Unregister-ScheduledTask -TaskName "dsh-zen-desktop-repair" -Confirm:$false -ErrorAction SilentlyContinue

if (-not $NoRestart) {
    $exe = Get-DshExe
    if ($exe) {
        Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Process $exe
        Write-Host "已重启 DSH Desktop。" -ForegroundColor Green
    }
}
Write-Host "卸载完成。" -ForegroundColor Cyan
