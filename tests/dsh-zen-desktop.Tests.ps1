#requires -Version 5.1
<#
    dsh-zen-desktop 逻辑回归测试(Pester 4/5 兼容)。

    重点覆盖历史 bug(已在本机复现过):
      - Bug A: IndexOf(Match.Index) 被解析成 IndexOf(char) 导致 Substring 崩溃/错位
      - Bug B: "找块末尾"的正则把 provider 块截断成只剩 key 行
   以及常规幂等/路径/格式场景。
#>
# 注意: Pester 5 的 Discovery 阶段(Describe 之外)与 Run 阶段(BeforeAll/It)作用域相互隔离,
# 顶层变量无法在 BeforeAll 中读取。因此模块路径改为在 BeforeAll 内部解析。

Describe "Find-YamlBlock" {
    BeforeAll {
        Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force
    }

    It "定位文件尾部的 opencode 块时应延伸到文本末尾" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Find-YamlBlock -Text $raw -Key "opencode"
        $r | Should -Not -Be $null
        $r.End | Should -Be $raw.Length
        ($r.Block -match "deepseek-v4-flash-free") | Should -Be $true
    }

    It "opencode 定位索引应精确指向 opencode 起始行(不依赖 IndexOf(char) 行为)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Find-YamlBlock -Text $raw -Key "opencode"
        # Start = 键行的行首(含缩进),直接可被 Substring 取整行
        $expected = [regex]::Match($raw, "(?m)^\s*opencode:").Index
        $r.Start | Should -Be $expected
        $raw.Substring($r.Start) | Should -Match "(?m)^\s*opencode:\s*$"
    }

    It "opencode 块后面紧跟同级 provider 时,块应止于下一个 provider(不吞并)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
    anthropic:
      baseURL: https://api.anthropic.com
"@
        $r = Find-YamlBlock -Text $raw -Key "opencode"
        # 块必须以 opencode 行起始,且止于下一个同级 provider(anthropic)之前
        ($r.Block -match "anthropic") | Should -Be $false
        ($r.Block -match "deepseek-v4-flash-free") | Should -Be $true
        ($r.Block -match "(?m)^\s*opencode:\s*$") | Should -Be $true
    }

    It "找不到 key 时返回 null" {
        $r = Find-YamlBlock -Text "a:\n  b: 1" -Key "missing"
        $r | Should -Be $null
    }
}

Describe "Block boundary correctness (Bug B regression)" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "opencode 是最后一个 provider 时,块末尾 = 文本末尾(不截断)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
        - deepseek-r1-flash-free
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "updated"
        $r.Text | Should -Match "http://127.0.0.1:4097/v1"
        # 模型的每一行都必须保留
        $r.Text | Should -Match "deepseek-v4-flash-free"
        $r.Text | Should -Match "deepseek-r1-flash-free"
        $r.Text | Should -Match "apiKeyEnv: OPENCODE_API_KEY"
        # provider 不能被截断成只有 key 行
        $found = Find-YamlBlock -Text $r.Text -Key "opencode"
        $found.Block | Should -Match "models:"
    }
}

