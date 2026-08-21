#requires -Version 5.1
<#
    dsh-zen-desktop 共享逻辑模块。
    所有纯逻辑(文本处理/路径定位/校验)都放在这里,供 install/repair/uninstall/add-key/check 与 Pester 测试共用。
    要求: Windows PowerShell 5.1+ 兼容(无三元、无 ??、无 &&)。
#>
Set-StrictMode -Version Latest

# ---------- 常量 ----------
$script:PluginName = "zen-proxy"
$script:PluginDirName = "dsh-zen-proxy"
$script:DefaultUpstreamHost = "opencode.ai"
$script:DefaultUpstreamBasePath = "/zen/v1"
$script:OfficialBaseUrl = "https://opencode.ai/zen/v1"
$script:BackupSuffix = ".dsh-zen-backup"
$script:ScheduleTaskName = "dsh-zen-desktop-repair"
$script:DefaultModels = @(
    "deepseek-v4-flash-free",
    "deepseek-v3-flash-free",
    "deepseek-v3.2-free",
    "deepseek-v3.1-free",
    "deepseek-v3-free",
    "deepseek-r1-flash-free"
)

# ---------- 路径定位 ----------
function Get-HarnessHome {
    <#
    .SYNOPSIS
        定位 dsh harness 目录(DSH_HOME 或 %APPDATA%\dsh-desktop\harness)。
    #>
    if ($env:DSH_HOME) {
        if (Test-Path $env:DSH_HOME) { return $env:DSH_HOME }
        Write-Warning "DSH_HOME 已设置但目录不存在: $env:DSH_HOME"
    }
    if (-not $env:APPDATA) {
        throw "环境变量 APPDATA 未设置(非交互式账户?),无法定位 dsh harness 目录。请设置 DSH_HOME 后重试。"
    }
    $cand = Join-Path $env:APPDATA "dsh-desktop\harness"
    if (Test-Path $cand) { return $cand }
    throw "找不到 dsh harness 目录。请设置环境变量 DSH_HOME 后重试。"
}

function Get-AppNodeModules {
    <#
    .SYNOPSIS
        定位 DSH Desktop 安装目录中持有 @deepseek-ai/schemastery 的 node_modules。
        仅检查 schemastery 存在才认定有效(避免 DSH 更新改名后 junction 指向空心目录)。
    #>
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $cands.Add((Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\resources\app\node_modules"))
        $cands.Add((Join-Path $env:LOCALAPPDATA "Programs\dsh-desktop\resources\app\node_modules"))
    }
    if (${env:ProgramFiles}) {
        $cands.Add((Join-Path ${env:ProgramFiles} "DSH Desktop\resources\app\node_modules"))
    }
    if (${env:ProgramFiles(x86)}) {
        $cands.Add((Join-Path ${env:ProgramFiles(x86)} "DSH Desktop\resources\app\node_modules"))
    }
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c "@deepseek-ai\schemastery")) { return $c }
    }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
        $c = Join-Path (Split-Path -Parent $proc.Path) "resources\app\node_modules"
        if (Test-Path (Join-Path $c "@deepseek-ai\schemastery")) { return $c }
    }
    return $null
}

function Get-DshExe {
    <#
    .SYNOPSIS
        定位 DSH Desktop 可执行文件;找不到返回 $null。
    #>
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $cands.Add((Join-Path $env:LOCALAPPDATA "Programs\DSH Desktop\DSH Desktop.exe"))
        $cands.Add((Join-Path $env:LOCALAPPDATA "Programs\dsh-desktop\dsh-desktop.exe"))
    }
    if (${env:ProgramFiles}) {
        $cands.Add((Join-Path ${env:ProgramFiles} "DSH Desktop\DSH Desktop.exe"))
    }
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $proc = Get-Process -Name "DSH Desktop" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) { return $proc.Path }
    return $null
}

function Get-Utf8NoBomWriter {
    <#
    .SYNOPSIS
        返回无 BOM 的 UTF-8 编码器(所有写文件的统一入口,避免 BOM 破坏 harness 启动)。
    #>
    return New-Object System.Text.UTF8Encoding($false)
}

