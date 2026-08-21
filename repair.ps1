#requires -Version 5.1
<#
.SYNOPSIS
    dsh-zen-desktop 自愈脚本 —— 检查并修复所有部署项,应用更新/误删后一键恢复。

.DESCRIPTION
    检查项(全部幂等):
      1. 插件文件是否存在于 profiles\web\plugins\dsh-zen-proxy;
      2. @deepseek-ai junction 是否存在且指向当前 DSH Desktop 依赖树;
      3. cordis.patch.yml 是否含 zen-proxy 注册;
      4. settings.yaml 的 opencode baseURL 是否指向本地代理;
      5. storages\*.json 是否残留 UTF-8 BOM。

    可用 -CreateScheduledTask 注册"登录时自动修复"计划任务,应用更新后无需手动处理。

.PARAMETER Silent
    不输出彩色提示、不询问、不重启应用(供计划任务调用)。

.PARAMETER CreateScheduledTask
    注册计划任务 dsh-zen-desktop-repair(用户登录时运行 repair.ps1 -Silent)。

.PARAMETER RemoveScheduledTask
    移除已注册的计划任务。
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [int]$Port = 4097,
    [switch]$CreateScheduledTask,
    [switch]$RemoveScheduledTask,
    [string]$RepoRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

function Say([string]$msg, [string]$color) {
    if ($Silent) { Write-Host $msg } else { Write-Host $msg -ForegroundColor $color }
}
function Ok([string]$msg) { Say "    [ok] $msg" "Green" }
function Skip([string]$msg) { Say "    [--] $msg" "DarkYellow" }
function Note([string]$msg) { Say "==> $msg" "Cyan" }
function Fix([string]$msg) { Say "    [fix] $msg" "Yellow" }

function Get-HarnessHome {
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return $env:DSH_HOME }
    $cand = Join-Path $env:APPDATA "dsh-desktop\harness"
    if (Test-Path $cand) { return $cand }
    throw "找不到 dsh harness 目录(可用 DSH_HOME 指定)"
}

function Get-AppNodeModules {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\resources\app\node_modules"),
        (Join-Path $env:LOCALAPPDATA "Programs\dsh-desktop\resources\app\node_modules"),
        (Join-Path ${env:ProgramFiles} "DSH Desktop\resources\app\node_modules"),
        (Join-Path ${env:ProgramFiles(x86)} "DSH Desktop\resources\app\node_modules")
    )
    foreach ($c in $cands) { if (Test-Path (Join-Path $c "@deepseek-ai")) { return $c } }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $c = Join-Path (Split-Path -Parent $proc.Path) "resources\app\node_modules"
        if (Test-Path (Join-Path $c "@deepseek-ai")) { return $c }
    }
    return $null
}

function Get-Utf8NoBomWriter { return New-Object System.Text.UTF8Encoding($false) }

$fixed = 0
$harness = Get-HarnessHome
$appModules = Get-AppNodeModules
if (-not $appModules) { throw "找不到 DSH Desktop 依赖树,无法自愈。请确认桌面版已安装。" }
$dst = Join-Path $harness "profiles\web\plugins\dsh-zen-proxy"
$src = Join-Path $RepoRoot "plugins\dsh-zen-proxy"

Note "自愈检查: $harness"

if (-not (Test-Path (Join-Path $dst "index.js"))) {
    if (-not (Test-Path (Join-Path $src "index.js"))) { throw "仓库插件缺失: $src" }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item (Join-Path $src "index.js"), (Join-Path $src "package.json"), (Join-Path $src "LICENSE") -Destination $dst -Force
    Fix "重新部署插件文件 -> $dst"
    $script:fixed++
} else { Skip "插件文件存在" }

$link = Join-Path $dst "node_modules\@deepseek-ai"
$target = Join-Path $appModules "@deepseek-ai"
if (Test-Path $link) {
    $item = Get-Item $link -Force
    if ($item.LinkType -ne "Junction") {
        if ($item.PSIsContainer) { Remove-Item $link -Recurse -Force } else { Remove-Item $link -Force }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Fix "重建 junction(原为普通目录/文件)"
        $script:fixed++
    } elseif (($item.Target | Select-Object -First 1) -ne $target) {
        Remove-Item $link -Force
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Fix "重建 junction(目标变更 -> $target)"
        $script:fixed++
    } else { Skip "junction 正常: $target" }
} else {
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Fix "创建缺失的 junction -> $target"
    $script:fixed++
}

