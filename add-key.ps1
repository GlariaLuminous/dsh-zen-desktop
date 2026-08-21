#requires -Version 5.1
<#
.SYNOPSIS
    dsh-zen-desktop 多 key 轮换助手 —— 添加第 N 个 Zen API key 与对应 provider。

.DESCRIPTION
    为 dsh 添加额外的 OpenCode Zen key:
      - 在 .credentials.yaml 写入 OPENCODE_API_KEY_<Slot>;
      - 在 settings.yaml 的 llm-pi-ai.providers 添加 opencode-<Slot> provider(与 opencode 相同的模型列表、同一本地代理)。
    使用方式:在 DSH Desktop 模型选择器中切换到 opencode-<Slot> 下的模型,即可轮换 key。
    适合有多个 opencode.ai 账号/额度受限时交替使用。

.EXAMPLE
    .\add-key.ps1 -Key sk-xxxx -Slot 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [ValidateRange(2, 9)]
    [int]$Slot = 2,
    [int]$Port = 4097
)

$ErrorActionPreference = "Stop"

function Get-HarnessHome {
    if ($env:DSH_HOME -and (Test-Path $env:DSH_HOME)) { return $env:DSH_HOME }
    $cand = Join-Path $env:APPDATA "dsh-desktop\harness"
    if (Test-Path $cand) { return $cand }
    throw "找不到 dsh harness 目录(可用 DSH_HOME 指定)"
}

function Get-Utf8NoBomWriter { return New-Object System.Text.UTF8Encoding($false) }

$harness = Get-HarnessHome
$envName = "OPENCODE_API_KEY_$Slot"
$providerName = "opencode-$Slot"
$proxyUrl = "http://127.0.0.1:$Port/v1"

$credFile = Join-Path $harness ".credentials.yaml"
$raw = [System.IO.File]::ReadAllText($credFile)
$pattern = "(?m)^$envName\s*:\s*\S+"
if ($raw -match $pattern) {
    $raw = [regex]::Replace($raw, $pattern, "${envName}: $Key")
    Write-Host "已更新 $envName" -ForegroundColor Green
} else {
    $raw = $raw.TrimEnd() + "`r`n${envName}: $Key"
    Write-Host "已添加 $envName" -ForegroundColor Green
}
[System.IO.File]::WriteAllText($credFile, $raw, (Get-Utf8NoBomWriter))

$settingsFile = Join-Path $harness "settings.yaml"
$raw = [System.IO.File]::ReadAllText($settingsFile)
if ($raw -match "(?m)^$providerName\s*:\s*$") {
    Write-Warning "settings.yaml 已存在 $providerName,跳过 provider 注册(仅更新了 key)。"
    return
}
$provider = @"
${providerName}:
    apiKeyEnv: $envName
    baseURL: $proxyUrl
    models:
        - deepseek-v4-flash-free
        - deepseek-v3-flash-free
        - deepseek-v3.2-free
        - deepseek-v3.1-free
        - deepseek-v3-free
        - deepseek-r1-flash-free
"@
$insertAfter = [regex]::Match($raw, "(?m)^\s*providers:\s*$")
if (-not $insertAfter.Success) { throw "settings.yaml 中未找到 llm-pi-ai.providers" }
$pos = $insertAfter.Index + $insertAfter.Length
$raw = $raw.Substring(0, $pos) + "`r`n        " + $provider.Replace("`r`n", "`r`n        ") + $raw.Substring($pos)
[System.IO.File]::WriteAllText($settingsFile, $raw, (Get-Utf8NoBomWriter))

Write-Host "完成。重启 DSH Desktop 后,在模型选择器中选择 $providerName 下的模型即可使用第 $Slot 个 key。" -ForegroundColor Cyan
