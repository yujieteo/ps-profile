$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = $PSScriptRoot
$ProfileFile = Join-Path $Root 'Microsoft.PowerShell_profile.ps1'
$ToolFiles = @((Join-Path $Root 'check.ps1'), (Join-Path $Root 'tests.ps1'))
$BaseRef = 'origin/main'
$AnalyzerVersion = '1.24.0'
$CompatibilityProfile = 'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
$PublicCommands = @(
    'fd', 'recent', 'rg', 'rgi', 'fzf', 'br', 'bat', 'du', 'tldr', 'z', 'zi', 'cd', 'delta', 'ls', 'll',
    'cpath', 'unc', 'cb', 'wc', 'head', 'tail', 'which', 'touch', 'mkcd', 'up', '..', '...', 'ep', 'reload',
    'prompt', 'Update-Index'
)
$ExcludedRules = [ordered]@{
    PSAvoidGlobalVars          = 'The profile shares its state with its commands and with the index job through global variables.'
    PSAvoidUsingWriteHost      = 'The commands color console output for a person, and piped output goes to the pipeline.'
    PSUseConsistentIndentation = 'The rule mis-indents script blocks inside @() and the continuation lines of the tldr table.'
    PSReviewUnusedParameter    = 'The rule does not see parameters that nested script blocks use (rg and du).'
    PSUseSingularNouns         = 'The tests and the replay call these helper names, so a rename shows as a replay failure.'
}
$RuleSettings = @{
    PSPlaceCloseBrace          = @{ Enable = $true; NewLineAfter = $false }
    PSUseConsistentWhitespace  = @{ Enable = $true; CheckOperator = $false }
    PSPlaceOpenBrace           = @{ Enable = $true }
    PSAlignAssignmentStatement = @{ Enable = $true }
    PSUseCorrectCasing         = @{ Enable = $true }
}
$CompatibilityRules = @{
    PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
    PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($CompatibilityProfile) }
    PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($CompatibilityProfile) }
}

$failures = @()
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'ps-profile-check'
$env:TZ = 'UTC'

function Add-Failure([string]$Message) { $script:failures += $Message }

function Get-Syntax([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = $errors }
}

function Test-Parse([string]$Path) {
    $syntax = Get-Syntax $Path
    foreach ($e in $syntax.Errors) { Add-Failure ('parse: {0}:{1} {2}' -f $Path, $e.Extent.StartLineNumber, $e.Message) }
    foreach ($t in $syntax.Tokens) {
        if ($t.Kind -ne 'Comment') { continue }
        if ($t.Text -match 'https?://' -or $t.Text -match '^#requires\b') { continue }
        Add-Failure ('comment: {0}:{1} {2}' -f $Path, $t.Extent.StartLineNumber, $t.Text)
    }
}

function Import-Analyzer {
    $modules = Join-Path $tmp 'modules'
    if (-not (Test-Path -LiteralPath (Join-Path $modules 'PSScriptAnalyzer'))) {
        Save-Module -Name PSScriptAnalyzer -Path $modules -RequiredVersion $AnalyzerVersion -Force
    }
    Import-Module (Join-Path $modules 'PSScriptAnalyzer') -Force
}

function Test-Analyzer([string[]]$Paths, [hashtable]$Rules) {
    $included = @(Get-ScriptAnalyzerRule | ForEach-Object { $_.RuleName } | Where-Object { $ExcludedRules.Keys -notcontains $_ })
    foreach ($path in $Paths) {
        foreach ($rule in $included) {
            $settings = @{ IncludeRules = [string[]]@($rule); Rules = $Rules }
            foreach ($d in @(Invoke-ScriptAnalyzer -Path $path -Settings $settings)) {
                Add-Failure ('analyzer: {0}:{1} {2} {3}' -f $path, $d.Line, $d.RuleName, $d.Message)
            }
        }
    }
}

function Test-DeadFunction {
    $ast = (Get-Syntax $ProfileFile).Ast
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name -replace '^global:', '' })
    $used = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    foreach ($name in $defined) {
        if ($PublicCommands -notcontains $name -and $used -notcontains $name) { Add-Failure "dead function: $name has no reference" }
    }
    foreach ($name in $PublicCommands) {
        if ($defined -notcontains $name) { Add-Failure "public command: $name is not defined" }
    }
}

function Test-Version {
    $text = Get-Content -LiteralPath $ProfileFile -Raw
    $profileVersion = [regex]::Match($text, "PSProfileVersion = '([^']+)'").Groups[1].Value
    $changelog = Get-Content -LiteralPath (Join-Path $Root 'CHANGELOG.md') | Where-Object { $_ -match '^## \[\d' } | Select-Object -First 1
    $changelogVersion = [regex]::Match($changelog, '^## \[([^\]]+)\]').Groups[1].Value
    if ($profileVersion -ne $changelogVersion) { Add-Failure "version: profile $profileVersion but changelog $changelogVersion" }
}

function Invoke-Tests([string]$ProfilePath, [string]$Name, [bool]$Strict, [bool]$AllowFail) {
    $out = Join-Path $tmp "$Name.txt"
    $work = Join-Path $tmp 'work'
    $arguments = @('-NoProfile', '-File', (Join-Path $Root 'tests.ps1'), '-ProfilePath', $ProfilePath, '-WorkDir', $work, '-OutFile', $out)
    if ($Strict) { $arguments += '-Strict' }
    $pwsh = (Get-Process -Id $PID).Path
    $log = & $pwsh @arguments 3>$null
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { Add-Failure ("tests ($Name): " + ($log -join ' ')) }
    $out
}

function Test-Replay {
    $base = Join-Path $tmp 'base.ps1'
    $baseText = & git -C $Root show "${BaseRef}:Microsoft.PowerShell_profile.ps1"
    if ($LASTEXITCODE -ne 0) { Add-Failure "replay: cannot read $BaseRef"; return }
    Set-Content -LiteralPath $base -Value $baseText -Encoding utf8NoBOM
    $baseOut = Invoke-Tests -ProfilePath $base -Name 'replay-base' -Strict $false -AllowFail $true
    $branchOut = Invoke-Tests -ProfilePath $ProfileFile -Name 'replay-branch' -Strict $false -AllowFail $false
    $baseLines = @(Get-Content -LiteralPath $baseOut)
    $newCases = @($baseLines | Where-Object { ($_ -split "`t")[1] -eq 'fail' } | ForEach-Object { ($_ -split "`t")[0] })
    $baseKept = @($baseLines | Where-Object { $newCases -notcontains ($_ -split "`t")[0] })
    $branchKept = @(Get-Content -LiteralPath $branchOut | Where-Object { $newCases -notcontains ($_ -split "`t")[0] })
    $diff = @(Compare-Object $baseKept $branchKept)
    foreach ($d in $diff) {
        $name = ($d.InputObject -split "`t")[0]
        Add-Failure ("replay: {0} output differs from {1} ({2})" -f $name, $BaseRef, $d.SideIndicator)
    }
}

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
foreach ($file in @($ProfileFile) + $ToolFiles) { Test-Parse $file }
Import-Analyzer
Test-Analyzer @($ProfileFile) ($RuleSettings + $CompatibilityRules)
Test-Analyzer $ToolFiles $RuleSettings
Test-DeadFunction
Test-Version
$null = Invoke-Tests -ProfilePath $ProfileFile -Name 'strict' -Strict $true -AllowFail $false
Test-Replay

if ($failures.Count) {
    $failures | ForEach-Object { Write-Output $_ }
    Write-Output "check failed: $($failures.Count) problems"
    exit 1
}
Write-Output 'check ok'