Describe "Set-ProviderBaseUrl" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "已指向本地代理时保持原样(skip)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: http://127.0.0.1:4097/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "skip"
        $r.Changed | Should -Be $false
        $r.Text | Should -Be $raw
    }

    It "端口不同时不视为已指向(应更新为指定端口)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: http://127.0.0.1:4097/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 5000
        $r.Action | Should -Be "updated"
        $r.Text | Should -Match "http://127.0.0.1:5000/v1"
    }

    It "opencode 不存在时新增 provider(added)" {
        $raw = @"
llm-pi-ai:
  providers:
    anthropic:
      baseURL: https://api.anthropic.com
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "added"
        ($r.Text -match "(?m)^\s*opencode:\s*$") | Should -Be $true
        ($r.Text -match "http://127.0.0.1:4097/v1") | Should -Be $true
        ($r.Text -match "OPENCODE_API_KEY") | Should -Be $true
        # 原 anthropic 不能丢
        ($r.Text -match "anthropic") | Should -Be $true
    }

    It "opencode 块内无 apiKeyEnv 时自动补上(有 models 场景)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "updated"
        ($r.Text -match "(?m)^\s*apiKeyEnv: OPENCODE_API_KEY\s*$") | Should -Be $true
        ($r.Text -match "deepseek-v4-flash-free") | Should -Be $true
    }

    It "opencode 块内无 models 无 apiKeyEnv 时在块尾追加 apiKeyEnv" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      baseURL: https://opencode.ai/zen/v1
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "updated"
        ($r.Text -match "(?m)^\s*apiKeyEnv: OPENCODE_API_KEY\s*$") | Should -Be $true
    }

    It "只修改指定 provider,不影响同层其他 provider(指定 opencode-2)" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      baseURL: http://127.0.0.1:4097/v1
      models:
        - deepseek-v4-flash-free
    opencode-2:
      baseURL: http://127.0.0.1:4097/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 5000 -ProviderName "opencode-2"
        $r.Action | Should -Be "updated"
        $op = Find-YamlBlock -Text $r.Text -Key "opencode"
        $op2 = Find-YamlBlock -Text $r.Text -Key "opencode-2"
        ($op.Block -match "127\.0\.0\.1:4097") | Should -Be $true   # opencode 保持
        ($op2.Block -match "127\.0\.0\.1:5000") | Should -Be $true  # opencode-2 改成新端口
    }

    It "回转使用 Restore-OfficialBaseUrl 恢复官方直连" {
        $raw = @"
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: http://127.0.0.1:4097/v1
      models:
        - deepseek-v4-flash-free
"@
        $r = Restore-OfficialBaseUrl -Text $raw
        ($r -match "https://opencode.ai/zen/v1") | Should -Be $true
        ($r -match "127\.0\.0\.1") | Should -Be $false
        ($r -match "deepseek-v4-flash-free") | Should -Be $true
    }

    It "4 空格缩进体系下新增 provider 对齐层级(added)" {
        $raw = @"
llm-pi-ai:
    providers:
        anthropic:
            baseURL: https://api.anthropic.com
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "added"
        $lines = $r.Text -split "`r?`n"
        (@($lines | Where-Object { $_ -match '^        opencode:\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^            apiKeyEnv: OPENCODE_API_KEY\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^            baseURL: http://127\.0\.0\.1:4097/v1\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^                - deepseek-v4-flash-free\s*$' }).Count -gt 0) | Should -Be $true
        # 原 anthropic 及其字段层级不受影响
        (@($lines | Where-Object { $_ -match '^        anthropic:\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^            baseURL: https://api\.anthropic\.com\s*$' }).Count -gt 0) | Should -Be $true
    }

    It "2 空格缩进体系下新增 provider 对齐层级(added)" {
        $raw = @"
llm-pi-ai:
  providers:
    anthropic:
      baseURL: https://api.anthropic.com
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "added"
        $lines = $r.Text -split "`r?`n"
        (@($lines | Where-Object { $_ -match '^    opencode:\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^      apiKeyEnv: OPENCODE_API_KEY\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^      baseURL: http://127\.0\.0\.1:4097/v1\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^        - deepseek-v4-flash-free\s*$' }).Count -gt 0) | Should -Be $true
    }

    It "providers 无现有子键时也能新增(默认步进 2,不压扁 providers 行)" {
        $raw = @"
llm-pi-ai:
  providers:
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "added"
        # 原本的 providers: 行必须保持原样
        ($r.Text -match "(?m)^  providers:\s*$") | Should -Be $true
        $lines = $r.Text -split "`r?`n"
        (@($lines | Where-Object { $_ -match '^    opencode:\s*$' }).Count -gt 0) | Should -Be $true
        (@($lines | Where-Object { $_ -match '^      baseURL: http://127\.0\.0\.1:4097/v1\s*$' }).Count -gt 0) | Should -Be $true
    }

    It "4 空格体系下 provider 无 models 时追加 apiKeyEnv 字段缩进对齐(不退回默认 4 空格)" {
        $raw = @"
llm-pi-ai:
    providers:
        opencode:
            baseURL: https://opencode.ai/zen/v1
"@
        $r = Set-ProviderBaseUrl -Text $raw -Port 4097
        $r.Action | Should -Be "updated"
        $lines = $r.Text -split "`r?`n"
        (@($lines | Where-Object { $_ -match '^            apiKeyEnv: OPENCODE_API_KEY\s*$' }).Count -gt 0) | Should -Be $true
        # 不能与 provider 键同层
        ($r.Text -match "(?m)^        apiKeyEnv:") | Should -Be $false
    }
}

