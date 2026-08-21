#requires -Version 5.1
<#
.SYNOPSIS
    dsh-zen-desktop 一键安装器 —— 让 DSH Desktop(Windows 桌面版)免 429 使用 OpenCode Zen 免费模型。

.DESCRIPTION
    在 DSH Desktop 中部署 dsh-zen-proxy 本地代理:
      1. 将代理插件(vendored 于本仓库 plugins\dsh-zen-proxy)复制到 DSH_HOME 的 web profile;
      2. 在 profiles\web\node_modules 下创建 @deepseek-ai 的 junction(指向 DSH Desktop 安装目录内的依赖树),
         使插件能解析 @deepseek-ai/schemastery;
      3. 在 profiles\web\cordis.patch.yml 中注册 zen-proxy 插件(幂等,重复执行安全);
      4. 将 settings.yaml 中 llm-pi-ai.providers.opencode 的 baseURL 指向 http://127.0.0.1:<Port>/v1;
      5. 在 .credentials.yaml 中配置 OPENCODE_API_KEY(若未传入 -Key 且已存在则保留);
      6. 修复 storages\*.json 中可能存在的 UTF-8 BOM(会导致 harness 启动失败);
      7. 可选:重启 DSH Desktop 并等待代理端口监听。

.NOTES
    所有操作均针对 DSH_HOME(AppData\Roaming\dsh-desktop\harness)与 DSH Desktop 安装目录,
    不会修改 DSH Desktop 安装目录下的任何文件 —— 应用更新后无需重新安装本工具。
#>
[CmdletBinding()]
param(
    [string]$Key,
    [int]$Port = 4097,
    [switch]$NoRestart,
    [switch]$NoTest,
    [string]$RepoRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Skip([string]$msg) { Write-Host "    [--] $msg" -ForegroundColor DarkYellow }

function Get-HarnessHome {
    if ($env:DSH_HOME) {
        if (Test-Path $env:DSH_HOME) { return $env:DSH_HOME }
        Write-Warning "DSH_HOME 已设置但目录不存在: $env:DSH_HOME"
    }
    $cand = Join-Path $env:APPDATA "dsh-desktop\harness"
    if (Test-Path $cand) { return $cand }
    throw "找不到 dsh harness 目录。请设置环境变量 DSH_HOME 后重试。"
}

function Get-AppNodeModules {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\resources\app\node_modules"),
        (Join-Path $env:LOCALAPPDATA "Programs\dsh-desktop\resources\app\node_modules"),
        (Join-Path ${env:ProgramFiles} "DSH Desktop\resources\app\node_modules"),
        (Join-Path ${env:ProgramFiles(x86)} "DSH Desktop\resources\app\node_modules")
    )
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c "@deepseek-ai")) { return $c }
    }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $base = Split-Path -Parent $proc.Path
        $c = Join-Path $base "resources\app\node_modules"
        if (Test-Path (Join-Path $c "@deepseek-ai")) { return $c }
    }
    throw "找不到 DSH Desktop 安装目录。请确认已安装 DSH Desktop 桌面版,或手动指定。"
}

function Get-DshExe {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\DSH Desktop.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\dsh-desktop\dsh-desktop.exe"),
        (Join-Path ${env:ProgramFiles} "DSH Desktop\DSH Desktop.exe")
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { return $proc.Path }
    return $null
}

function Ensure-Junction([string]$Link, [string]$Target) {
    if (Test-Path $Link) {
        $item = Get-Item $Link -Force
        if ($item.LinkType -eq "Junction") {
            $cur = try { ($item.Target | Select-Object -First 1) } catch { $null }
            if ($cur -and $cur -eq $Target) { Write-Skip "junction 已存在且指向正确: $Link"; return }
            Write-Host "        junction 指向不符($cur),重建..."
            Remove-Item $Link -Force
        } else {
            Write-Host "        发现普通目录/文件,移除后重建 junction..."
            if ($item.PSIsContainer) { Remove-Item $Link -Recurse -Force } else { Remove-Item $Link -Force }
        }
    }
    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    Write-Ok "已创建 junction: $Link => $Target"
}

function Get-Utf8NoBomWriter {
    return New-Object System.Text.UTF8Encoding($false)
}

function Update-CordisPatch([string]$Harness) {
    $patchFile = Join-Path $Harness "profiles\web\cordis.patch.yml"
    if (-not (Test-Path $patchFile)) { throw "找不到 cordis.patch.yml: $patchFile" }
    $raw = [System.IO.File]::ReadAllText($patchFile)
    if ($raw -match "zen-proxy") { Write-Skip "cordis.patch.yml 已包含 zen-proxy 注册"; return }
    $entry = @"
# dsh-zen-desktop: 为 opencode.ai/zen 上游注入官方 opencode 客户端头,解除 429 限流
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
    if ($trimmed -eq "[]") {
        $new = $entry
    } else {
        $new = $raw.TrimEnd() + "`r`n" + $entry
    }
    [System.IO.File]::WriteAllText($patchFile, $new + "`r`n", (Get-Utf8NoBomWriter))
    Write-Ok "已注册 zen-proxy(port=$Port)到 cordis.patch.yml"
}