# ---------- YAML 纯文本处理(核心,可测) ----------
function ConvertTo-ProviderBlock {
    <#
    .SYNOPSIS
        生成一个 provider 的 YAML 块文本(不含尾部换行)。
    .PARAMETER ProviderName
        provider 键名(如 opencode / opencode-2)。
    .PARAMETER ApiKeyEnv
        apiKeyEnv 环境变量名。
    .PARAMETER BaseUrl
        baseURL 值。
    .PARAMETER Models
        模型列表。
    .PARAMETER Indent
        字段级缩进单位(默认 4 空格)。模型项自动再缩进一级。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$ApiKeyEnv,
        [Parameter(Mandatory)][string]$BaseUrl,
        [string[]]$Models = $script:DefaultModels,
        [string]$Indent = "    "
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("${ProviderName}:")
    $lines.Add("${Indent}apiKeyEnv: $ApiKeyEnv")
    $lines.Add("${Indent}baseURL: $BaseUrl")
    $lines.Add("${Indent}models:")
    foreach ($m in $Models) { $lines.Add("${Indent}${Indent}- $m") }
    return ($lines -join "`r`n")
}

function Get-ProviderFieldIndent {
    <#
    .SYNOPSIS
        (内部 helper)从 provider 块文本推断"字段缩进"。
        取块内第一个缩进大于 provider 键行的行作为字段缩进;
        若块内只有键行(空块),沿用键缩进 + 4 空格。
        供 Set-ProviderBaseUrl 补 apiKeyEnv 时对齐用,避免与 provider 键同层。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Block)
    $keyM = [regex]::Match($Block, "(?m)^(\s*)\S")
    if (-not $keyM.Success) { return "    " }
    $keyInd = $keyM.Groups[1].Value
    $fieldM = [regex]::Match($Block, "(?m)^(\s{$($keyInd.Length + 1)},)\S")
    if ($fieldM.Success) { return $fieldM.Groups[1].Value }
    return $keyInd + "    "
}

function Get-ProvidersChildStep {
    <#
    .SYNOPSIS
        (内部 helper)从 providers 行缩进与其下第一个子键缩进之差推导 YAML 层级步进(通常 2 或 4)。
        无子键时默认 2。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$ScanStart,
        [Parameter(Mandatory)][string]$ProvidersIndent
    )
    $child = [regex]::Match($Text.Substring($ScanStart), "(?m)^(\s*)\S")
    if ($child.Success -and $child.Groups[1].Value.Length -gt $ProvidersIndent.Length) {
        return $child.Groups[1].Value.Length - $ProvidersIndent.Length
    }
    return 2
}

function Find-YamlBlock {
    <#
    .SYNOPSIS
        在文本中定位 "key:" 块,返回块起止位置(下一顶层键之前 / 文本末尾)。
    .PARAMETER Text
        YAML 文本。
    .PARAMETER Key
        顶层或任意层级的键名(自动转义)。
    .OUTPUTS
        $null(找不到) 或 pscustomobject { Start, End, Length, Block, HasNext }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key
    )
    $esc = [regex]::Escape($Key)
    $m = [regex]::Match($Text, "(?m)^(\s*)$esc\s*:\s*$")
    if (-not $m.Success) { return $null }
    $indentLen = $m.Groups[1].Value.Length
    $blockStart = $m.Index + $m.Length
    $rest = $Text.Substring($blockStart)
    # 块结束 = 下一个"缩进小于等于当前 key"的非空行(同层或更上层)。
    # 不能只找 ^\S(零缩进),因为 providers 下的 provider 全是缩进同级,会把相邻 provider 吞进块。
    $boundary = "(?m)^[ \t]{0,$indentLen}\S"
    $next = [regex]::Match($rest, $boundary)
    if ($next.Success) {
        $blockEnd = $blockStart + $next.Index
        $hasNext = $true
    } else {
        $blockEnd = $Text.Length
        $hasNext = $false
    }
    return [pscustomobject]@{
        Start     = $m.Index
        End       = $blockEnd
        Length    = $blockEnd - $m.Index
        IndentLen = $indentLen
        Block     = $Text.Substring($m.Index, $blockEnd - $m.Index)
        HasNext   = $hasNext
    }
}