Describe "cordis.patch.yml 注册/移除" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "追加注册条目(add)" {
        $raw = "[]"
        $r = Add-ZenProxyPatchEntry -Text $raw -Port 4097
        $r.Changed | Should -Be $true
        ($r.Text -match "zen-proxy") | Should -Be $true
        ($r.Text -match "port: 4097") | Should -Be $true
    }

    It "已注册时幂等(skip)" {
        $raw = @"
- insert:
    - id: zen-proxy
      name: './plugins/dsh-zen-proxy/index.js'
      config:
        port: 4097
"@
        $r = Add-ZenProxyPatchEntry -Text $raw -Port 4097
        $r.Changed | Should -Be $false
    }

    It "移除注册条目后不再含 zen-proxy" {
        $raw = @"
- insert:
    - id: zen-proxy
      name: './plugins/dsh-zen-proxy/index.js'
      config:
        port: 4097
      foo: bar
"@
        $r = Remove-ZenProxyPatchEntry -Text $raw
        $r.Changed | Should -Be $true
        ($r.Text -match "zen-proxy") | Should -Be $false
    }

    It "移除多条目中的 zen-proxy,保留其他插件的 - insert 块" {
        $raw = @"
# dsh-zen-desktop: 为 opencode.ai/zen 上游注入官方 opencode 客户端头,解除 429 限流
- insert:
    - id: zen-proxy
      name: './plugins/dsh-zen-proxy/index.js'
      config:
        host: 127.0.0.1
        port: 4097
        upstreamHost: opencode.ai
        upstreamBasePath: /zen/v1
- insert:
    - id: other-plugin
      name: './plugins/other/index.js'
"@
        $r = Remove-ZenProxyPatchEntry -Text $raw
        $r.Changed | Should -Be $true
        ($r.Text -match "zen-proxy") | Should -Be $false
        ($r.Text -match "other-plugin") | Should -Be $true
        ($r.Text -match "^- insert:") | Should -Be $true
    }
}

Describe "credentials 增改删" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "新增 key" {
        $r = Set-CredentialValue -Text "" -EnvName "OPENCODE_API_KEY" -Value "sk-test"
        $r.Action | Should -Be "added"
        ($r.Text -match "(?m)^OPENCODE_API_KEY:\s*sk-test\s*$") | Should -Be $true
    }

    It "更新已有 key" {
        $r = Set-CredentialValue -Text "OPENCODE_API_KEY: sk-old" -EnvName "OPENCODE_API_KEY" -Value "sk-new"
        $r.Action | Should -Be "updated"
        ($r.Text -match "sk-new") | Should -Be $true
        ($r.Text -match "sk-old") | Should -Be $false
    }

    It "删除 key" {
        $r = Remove-CredentialValue -Text "OPENCODE_API_KEY: sk-x`r`nOTHER: 1" -EnvName "OPENCODE_API_KEY"
        $r.Changed | Should -Be $true
        ($r.Text -match "OPENCODE_API_KEY") | Should -Be $false
        ($r.Text -match "OTHER") | Should -Be $true
    }
}