function Update-SettingsYaml([string]$Harness, [int]$Port) {
    $settingsFile = Join-Path $Harness "settings.yaml"
    if (-not (Test-Path $settingsFile)) { throw "找不到 settings.yaml: $settingsFile" }
    $backup = "$settingsFile.dsh-zen-backup"
    if (-not (Test-Path $backup)) {
        Copy-Item $settingsFile $backup -Force
        Write-Ok "已备份原始配置 -> settings.yaml.dsh-zen-backup"
    }
    $raw = [System.IO.File]::ReadAllText($settingsFile)
    $proxyUrl = "http://127.0.0.1:$Port/v1"
    if ($raw -match [regex]::Escape($proxyUrl)) { Write-Skip "settings.yaml 已指向本地代理"; return }

    if ($raw -match "(?m)^\s*baseURL:\s*https://opencode\.ai/zen/v1\s*$") {
        $new = $raw -replace "(?m)^\s*baseURL:\s*https://opencode\.ai/zen/v1\s*$", "      baseURL: $proxyUrl"
        Write-Ok "settings.yaml: baseURL -> $proxyUrl"
    } elseif ($raw -match "(?m)^opencode:\s*$") {
        $block = $raw.Substring($raw.IndexOf([regex]::Match($raw, "(?m)^opencode:\s*$").Index))
        $nextKey = [regex]::Match($block, "(?m)^\S.*$", "RightToLeft")
        $end = $nextKey.Index + $nextKey.Length
        $opencodeBlock = $block.Substring(0, $end)
        $newBlock = $opencodeBlock -replace "(?m)^(\s*)baseURL:.*$", "`$1baseURL: $proxyUrl"
        if ($newBlock -notmatch "apiKeyEnv:\s*OPENCODE_API_KEY") {
            $newBlock = $newBlock -replace "(?m)^(\s*)models:", "`$1apiKeyEnv: OPENCODE_API_KEY`r`n`$1models:"
        }
        $new = $raw.Substring(0, $raw.IndexOf([regex]::Match($raw, "(?m)^opencode:\s*$").Index)) + $newBlock + $block.Substring($end)
        Write-Ok "settings.yaml: 已更新 opencode provider(baseURL=$proxyUrl)"
    } else {
        $provider = @"
opencode:
    apiKeyEnv: OPENCODE_API_KEY
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
        if (-not $insertAfter.Success) { throw "settings.yaml 中未找到 llm-pi-ai.providers,请手动检查配置" }
        $pos = $insertAfter.Index + $insertAfter.Length
        $new = $raw.Substring(0, $pos) + "`r`n        " + $provider.Replace("`r`n", "`r`n        ") + $raw.Substring($pos)
        Write-Ok "settings.yaml: 已添加 opencode provider(baseURL=$proxyUrl)"
    }
    [System.IO.File]::WriteAllText($settingsFile, $new, (Get-Utf8NoBomWriter))
}

function Update-Credentials([string]$Harness, [string]$Key) {
    $credFile = Join-Path $Harness ".credentials.yaml"
    $raw = [System.IO.File]::ReadAllText($credFile)
    $linePattern = "(?m)^OPENCODE_API_KEY:\s*\S+"
    if ($Key) {
        $line = "OPENCODE_API_KEY: $Key"
        if ($raw -match $linePattern) {
            $raw = [regex]::Replace($raw, $linePattern, $line)
            Write-Ok ".credentials.yaml: 已更新 OPENCODE_API_KEY"
        } else {
            $raw = $raw.TrimEnd() + "`r`n" + $line
            Write-Ok ".credentials.yaml: 已添加 OPENCODE_API_KEY"
        }
    } elseif ($raw -match $linePattern) {
        Write-Skip ".credentials.yaml 已配置 OPENCODE_API_KEY(如需更换请用 -Key 参数)"
    } else {
        Write-Host "    dsh 目前未配置 OPENCODE_API_KEY。"
        Write-Host "    请在 https://opencode.ai/account 登录后创建 API key(需为登录账号的 key,匿名 key 无效)。"
        $inputKey = Read-Host "    粘贴你的 Zen API key"
        if ([string]::IsNullOrWhiteSpace($inputKey)) { throw "未提供 key,中止。可稍后重跑本脚本。:)" }
        $raw = $raw.TrimEnd() + "`r`nOPENCODE_API_KEY: " + $inputKey.Trim()
        Write-Ok ".credentials.yaml: 已配置 OPENCODE_API_KEY"
    }
    [System.IO.File]::WriteAllText($credFile, $raw, (Get-Utf8NoBomWriter))
}