function Set-ProviderBaseUrl {
    <#
    .SYNOPSIS
        (纯函数)把 settings.yaml 中指定 provider 的 baseURL 指向本地代理,并确保 apiKeyEnv 存在。
        已指向目标则原样返回。
    .PARAMETER Text
        原始 YAML 文本(不读盘,便于测试)。
    .PARAMETER Port
        本地代理端口(默认 4097)。
    .PARAMETER ProviderName
        provider 键名(默认 opencode)。
    .PARAMETER ApiKeyEnv
        环境变量名(默认 OPENCODE_API_KEY)。
    .PARAMETER Models
        provider 不存在时需要新增的模型列表。
    .OUTPUTS
        pscustomobject { Text, Changed, Action }。Action: skip / updated / added。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Port = 4097,
        [string]$ProviderName = "opencode",
        [string]$ApiKeyEnv = "OPENCODE_API_KEY",
        [string[]]$Models = $script:DefaultModels
    )
    $proxyUrl = "http://127.0.0.1:$Port/v1"

    # 已指向本地代理 -> 不动
    if ($Text.IndexOf($proxyUrl, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return [pscustomobject]@{ Text = $Text; Changed = $false; Action = "skip" }
    }

    # provider 不存在 -> 新增(缩进对齐现有 provider,避免错层)
    $found = Find-YamlBlock -Text $Text -Key $ProviderName
    if (-not $found) {
        $ins = [regex]::Match($Text, "(?m)^(\s*)providers:\s*$")
        if (-not $ins.Success) { throw "settings.yaml 中未找到 llm-pi-ai.providers,请手动检查配置" }
        $after = $ins.Index + $ins.Length
        $step = Get-ProvidersChildStep -Text $Text -ScanStart $after -ProvidersIndent $ins.Groups[1].Value
        $providerIndent = $ins.Groups[1].Value + (" " * $step)
        $fieldIndent = $providerIndent + (" " * $step)
        $blockText = ConvertTo-ProviderBlock -ProviderName $ProviderName -ApiKeyEnv $ApiKeyEnv -BaseUrl $proxyUrl -Models $Models -Indent $fieldIndent
        $new = $Text.Substring(0, $after) + "`r`n" + $providerIndent + $blockText.Replace("`r`n", "`r`n" + $providerIndent) + $Text.Substring($after)
        return [pscustomobject]@{ Text = $new; Changed = $true; Action = "added" }
    }

    # provider 存在 -> 块内替换 baseURL / 补 apiKeyEnv
    # 注意用 [^\r\n]* 而非 .*,避免吞掉行尾 \r 导致 CRLF 混成 LF
    $block = $found.Block
    $newBlock = $block -replace "(?m)^(\s*)baseURL:[^\r\n]*$", ('${1}baseURL: ' + $proxyUrl)
    if ($newBlock -notmatch "apiKeyEnv:\s*\S") {
        $apikeyLine = '${1}apiKeyEnv: ' + $ApiKeyEnv + "`r`n" + '${1}models:'
        if ($newBlock -match "(?m)^(\s*)models:") {
            $newBlock = $newBlock -replace "(?m)^(\s*)models:", $apikeyLine
        } else {
            $fieldIndent = Get-ProviderFieldIndent -Block $newBlock
            $newBlock = $newBlock.TrimEnd() + "`r`n" + $fieldIndent + "apiKeyEnv: $ApiKeyEnv" + "`r`n"
        }
    }
    $new = $Text.Substring(0, $found.Start) + $newBlock + $Text.Substring($found.End)
    return [pscustomobject]@{ Text = $new; Changed = $true; Action = "updated" }
}

function Restore-OfficialBaseUrl {
    <#
    .SYNOPSIS
        (纯函数)把 providers 中所有指向本地代理的 baseURL 恢复为官方直连。
        供 uninstall 在无备份时回退用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$OfficialUrl = $script:OfficialBaseUrl
    )
    $new = $Text -replace "(?m)^(\s*)baseURL:\s*http://127\.0\.0\.1:\d+/v1[^\r\n]*$", ('${1}baseURL: ' + $OfficialUrl)
    return $new
}