$patchFile = Join-Path $harness "profiles\web\cordis.patch.yml"
if (-not (Test-Path $patchFile)) { throw "cordis.patch.yml 不存在: $patchFile" }
$raw = [System.IO.File]::ReadAllText($patchFile)
if ($raw -notmatch "zen-proxy") {
    $entry = @"
# dsh-zen-desktop: 为 opencode.ai/zen 上游注入官方 opencode 客户端头
- insert:
    - id: zen-proxy
      name: './plugins/dsh-zen-proxy/index.js'
      config:
        host: 127.0.0.1
        port: $Port
        upstreamHost: opencode.ai
        upstreamBasePath: /zen/v1
"@
    $trimmed = $raw.Trim()
    $new = if ($trimmed -eq "[]") { $entry } else { $raw.TrimEnd() + "`r`n" + $entry }
    [System.IO.File]::WriteAllText($patchFile, $new + "`r`n", (Get-Utf8NoBomWriter))
    Fix "补回 cordis.patch.yml 中的 zen-proxy 注册"
    $script:fixed++
} else { Skip "cordis.patch.yml 已注册 zen-proxy" }

$settingsFile = Join-Path $harness "settings.yaml"
if (Test-Path $settingsFile) {
    $raw = [System.IO.File]::ReadAllText($settingsFile)
    if ($raw -notmatch [regex]::Escape("http://127.0.0.1:$Port/v1")) {
        if ($raw -match "(?m)^opencode:\s*$") {
            $block = $raw.Substring($raw.IndexOf([regex]::Match($raw, "(?m)^opencode:\s*$").Index))
            $nextKey = [regex]::Match($block, "(?m)^\S.*$", "RightToLeft")
            $end = $nextKey.Index + $nextKey.Length
            $newBlock = $block.Substring(0, $end) -replace "(?m)^(\s*)baseURL:.*$", "`$1baseURL: http://127.0.0.1:$Port/v1"
            $new = $raw.Substring(0, $raw.IndexOf([regex]::Match($raw, "(?m)^opencode:\s*$").Index)) + $newBlock + $block.Substring($end)
            [System.IO.File]::WriteAllText($settingsFile, $new, (Get-Utf8NoBomWriter))
            Fix "settings.yaml: baseURL 已指回本地代理"
            $script:fixed++
        } else { Say "    [warn] settings.yaml 中无 opencode provider,请运行 install.ps1" "Yellow" }
    } else { Skip "settings.yaml baseURL 指向本地代理" }
} else { Say "    [warn] settings.yaml 不存在,请运行 install.ps1" "Yellow" }

$storages = Join-Path $harness "storages"
if (Test-Path $storages) {
    foreach ($f in Get-ChildItem $storages -Filter "*.json" -File) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            [System.IO.File]::WriteAllBytes($f.FullName, $bytes[3..($bytes.Length - 1)])
            Fix "去除 BOM: $($f.Name)"
            $script:fixed++
        }
    }
}

if ($RemoveScheduledTask) {
    Unregister-ScheduledTask -TaskName "dsh-zen-desktop-repair" -Confirm:$false -ErrorAction SilentlyContinue
    Say "计划任务已移除" "Green"
} elseif ($CreateScheduledTask) {
    $existing = Get-ScheduledTask -TaskName "dsh-zen-desktop-repair" -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    if ($existing) {
        Set-ScheduledTask -TaskName "dsh-zen-desktop-repair" -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Say "计划任务已更新: dsh-zen-desktop-repair(登录时自动自愈)" "Green"
    } else {
        Register-ScheduledTask -TaskName "dsh-zen-desktop-repair" -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Say "已注册计划任务: dsh-zen-desktop-repair(登录时自动自愈)" "Green"
    }
}

if ($script:fixed -eq 0) {
    Say "检查完毕,全部正常,无需修复。" "Green"
} else {
    Say "检查完毕,共修复 $script:fixed 项。如 DSH Desktop 正在运行,请重启应用。" "Yellow"
}
