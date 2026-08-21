$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\dsh-zen-desktop.psm1') -Force
$raw = @'
llm-pi-ai:
  providers:
    opencode:
      apiKeyEnv: OPENCODE_API_KEY
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
        - deepseek-r1-flash-free
'@
$r = Set-ProviderBaseUrl -Text $raw -Port 4097
Write-Host 'action:' $r.Action
$r.Text
Write-Host '---- re-run (should skip) ----'
$r2 = Set-ProviderBaseUrl -Text $r.Text -Port 4097
Write-Host 're-run action:' $r2.Action

Write-Host '==== neighbour provider case ===='
$raw2 = @'
llm-pi-ai:
  providers:
    opencode:
      baseURL: https://opencode.ai/zen/v1
      models:
        - deepseek-v4-flash-free
    anthropic:
      baseURL: https://api.anthropic.com
'@
$r3 = Set-ProviderBaseUrl -Text $raw2 -Port 4097
$r3.Text
Write-Host '---- anthropic preserved? ----'
if ($r3.Text -match 'anthropic') { 'OK anthropic kept' } else { 'FAIL anthropic lost' }
Write-Host '---- changed only opencode block? ----'
$f = Find-YamlBlock -Text $r3.Text -Key 'opencode'
$f.Block