function Add-ZenProxyPatchEntry {
    <#
    .SYNOPSIS
        (纯函数)在 cordis.patch.yml 中追加 zen-proxy 注册条目,幂等。
    .PARAMETER Text
        原始 patch 文本。
    .PARAMETER Port
        代理端口。
    .OUTPUTS
        pscustomobject { Text, Changed }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Port = 4097
    )
    if ($Text -match "zen-proxy") {
        return [pscustomobject]@{ Text = $Text; Changed = $false }
    }
    $entry = @"
# dsh-zen-desktop: 为 opencode.ai/zen 上游注入官方 opencode 客户端头,解除 429 限流
- insert:
    - id: zen-proxy
      name: './plugins/dsh-zen-proxy/index.js'
      config:
        host: 127.0.0.1
        port: $Port
        upstreamHost: $script:DefaultUpstreamHost
        upstreamBasePath: $script:DefaultUpstreamBasePath
"@
    $trimmed = $Text.Trim()
    $new = if ($trimmed -eq "[]") { $entry } else { $Text.TrimEnd() + "`r`n" + $entry }
    return [pscustomobject]@{ Text = $new + "`r`n"; Changed = $true }
}

function Remove-ZenProxyPatchEntry {
    <#
    .SYNOPSIS
        (纯函数)从 cordis.patch.yml 移除 zen-proxy 注册条目,幂等。
        按顶层 "- insert:" 块切分,凡是块内含 zen-proxy 的条目整体丢弃。
        不依赖任何注释行,可处理手工录入的条目。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Text)
    if ($Text -notmatch "zen-proxy") {
        return [pscustomobject]@{ Text = $Text; Changed = $false }
    }
    $segments = [regex]::Matches($Text, "(?s)(?m)^- insert:.*?(?=^- insert:|\z)")
    $kept = New-Object System.Collections.Generic.List[string]
    $changed = $false
    if ($segments.Count -eq 0) {
        # 没有标准 "- insert:" 条目,但文本里含 zen-proxy(异常格式):整体清空
        return [pscustomobject]@{ Text = ""; Changed = $true }
    }
    foreach ($seg in $segments) {
        if ($seg.Value -match "zen-proxy") { $changed = $true; continue }
        $kept.Add($seg.Value)
    }
    $new = ($kept -join "").TrimEnd()
    return [pscustomobject]@{ Text = $new; Changed = $changed }
}

function Set-CredentialValue {
    <#
    .SYNOPSIS
        (纯函数)在 .credentials.yaml 中写入/更新 envName 的值,幂等。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][string]$Value
    )
    $line = "${EnvName}: $Value"
    $pattern = "(?m)^$([regex]::Escape($EnvName))\s*:\s*\S+"
    if ($Text -match $pattern) {
        $new = [regex]::Replace($Text, $pattern, $line)
        $action = "updated"
    } else {
        $new = $Text.TrimEnd() + "`r`n" + $line
        $action = "added"
    }
    return [pscustomobject]@{ Text = $new; Changed = $true; Action = $action }
}

function Remove-CredentialValue {
    <#
    .SYNOPSIS
        (纯函数)删除 .credentials.yaml 中的某个键,幂等。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$EnvName
    )
    if ($Text -notmatch "(?m)^$([regex]::Escape($EnvName))\s*:\s*\S+\r?\n?") {
        return [pscustomobject]@{ Text = $Text; Changed = $false }
    }
    $new = [regex]::Replace($Text, "(?m)^$([regex]::Escape($EnvName))\s*:\s*\S+\r?\n?", "")
    return [pscustomobject]@{ Text = $new; Changed = $true }
}

