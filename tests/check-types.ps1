param(
    [string]$ProfilePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Microsoft.PowerShell_profile.ps1')
)

# This check reads the profile with the PowerShell parser. The parser needs FullLanguage mode,
# so the check cannot run inside tests.ps1, which runs in ConstrainedLanguage mode.
# It lists each type, method or command in the profile that ConstrainedLanguage mode does not permit.
# Exit code 0: no problem. Exit code 1: one or more problems. Exit code 2: the check cannot run.

if ("$($ExecutionContext.SessionState.LanguageMode)" -ne 'FullLanguage') {
    Write-Output "The check needs FullLanguage mode, and this session is in $($ExecutionContext.SessionState.LanguageMode) mode. Run it on a computer without that policy, for example: pwsh -NoProfile -File tests/check-types.ps1, or powershell -NoProfile -File tests\check-types.ps1 where no policy sets ConstrainedLanguage mode"
    exit 2
}

if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    Write-Output "The check cannot run: '$ProfilePath' is not a file."
    exit 2
}

$allowedTypes = @(
    'adsi', 'adsisearcher', 'array', 'bigint', 'bool', 'byte', 'char', 'cimclass', 'cimconverter', 'ciminstance', 'cimsession', 'cimtype',
    'cultureinfo', 'datetime', 'decimal', 'double', 'float', 'guid', 'hashtable', 'int', 'int16', 'int32', 'int64', 'ipaddress', 'ipendpoint',
    'long', 'mailaddress', 'nullstring', 'object', 'objectsecurity', 'ordered', 'physicaladdress', 'pscredential', 'pscustomobject',
    'pslistmodifier', 'psobject', 'psprimitivedictionary', 'regex', 'sbyte', 'securestring', 'single', 'string', 'switch', 'timespan',
    'uint16', 'uint32', 'uint64', 'uri', 'version', 'void', 'wildcardpattern', 'wmi', 'wmiclass', 'wmisearcher', 'x500distinguishedname',
    'x509certificate', 'xml'
)
$allowedMethods = @(
    'Substring', 'ToLower', 'ToUpper', 'StartsWith', 'EndsWith', 'Trim', 'TrimEnd', 'TrimStart', 'Split', 'IndexOf', 'LastIndexOf',
    'PadRight', 'PadLeft', 'Contains', 'ToCharArray', 'Replace', 'Insert', 'ContainsKey', 'Remove', 'Clone', 'Add', 'AddDays', 'AddHours',
    'AddMinutes', 'AddSeconds', 'ToUniversalTime', 'ToLocalTime', 'ToString', 'Match', 'Matches', 'IsMatch', 'Equals', 'CompareTo'
)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ProfilePath, [ref]$tokens, [ref]$errors)
$problems = @(
    foreach ($e in $errors) { 'line {0}: parse error: {1}' -f $e.Extent.StartLineNumber, $e.Message }
    foreach ($n in $ast.FindAll({ param($x) $true }, $true)) {
        $kind = $n.GetType().Name
        if ($kind -eq 'TypeExpressionAst' -or $kind -eq 'TypeConstraintAst') {
            $name = ($n.TypeName.FullName -replace '\[\]$', '' -replace '^System\.', '').ToLower()
            if ($allowedTypes -notcontains $name) { 'line {0}: [{1}] is not an allowed type' -f $n.Extent.StartLineNumber, $n.TypeName.FullName }
        } elseif ($kind -eq 'InvokeMemberExpressionAst' -and -not $n.Static) {
            $member = "$($n.Member.Extent.Text)"
            if ($allowedMethods -notcontains $member) { 'line {0}: .{1}() is not a string, hashtable, date or regex method' -f $n.Extent.StartLineNumber, $member }
        } elseif ($kind -eq 'CommandAst') {
            $command = "$($n.GetCommandName())"
            if ($command -match '^(Add-Type|Invoke-Expression|iex)$') { 'line {0}: {1} is not permitted' -f $n.Extent.StartLineNumber, $command }
            if ($command -eq 'New-Object' -and ($n.Extent.Text -match '-ComObject' -or $n.Extent.Text -notmatch '^New-Object\s+(PSObject|DateTime)\b')) {
                'line {0}: New-Object makes a type that is not PSObject or DateTime' -f $n.Extent.StartLineNumber
            }
        }
    }
)

foreach ($p in $problems) { Write-Output $p }
Write-Output ('{0} problem(s) in {1}' -f $problems.Count, $ProfilePath)
if ($problems.Count) { exit 1 }