function Repair-StorageBom([string]$Harness) {
    $storages = Join-Path $Harness "storages"
    if (-not (Test-Path $storages)) { return }
    foreach ($f in Get-ChildItem $storages -Filter "*.json" -File) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            [System.IO.File]::WriteAllBytes($f.FullName, $bytes[3..($bytes.Length - 1)])
            Write-Ok "已去除 BOM: $($f.Name)(避免 harness 启动报 'file is not valid JSON')"
        }
    }
}

# ---------- 主流程 ----------
Write-Step "定位 dsh harness 与 DSH Desktop 安装目录"
$harness = Get-HarnessHome
$appModules = Get-AppNodeModules
Write-Ok "DSH_HOME: $harness"
Write-Ok "应用依赖: $appModules"

Write-Step "部署 dsh-zen-proxy 插件"
$src = Join-Path $RepoRoot "plugins\dsh-zen-proxy"
$dst = Join-Path $harness "profiles\web\plugins\dsh-zen-proxy"
if (-not (Test-Path (Join-Path $src "index.js"))) { throw "仓库插件目录不完整: $src" }
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item (Join-Path $src "index.js"), (Join-Path $src "package.json"), (Join-Path $src "LICENSE") -Destination $dst -Force
Write-Ok "插件已复制到 $dst"

Write-Step "创建 @deepseek-ai 依赖 junction"
Ensure-Junction -Link (Join-Path $dst "node_modules\@deepseek-ai") -Target (Join-Path $appModules "@deepseek-ai")

Write-Step "注册插件到 cordis.patch.yml"
Update-CordisPatch -Harness $harness

Write-Step "配置 settings.yaml"
Update-SettingsYaml -Harness $harness -Port $Port

Write-Step "配置 API key"
Update-Credentials -Harness $harness -Key $Key

Write-Step "修复 storages JSON BOM"
Repair-StorageBom -Harness $harness

if ($NoRestart) {
    Write-Step "跳过重启(-NoRestart)"
} else {
    Write-Step "重启 DSH Desktop"
    $exe = Get-DshExe
    if (-not $exe) { Write-Warning "未找到 DSH Desktop.exe,请手动重启应用后验证。"; return }
    Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process $exe
    Write-Ok "已重启: $exe"
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { Write-Ok "代理已在 127.0.0.1:$Port 监听(pid=$($c.OwningProcess))"; break }
    }
    if (-not $c) {
        Write-Warning "等待超时,代理未监听。请查看 harness 日志: $harness\..\logs\harness.log"
    } elseif (-not $NoTest) {
        Write-Step "安装后冒烟测试:向本地代理发送一次请求,验证可连通 OpenCode Zen"
        try {
            $keyLine = (Get-Content (Join-Path $harness ".credentials.yaml") | Select-String '^OPENCODE_API_KEY:' | Select-Object -First 1).Line
            if ($keyLine) {
                $testKey = ($keyLine -split ':\s*', 2)[1].Trim()
                $body = '{"model":"deepseek-v4-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
                $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method POST `
                    -Headers @{ Authorization = "Bearer $testKey" } -Body $body -UseBasicParsing -TimeoutSec 30
                if ($resp.StatusCode -eq 200) {
                    Write-Ok "冒烟测试通过(HTTP 200):代理已可正常使用 OpenCode Zen 免费模型"
                } else {
                    Write-Warning "冒烟测试返回非 200 状态: $($resp.StatusCode)(部署仍成功,可稍后手动验证)"
                }
            } else {
                Write-Warning "未找到 OPENCODE_API_KEY,跳过冒烟测试(可稍后手动验证)。"
            }
        } catch {
            Write-Warning "冒烟测试未通过(可能 key 无效或额度受限;部署已完成,可稍后手动验证): $_"
        }
    }
}

Write-Step "完成"
Write-Host @"

验证方法(在 PowerShell 中执行):
  1. 在 DSH Desktop 中选择模型 opencode / deepseek-v4-flash-free
  2. 或直接冒烟测试:

     (Get-Content "$harness\.credentials.yaml" | Select-String 'OPENCODE_API_KEY').Line -replace '(?<=OPENCODE_API_KEY:\s*\S{6})\S+', '******'

  若仍遇 429/限流,检查 key 是否为登录账号创建(key 前缀 sk- 且可在 opencode.ai/account 查看)。

多 key 轮换:运行 add-key.ps1 -Key <key2> -Slot 2,然后在模型选择器中使用 opencode-2。
"@