# ---------- 结账/校验 ----------
function Get-JunctionStatus {
    <#
    .SYNOPSIS
        (只读)检查 junction 状态。返回 pscustomobject { Exists, Type, TargetMatches, LinkType, Target }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )
    if (-not (Test-Path $Link)) {
        return [pscustomobject]@{ Exists = $false; LinkType = $null; TargetMatches = $false; Target = $null }
    }
    $item = Get-Item $Link -Force
    $t = $null
    if ($item.LinkType) { $t = ($item.Target | Select-Object -First 1) }
    $matches = [bool]$t -and $t -imatch [regex]::Escape($ExpectedTarget)
    return [pscustomobject]@{
        Exists        = $true
        LinkType      = $item.LinkType
        TargetMatches = $matches
        Target        = $t
    }
}

function Get-PluginDeployment {
    <#
    .SYNOPSIS
        (只读)汇总某个 harness 下的部署状态,供 check.ps1 / repair.ps1 使用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$AppNodeModules,
        [string]$PluginDirName = $script:PluginDirName
    )
    $dst = Join-Path $Harness "profiles\web\plugins\$PluginDirName"
    $link = Join-Path $dst "node_modules\@deepseek-ai"
    $target = Join-Path $AppNodeModules "@deepseek-ai"
    $patchFile = Join-Path $Harness "profiles\web\cordis.patch.yml"
    $settingsFile = Join-Path $Harness "settings.yaml"
    $credFile = Join-Path $Harness ".credentials.yaml"

    $result = [ordered]@{
        Harness          = $Harness
        AppNodeModules   = $AppNodeModules
        PluginDir        = $dst
        PluginExists     = Test-Path (Join-Path $dst "index.js")
        Junction         = Get-JunctionStatus -Link $link -ExpectedTarget $target
        PatchRegistered  = $false
        PatchFile        = $patchFile
        SettingsBaseUrl  = $null
        SettingsApiKeyEnv = $null
        SettingsModels   = $null
        CredentialKeySet = $false
        PortElevated     = $false
        Port             = $null
    }

    if (Test-Path $patchFile) {
        $patchText = [System.IO.File]::ReadAllText($patchFile)
        $result.PatchRegistered = $patchText -match "zen-proxy"
        $pm = [regex]::Match($patchText, "(?m)^\s*port:\s*(\d+)")
        if ($pm.Success) { $result.Port = [int]$pm.Groups[1].Value }
    }

    if (Test-Path $settingsFile) {
        $yamlText = [System.IO.File]::ReadAllText($settingsFile)
        $found = Find-YamlBlock -Text $yamlText -Key "opencode"
        if ($found) {
            $bm = [regex]::Match($found.Block, "(?m)^\s*baseURL:\s*(\S+)")
            if ($bm.Success) { $result.SettingsBaseUrl = $bm.Groups[1].Value.Trim() }
            $em = [regex]::Match($found.Block, "(?m)^\s*apiKeyEnv:\s*(\S+)")
            if ($em.Success) { $result.SettingsApiKeyEnv = $em.Groups[1].Value.Trim() }
            $models = [regex]::Matches($found.Block, "(?m)^\s*-\s*(\S+)")
            if ($models.Count -gt 0) { $result.SettingsModels = @($models | ForEach-Object { $_.Groups[1].Value }) }
        }
    }

    if (Test-Path $credFile) {
        $credText = [System.IO.File]::ReadAllText($credFile)
        $result.CredentialKeySet = $credText -match "(?m)^OPENCODE_API_KEY\s*:\s*\S+"
    }

    if ($result.Port) {
        $tcp = Get-NetTCPConnection -LocalPort $result.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $result.PortElevated = [bool]$tcp
    }

    return [pscustomobject]$result
}

function Test-StringHasBom {
    <#
    .SYNOPSIS
        (只读)检查字节数组是否带 UTF-8 BOM。不经磁盘、不修改。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

Export-ModuleMember -Function @(
    "Get-HarnessHome",
    "Get-AppNodeModules",
    "Get-DshExe",
    "Get-Utf8NoBomWriter",
    "ConvertTo-ProviderBlock",
    "Find-YamlBlock",
    "Set-ProviderBaseUrl",
    "Restore-OfficialBaseUrl",
    "Add-ZenProxyPatchEntry",
    "Remove-ZenProxyPatchEntry",
    "Set-CredentialValue",
    "Remove-CredentialValue",
    "Get-JunctionStatus",
    "Get-PluginDeployment",
    "Test-StringHasBom"
)