Describe "convert + bom" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "ConvertTo-ProviderBlock 生成完整块" {
        $b = ConvertTo-ProviderBlock -ProviderName "opencode" -ApiKeyEnv "OPENCODE_API_KEY" -BaseUrl "http://127.0.0.1:4097/v1" -Models @("deepseek-v4-flash-free")
        # 行以 CRLF 结尾,用 \r?$ 匹配(行尾\r\n时 $ 只落在 \n 前)
        ($b -match "(?m)^opencode:\r?$") | Should -Be $true
        ($b -match "(?m)^    apiKeyEnv: OPENCODE_API_KEY\r?$") | Should -Be $true
        ($b -match "(?m)^    models:\r?$") | Should -Be $true
        ($b -match "(?m)^        - deepseek-v4-flash-free\r?$") | Should -Be $true
    }

    It "Test-StringHasBom 识别 BOM / 无 BOM" {
        $withBom = [byte[]]@(0xEF, 0xBB, 0xBF, 0x68, 0x69)
        $withoutBom = [byte[]]@(0x68, 0x69)
        Test-StringHasBom -Bytes $withBom | Should -Be $true
        Test-StringHasBom -Bytes $withoutBom | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 以下三组是回归护栏,对应一次真实的线上故障:
#   CI 在 windows-latest 上 checkout 出 CRLF(Windows 版 Git 默认 autocrlf=true),
#   而模块里的正则写的是 [^\r\n]*$。.NET 的 $ 只匹配 \n 之前,CRLF 里的 \r 挡在中间,
#   于是 baseURL / providers 全部失配 —— 7 个用例在 CI 红,本地却全绿。
# 现在:正则去掉 $,并且插入行时沿用原文的换行风格。
# ---------------------------------------------------------------------------

Describe "CRLF 输入(Windows 检出 / harness 写出的 yaml)" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    # 刻意用 LF 再手工转 CRLF:测试结果不应依赖本仓库的检出换行
    It "更新 baseURL 不因 CRLF 失配(<Case>)" -TestCases @(
        @{ Case = "2 空格缩进"; Lf = "llm-pi-ai:`n  providers:`n    opencode:`n      apiKeyEnv: OPENCODE_API_KEY`n      baseURL: https://opencode.ai/zen/v1`n      models:`n        - deepseek-v4-flash-free`n" }
        @{ Case = "4 空格缩进"; Lf = "llm-pi-ai:`n    providers:`n        opencode:`n            apiKeyEnv: OPENCODE_API_KEY`n            baseURL: https://opencode.ai/zen/v1`n" }
    ) {
        param($Case, $Lf)
        $crlf = $Lf.Replace("`n", "`r`n")
        $r = Set-ProviderBaseUrl -Text $crlf -Port 4097
        $r.Action | Should -Be "updated"
        ($r.Text -match "http://127\.0\.0\.1:4097/v1") | Should -Be $true
        ($r.Text -match "opencode\.ai/zen/v1") | Should -Be $false
        # 换行风格必须保持 CRLF,不能混进裸 LF
        ($r.Text -match "(?<!\r)\n") | Should -Be $false
    }

    It "新增 provider 时 providers 行也能被 CRLF 定位到(added)" {
        $lf = "llm-pi-ai:`n  providers:`n    anthropic:`n      baseURL: https://api.anthropic.com`n"
        $crlf = $lf.Replace("`n", "`r`n")
        $r = Set-ProviderBaseUrl -Text $crlf -Port 4097
        $r.Action | Should -Be "added"
        ($r.Text -match "(?m)^\s*opencode:\s*$") | Should -Be $true
        ($r.Text -match "anthropic") | Should -Be $true
        ($r.Text -match "(?<!\r)\n") | Should -Be $false
    }

    It "Restore-OfficialBaseUrl 在 CRLF 文本上生效" {
        $lf = "llm-pi-ai:`n  providers:`n    opencode:`n      baseURL: http://127.0.0.1:4097/v1`n"
        $crlf = $lf.Replace("`n", "`r`n")
        $r = Restore-OfficialBaseUrl -Text $crlf
        ($r -match "https://opencode.ai/zen/v1") | Should -Be $true
        ($r -match "127\.0\.0\.1") | Should -Be $false
        ($r -match "(?<!\r)\n") | Should -Be $false
    }

    It "cordis.patch.yml 追加条目沿用 CRLF" {
        $r = Add-ZenProxyPatchEntry -Text "- insert:`r`n    - id: other-plugin`r`n" -Port 4097
        $r.Changed | Should -Be $true
        ($r.Text -match "zen-proxy") | Should -Be $true
        ($r.Text -match "(?<!\r)\n") | Should -Be $false
    }

    It "cordis.patch.yml 追加条目沿用 LF" {
        $r = Add-ZenProxyPatchEntry -Text "- insert:`n    - id: other-plugin`n" -Port 4097
        $r.Changed | Should -Be $true
        ($r.Text -match "`r") | Should -Be $false
    }
}

Describe "credentials 边界" {
    BeforeAll { Import-Module (Resolve-Path (Join-Path $PSScriptRoot "..\lib\dsh-zen-desktop.psm1")).Path -Force }

    It "空文件首行不应是空行" {
        $r = Set-CredentialValue -Text "" -EnvName "OPENCODE_API_KEY" -Value "sk-test"
        $r.Text | Should -Be "OPENCODE_API_KEY: sk-test"
    }

    It "CRLF 文件的追加沿用 CRLF" {
        $r = Set-CredentialValue -Text "OTHER: 1`r`n" -EnvName "OPENCODE_API_KEY" -Value "sk-test"
        $r.Text.Contains("`r`nOPENCODE_API_KEY: sk-test") | Should -Be $true
        ($r.Text -match "(?<!\r)\n") | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Windows PowerShell 5.1 会把"无 BOM 的 UTF-8"当成系统 ANSI 代码页(简中环境是 GBK)读,
# 中文注释变乱码,甚至把 here-string 的引号吞掉导致整个文件解析失败。
# 5.1 是模块 #requires 声明的最低版本,所以每个脚本都必须是带 BOM 的 UTF-8。
# ---------------------------------------------------------------------------
Describe "源文件编码(Windows PowerShell 5.1 兼容)" {
    It "<Name> 必须是带 BOM 的 UTF-8" -TestCases @(
        @{ Name = "lib\dsh-zen-desktop.psm1" }
        @{ Name = "tests\dsh-zen-desktop.Tests.ps1" }
        @{ Name = "tests\smoke.ps1" }
        @{ Name = "install.ps1" }
        @{ Name = "repair.ps1" }
        @{ Name = "uninstall.ps1" }
        @{ Name = "add-key.ps1" }
    ) {
        param($Name)
        $root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $file = Join-Path $root $Name
        (Test-Path $file) | Should -Be $true
        $bytes = [System.IO.File]::ReadAllBytes($file)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $true
    }
}