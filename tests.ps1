param(
    [string]$ProfilePath = (Join-Path $PSScriptRoot 'Microsoft.PowerShell_profile.ps1'),
    [string]$WorkDir = '',
    [string]$Only = '',
    [switch]$Keep
)

if (Test-Path -LiteralPath Variable:global:PSProfileVersion) {
    Write-Output 'The profile is loaded in this session. Run the tests in a new process: powershell -NoProfile -File tests.ps1'
    exit 2
}

$GateProblems = $null
if ("$($ExecutionContext.SessionState.LanguageMode)" -eq 'FullLanguage') {
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
    $gateTokens = $null
    $gateErrors = $null
    $gateAst = [System.Management.Automation.Language.Parser]::ParseFile($ProfilePath, [ref]$gateTokens, [ref]$gateErrors)
    $GateProblems = @(
        foreach ($e in $gateErrors) { 'line {0}: parse error: {1}' -f $e.Extent.StartLineNumber, $e.Message }
        foreach ($n in $gateAst.FindAll({ param($x) $true }, $true)) {
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
    $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
}

$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if ($PSVersionTable.PSVersion.Major -lt 6) { $ByteArgs = @{ Encoding = 'Byte' } } else { $ByteArgs = @{ AsByteStream = $true } }
$E9 = [string][char]0xE9
$Results = @()

if (-not $WorkDir) {
    $base = $env:TEMP
    if (-not $base) { $base = $env:TMPDIR }
    if (-not $base) { $base = '/tmp' }
    $WorkDir = Join-Path $base 'ps-profile-tests'
}
$marker = Join-Path $WorkDir '.ps-profile-tests'
if (Test-Path -LiteralPath $WorkDir) {
    if (-not (Test-Path -LiteralPath $marker) -and @(Get-ChildItem -LiteralPath $WorkDir -Force).Count) {
        Write-Output "'$WorkDir' exists and is not a folder that these tests made. Give an empty folder with -WorkDir."
        exit 2
    }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath.TrimEnd('\', '/')
Set-Content -LiteralPath (Join-Path $WorkDir '.ps-profile-tests') -Value 'made by tests.ps1' -Encoding Ascii

function Get-Tool([string]$Name) {
    $c = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source } else { '' }
}

function Invoke-Tool([string]$Exe, [string]$Dir, [string[]]$Arguments, [string[]]$InputLines) {
    Push-Location -LiteralPath $Dir
    try {
        if ($InputLines) { @($InputLines | & $Exe @Arguments 2>$null) } else { @(& $Exe @Arguments 2>$null) }
    } finally { Pop-Location }
}

function ConvertTo-Hex([string]$Text) {
    (@(foreach ($ch in $Text.ToCharArray()) { '{0:x2}' -f [int]$ch }) -join '')
}

function Get-Hex([string]$Path) {
    (@(Get-Content -LiteralPath $Path @ByteArgs | ForEach-Object { '{0:x2}' -f $_ }) -join '')
}

function Add-File([string]$Root, [string]$Rel, [string]$Hex) {
    $parts = $Rel.Split('/')
    $path = $Root
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $path = Join-Path $path $parts[$i]
    }
    $clean = $Hex -replace '\s', ''
    if (-not $clean) { Set-Content -LiteralPath $path -Value '' -NoNewline -Encoding Ascii; return }
    $bytes = @(for ($i = 0; $i -lt $clean.Length; $i += 2) { [byte]('0x' + $clean.Substring($i, 2)) })
    Set-Content -LiteralPath $path -Value $bytes @ByteArgs -WarningAction SilentlyContinue
}

function Join-Rel([string]$Root, [string]$Rel) {
    $path = $Root
    foreach ($part in $Rel.Split('/')) { $path = Join-Path $path $part }
    $path
}

function ConvertTo-Rel([string]$Root, [string]$Path) {
    $Path.Substring($Root.Length + 1) -replace '\\', '/'
}

function Get-State([string]$Dir, [switch]$Time) {
    @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | ForEach-Object {
        $rel = ConvertTo-Rel $Dir $_.FullName
        if ($rel -notmatch '(^|/)\.git/') {
            $line = $rel + ' ' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            if ($Time) { $line += ' ' + $_.LastWriteTimeUtc.Ticks }
            $line
        }
    })
}

function Invoke-Captured($Body) {
    $r = @{ Out = @(); Err = @(); Warn = @(); Info = @(); Threw = '' }
    try {
        foreach ($o in @(& $Body 2>&1 3>&1 6>&1)) {
            if ($null -eq $o) { continue }
            $p = $o.PSObject.Properties
            if ($p['FullyQualifiedErrorId'] -and $p['Exception']) { $r.Err += "$o" }
            elseif ($p['FullyQualifiedWarningId']) { $r.Warn += "$o" }
            elseif ($p['MessageData']) { $r.Info += "$o" }
            else { $r.Out += $o }
        }
    } catch { $r.Threw = $_.Exception.Message }
    $r
}

function Assert-True($Condition, [string]$What) {
    if (-not $Condition) { throw $What }
}

function Assert-Equal($Actual, $Expected, [string]$What) {
    if ("$Actual" -cne "$Expected") { throw ('{0}: expected [{1}] but got [{2}]' -f $What, $Expected, $Actual) }
}

function Assert-Same($Actual, $Expected, [string]$What) {
    $a = @(@($Actual) | Where-Object { $null -ne $_ } | Sort-Object -CaseSensitive)
    $e = @(@($Expected) | Where-Object { $null -ne $_ } | Sort-Object -CaseSensitive)
    if (($a -join "`n") -ceq ($e -join "`n")) { return }
    $missing = @($e | Where-Object { $a -cnotcontains $_ })
    $extra = @($a | Where-Object { $e -cnotcontains $_ })
    throw ('{0}: missing [{1}] not expected [{2}]' -f $What, ($missing -join '; '), ($extra -join '; '))
}

function Assert-Quiet([hashtable]$Run, [string]$What) {
    if ($Run.Threw) { throw "$What threw: $($Run.Threw)" }
    if ($Run.Err.Count) { throw "$What gave $($Run.Err.Count) error(s): $($Run.Err[0])" }
}

function Test-Case([string]$Name, $Body) {
    if ($Only -and $Name -notmatch $Only) { return }
    $status = 'PASS'
    $detail = ''
    try { & $Body | Out-Null } catch {
        $detail = $_.Exception.Message
        if ($detail -like 'SKIP:*') { $status = 'SKIP'; $detail = $detail.Substring(5).Trim() } else { $status = 'FAIL' }
    }
    $script:Results += New-Object PSObject -Property @{ Status = $status; Name = $Name; Detail = $detail }
    Write-Output ('{0} {1}' -f $status, $Name)
    if ($detail) { Write-Output ('     ' + ($detail -replace '\r?\n', ' ')) }
}

$Git = Get-Tool 'git'
$RealRg = Get-Tool 'rg'
$RealFd = Get-Tool 'fd'
$RealSd = Get-Tool 'sd'

$saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; TEMP = $env:TEMP; RIPGREP_CONFIG_PATH = $env:RIPGREP_CONFIG_PATH }
$env:LOCALAPPDATA = Join-Path $WorkDir 'data'
$env:TEMP = Join-Path $WorkDir 'tmp'
$RgConfig = Join-Path $WorkDir 'rg-config'
Set-Content -LiteralPath $RgConfig -Value '' -Encoding Ascii
$env:RIPGREP_CONFIG_PATH = $RgConfig
New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:TEMP -Force | Out-Null
$UndoDir = Join-Path (Join-Path $env:LOCALAPPDATA 'ps-profile') 'sd-undo'
$EmptyIgnore = Join-Path $WorkDir 'empty-ignore'
Set-Content -LiteralPath $EmptyIgnore -Value '' -NoNewline -Encoding Ascii

try {
    $errorsBefore = $Error.Count
    . $ProfilePath
    $loadErrors = @()
    if ($Error.Count -gt $errorsBefore) {
        $loadErrors = @($Error[0..($Error.Count - $errorsBefore - 1)] | Where-Object { "$_" -notmatch 'Alias:' } | ForEach-Object { "$_" })
    }

    $tools = @(foreach ($t in @(@('git', $Git), @('rg', $RealRg), @('fd', $RealFd), @('sd', $RealSd))) {
        if ($t[1]) { $t[0] } else { 'no ' + $t[0] }
    }) -join ', '
    Write-Output ('ps-profile {0}, PowerShell {1}, {2}, real tools: {3}' -f $global:PSProfileVersion, $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode, $tools)

    Test-Case 'the tests run in ConstrainedLanguage mode' {
        Assert-Equal $ExecutionContext.SessionState.LanguageMode 'ConstrainedLanguage' 'language mode'
    }

    Test-Case 'the profile loads without an error' {
        Assert-Equal ($loadErrors -join ' | ') '' 'errors at load'
    }

    Test-Case 'the profile uses only the types and methods that ConstrainedLanguage mode permits' {
        if ($null -eq $GateProblems) { throw 'SKIP: the check reads the profile with the PowerShell parser, which needs FullLanguage mode at the start' }
        Assert-Equal ($GateProblems -join ' | ') '' 'problems'
    }

    $IgnoreCases = @(
        @{ Dir = 'c01-basic'; About = 'a name pattern matches at every level'; Lines = @('*.log')
            Files = @('YYYY a.txt', '.... a.log', '.... sub/b.log', 'YYYY sub/b.txt') }
        @{ Dir = 'c02-anchored'; About = 'a slash at the start or in the middle anchors the pattern'; Lines = @('/root.txt', 'dir/file.txt')
            Files = @('.... root.txt', 'YYYY sub/root.txt', '.... dir/file.txt', 'YYYY sub/dir/file.txt') }
        @{ Dir = 'c03-dironly'; About = 'a slash at the end matches folders only'; Lines = @('build/')
            Files = @('.... build/x.txt', 'YYYY sub/build', '.... sub2/build/y.txt', 'YYYY keep.txt') }
        @{ Dir = 'c04-negate'; About = 'an exclamation mark includes a file again'; Lines = @('*.tmp', '!keep.tmp')
            Files = @('.... a.tmp', 'YYYY keep.tmp', 'YYYY sub/keep.tmp', '.... sub/b.tmp') }
        @{ Dir = 'c05-negate-parent'; About = 'a file under an excluded folder cannot come back'; Lines = @('out/', '!out/keep.txt')
            Files = @('.... out/keep.txt', '.... out/x.txt', 'YYYY in.txt') }
        @{ Dir = 'c06-doublestar'; About = 'two asterisks cross folders only next to a slash'; Lines = @('**/gen', 'docs/**', 'a/**/z.txt', 'x**y.txt')
            Files = @('.... gen/1.txt', '.... sub/gen/2.txt', '.... docs/a.md', '.... docs/d/b.md', '.... a/z.txt', '.... a/b/z.txt', '.... a/b/c/z.txt',
                'YYYY a/b/c/y.txt', '.... xy.txt', '.... x1y.txt', 'YYYY x/1/y.txt', 'YYYY keep.txt') }
        @{ Dir = 'c07-escape'; About = 'a backslash makes the next character literal'; Lines = @('\#hash.txt', '\!bang.txt', 'lit\[x].txt', 'a\ b.txt', 'star\*.txt')
            Files = @('.... #hash.txt', '.... !bang.txt', '.... lit[x].txt', 'YYYY litx.txt', '.... a b.txt', 'YYYY starX.txt', 'YYYY keep.txt') }
        @{ Dir = 'c08-class'; About = 'a character class with a range, ! or ^'; Lines = @('f[0-9].txt', 'g[!0-9].txt', 'h[^0-9].txt', 'i[[:digit:]].txt')
            Files = @('.... f1.txt', 'YYYY fa.txt', 'YYYY g1.txt', '.... ga.txt', 'YYYY h1.txt', '.... ha.txt', '.YYY i1.txt', 'YYYY ia.txt') }
        @{ Dir = 'c09-case'; About = 'names match without regard to case, as Git does on Windows'; Lines = @('Upper.TXT', 'DirCase/')
            Files = @('.YY. upper.txt', '.YY. dircase/x.txt', 'YYYY keep.txt') }
        @{ Dir = 'c10-nested'; About = 'a .gitignore in a subfolder overrides the one above'; Lines = @('*.gen')
            Extra = @{ 'sub/.gitignore' = "!keep.gen`nlocal.txt`n" }
            Files = @('.... a.gen', '.... sub/a.gen', 'YYYY sub/keep.gen', '.... sub/local.txt', 'YYYY local.txt', '.... sub/deep/local.txt', 'YYYY sub/deep/keep.gen') }
        @{ Dir = 'c11-format'; About = 'a byte order mark, CRLF, comments, blank lines and trailing spaces'; Bom = $true
            Raw = "bom.txt`r`n# comment`r`n`r`ncrlf.txt`r`nts.txt   `r`ntab.txt`t`r`n  lead.txt`r`n"
            Files = @('.... bom.txt', '.... crlf.txt', '.... ts.txt', 'Y... tab.txt', 'YYYY lead.txt', '....   lead.txt', 'YYYY # comment', 'YYYY keep.txt') }
        @{ Dir = 'c12-exclude'; About = '.git/info/exclude applies, and .gitignore overrides it'; Lines = @('!prec.txt')
            Files = @('.... excluded.txt', 'YYYY prec.txt', 'YYYY keep.txt') }
        @{ Dir = 'c13-middle'; About = 'doc/frotz/ is anchored and frotz2/ is not'; Lines = @('doc/frotz/', 'frotz2/')
            Files = @('.... doc/frotz/a.txt', 'YYYY a/doc/frotz/b.txt', '.... frotz2/c.txt', '.... a/frotz2/d.txt', 'YYYY keep.txt') }
        @{ Dir = 'c15-hidden'; About = 'dot files and dot folders are hidden'; Lines = @()
            Files = @('Y... .hidden.txt', 'Y... .hdir/x.txt', 'YYYY visible.txt') }
        @{ Dir = 'c16-nested-repo'; About = 'the rules of the outer repository stop at a nested repository, as in rg and fd'; Lines = @('*.o')
            Files = @('.... a.o', 'YYYY a.txt', '-YYY inner/a.o', '-YYY inner/b.txt') }
        @{ Dir = 'c18-ignorefiles'; About = '.ignore, .rgignore and .fdignore are not read'; Lines = @()
            Extra = @{ '.ignore' = "ig.txt`n"; '.rgignore' = "rgig.txt`n"; '.fdignore' = "fdig.txt`n" }
            Files = @('Y..Y ig.txt', 'Y.YY rgig.txt', 'YY.Y fdig.txt', 'YYYY keep.txt') }
        @{ Dir = 'c19-except'; About = 'exclude everything except one folder'; Lines = @('/*', '!/foo', '/foo/*', '!/foo/bar')
            Files = @('.... top.txt', '.... foo/x.txt', 'YYYY foo/bar/keep.txt', '.... other/y.txt') }
        @{ Dir = 'c20-nonl'; About = 'the last line has no line ending'; Raw = "one.txt`ntwo.txt"
            Files = @('.... one.txt', '.... two.txt', 'YYYY keep.txt') }
        @{ Dir = 'c22-unicode'; About = 'a name with a letter that is not ASCII'; Hex = 'c3a92e7478740a'
            Files = @('---. {e9}.txt', 'YYYY e.txt') }
        @{ Dir = 'c23-space'; About = 'names with spaces'; Lines = @('my file.txt', 'dir with space/')
            Files = @('.... my file.txt', '.... dir with space/x.txt', 'YYYY keep.txt') }
        @{ Dir = 'c24-star-dir'; About = 'an asterisk does not cross a slash'; Lines = @('logs/*.txt', '*/cache')
            Files = @('.... logs/a.txt', 'YYYY logs/sub/b.txt', 'YYYY sub/logs/c.txt', '.... x/cache/d.txt', 'YYYY x/y/cache/e.txt', 'YYYY keep.txt') }
        @{ Dir = 'c25-dot-star'; About = 'a dot file stays hidden when a rule includes it again'; Lines = @('.*', '!.keepme')
            Files = @('.... .env', 'YYY. .keepme', 'YYYY keep.txt') }
        @{ Dir = 'e1-revrange'; About = 'a class with a reversed range matches nothing'; Lines = @('[z-a].txt', 'ok.log')
            Files = @('YYYY a.txt', '.... ok.log', 'YYYY keep.md') }
        @{ Dir = 'e2-unclosed'; About = 'a bracket that does not close is a literal bracket, as in rg and fd'; Lines = @('[abc', 'ok.log')
            Files = @('Y... [abc', 'YYYY a', '.... ok.log', 'YYYY keep.md') }
        @{ Dir = 'e3-trailbs'; About = 'a backslash at the end of a pattern matches nothing'; Lines = @('foo\', 'ok.log')
            Files = @('YYYY foo', '.... ok.log', 'YYYY keep.md') }
        @{ Dir = 'e4-rbracket'; About = 'a class can start with a closing bracket'; Lines = @('[]x].txt', 'ok.log')
            Files = @('.... ].txt', '.... x.txt', 'YYYY y.txt', '.... ok.log') }
        @{ Dir = 'e5-regexmeta'; About = 'regex characters in a pattern are literal'; Lines = @('a+b(1).txt', 'c{2}.txt', 'd$.txt', 'e^f.txt')
            Files = @('.... a+b(1).txt', 'YYYY aab(1).txt', '.YY. c{2}.txt', 'YYYY cc.txt', '.... d$.txt', '.... e^f.txt', 'YYYY keep.md') }
        @{ Dir = 'e6-qmark'; About = 'a question mark matches one character'; Lines = @('f?.txt')
            Files = @('.... f1.txt', 'YYYY f12.txt', 'YYYY f.txt') }
        @{ Dir = 'e7-slashonly'; About = 'a pattern of one slash matches nothing'; Lines = @('/', 'ok.log')
            Files = @('YYYY a.txt', '.... ok.log') }
        @{ Dir = 'e8-dotdir'; About = 'a pattern with ./ or ../ matches nothing'; Lines = @('./rel.txt', 'sub/../up.txt')
            Files = @('YYYY rel.txt', 'YYYY up.txt', 'YYYY sub/x.txt') }
    )

    $Ign = Join-Path $WorkDir 'ign'
    $IgnRows = @()
    foreach ($c in $IgnoreCases) {
        $text = ''
        if ($c.ContainsKey('Hex')) { $hex = $c.Hex }
        else {
            if ($c.ContainsKey('Raw')) { $text = $c.Raw } elseif ($c.Lines.Count) { $text = ($c.Lines -join "`n") + "`n" }
            $hex = ConvertTo-Hex $text
            if ($c.ContainsKey('Bom')) { $hex = 'efbbbf' + $hex }
        }
        if ($hex) { Add-File $Ign ($c.Dir + '/.gitignore') $hex }
        if ($c.ContainsKey('Extra')) { foreach ($k in $c.Extra.Keys) { Add-File $Ign ($c.Dir + '/' + $k) (ConvertTo-Hex $c.Extra[$k]) } }
        foreach ($f in $c.Files) {
            $pair = $f -split ' ', 2
            $rel = $c.Dir + '/' + ($pair[1] -replace '\{e9\}', $E9)
            Add-File $Ign $rel (ConvertTo-Hex "x`n")
            $IgnRows += New-Object PSObject -Property @{ Dir = $c.Dir; Code = $pair[0]; Rel = $rel }
        }
    }
    foreach ($repo in @($Ign, (Join-Rel $Ign 'c16-nested-repo/inner'))) {
        if ($Git) { & $Git init -q $repo 2>$null | Out-Null }
        $info = Join-Path (Join-Path $repo '.git') 'info'
        if (-not (Test-Path -LiteralPath $info)) { New-Item -ItemType Directory -Path $info -Force | Out-Null }
    }
    Add-Content -LiteralPath (Join-Path (Join-Path (Join-Path $Ign '.git') 'info') 'exclude') -Value "excluded.txt`nprec.txt" -Encoding Ascii

    foreach ($c in $IgnoreCases) {
        Test-Case ('ignore rules: {0} ({1})' -f $c.About, $c.Dir) {
            $want = @($IgnRows | Where-Object { $_.Dir -eq $c.Dir -and $_.Code.Substring(3, 1) -eq 'Y' } | ForEach-Object { $_.Rel })
            $run = Invoke-Captured { fd . (Join-Path $Ign $c.Dir) -t f }
            Assert-Quiet $run 'fd'
            Assert-Same @($run.Out | ForEach-Object { ConvertTo-Rel $Ign "$_" }) $want 'files that fd lists'
        }
    }

    function Test-ToolColumn([int]$Column, [string[]]$Listed, [string]$Tool) {
        $bad = @(foreach ($row in $IgnRows) {
            $code = $row.Code.Substring($Column, 1)
            if ($code -eq '-') { continue }
            $now = '.'
            if ($Listed -ccontains $row.Rel) { $now = 'Y' }
            if ($now -ne $code) { '{0}: the table has {1} and {2} gives {3}' -f $row.Rel, $code, $Tool, $now }
        })
        Assert-Equal ($bad -join ' | ') '' 'rows that differ'
    }

    Test-Case 'git check-ignore agrees with the git column of the ignore table' {
        if (-not $Git) { throw 'SKIP: git is not on this computer' }
        $paths = @($IgnRows | Where-Object { $_.Code.Substring(0, 1) -ne '-' } | ForEach-Object { $_.Rel })
        $ignored = Invoke-Tool $Git $Ign @('-c', "core.excludesFile=$EmptyIgnore", '-c', 'core.ignorecase=true', '-c', 'core.quotePath=false', 'check-ignore', '--stdin') $paths
        Test-ToolColumn 0 @($paths | Where-Object { $ignored -cnotcontains $_ }) 'git'
    }

    Test-Case 'rg --files agrees with the rg column of the ignore table' {
        if (-not $RealRg) { throw 'SKIP: rg is not on this computer' }
        $listed = Invoke-Tool $RealRg $Ign @('--files', '--no-ignore-global', '--path-separator', '/', '.')
        Test-ToolColumn 1 @($listed | ForEach-Object { $_ -replace '^\./', '' }) 'rg'
    }

    Test-Case 'fd agrees with the fd column of the ignore table' {
        if (-not $RealFd) { throw 'SKIP: fd is not on this computer' }
        $listed = Invoke-Tool $RealFd $Ign @('--no-global-ignore-file', '--path-separator', '/', '-t', 'f')
        Test-ToolColumn 2 @($listed | ForEach-Object { $_ -replace '^\./', '' }) 'fd'
    }

    Test-Case 'an ignore rule that is not valid gives one warning and no error' {
        $run = Invoke-Captured { fd . (Join-Path $Ign 'e1-revrange') -t f }
        Assert-Quiet $run 'fd'
        Assert-Equal $run.Warn.Count 1 'warnings'
    }

    Test-Case 'fd -H lists hidden files but never the .git folder' {
        $run = Invoke-Captured { fd . (Join-Path $Ign 'c15-hidden') -H -t f }
        Assert-Quiet $run 'fd -H'
        Assert-Same @($run.Out | ForEach-Object { ConvertTo-Rel $Ign "$_" }) @('c15-hidden/.hidden.txt', 'c15-hidden/.hdir/x.txt', 'c15-hidden/visible.txt') 'files'
        $run = Invoke-Captured { fd . (Join-Path $Ign 'c16-nested-repo') -H }
        Assert-Quiet $run 'fd -H in a folder with a nested repository'
        Assert-Equal (@($run.Out | Where-Object { "$_" -match '[\\/]\.git([\\/]|$)' }).Count) 0 'items in .git'
    }

    Test-Case 'fd -I lists the files that .gitignore ignores' {
        $dir = Join-Path $Ign 'c01-basic'
        $run = Invoke-Captured { fd . $dir -I -t f }
        Assert-Quiet $run 'fd -I'
        Assert-Same @($run.Out | ForEach-Object { ConvertTo-Rel $dir "$_" }) @('a.txt', 'a.log', 'sub/b.log', 'sub/b.txt') 'files'
    }

    $TextFiles = @(
        , @('case.txt', (ConvertTo-Hex "alpha`nAlpha`nALPHA`n"))
        , @('crlf.txt', (ConvertTo-Hex "foo`r`nbar`r`n"))
        , @('words.txt', (ConvertTo-Hex "cat`ncatalog`nbob-cat`n"))
        , @('utf16le.txt', 'fffe 6800 e900 6c00 6c00 6f00 2000 7700 f600 7200 6c00 6400 0a00')
        , @('utf16be.txt', 'feff 0068 00e9 006c 006c 006f 0020 0077 00f6 0072 006c 0064 000a')
        , @('utf8bom.txt', 'efbbbf 68 c3a9 6c6c6f 20 626f6d 0a')
        , @('utf8.txt', '68 c3a9 6c6c6f 20 706c61696e 0a')
        , @('cp1252.txt', '636166 e9 20 6175 20 6c616974 0a')
        , @('bin.dat', '616263 00 646566 20 6d61746368 0a')
        , @('nofinal.txt', (ConvertTo-Hex "first`nlast needle"))
        , @('mixed.txt', (ConvertTo-Hex "one needle`r`ntwo`nthree needle`rfour needle"))
        , @('blank.txt', (ConvertTo-Hex "a`n`nb`n"))
        , @('empty.txt', '')
        , @('mail.txt', (ConvertTo-Hex "bob@example`n"))
        , @('sub/deep.md', (ConvertTo-Hex "alpha deep`n"))
        , @('sub/Deep.TXT', (ConvertTo-Hex "Alpha upper ext`n"))
        , @('.hid/secret.txt', (ConvertTo-Hex "alpha hidden`n"))
    )
    function New-TextTree([string]$Name) {
        $dir = Join-Path $WorkDir $Name
        foreach ($f in $TextFiles) { Add-File $dir $f[0] $f[1] }
        $dir
    }
    $Txt = New-TextTree 'txt'
    $accent = 'h' + $E9 + 'llo'

    $RgCases = @(
        @{ Name = 'lower-case text ignores case, as rg --smart-case'; Mine = @{ Pattern = 'alpha' }; Real = @('-S', 'alpha')
            Want = @('case.txt:1', 'case.txt:2', 'case.txt:3', 'sub/deep.md:1', 'sub/Deep.TXT:1') }
        @{ Name = 'an upper-case letter makes the search case-sensitive'; Mine = @{ Pattern = 'Alpha' }; Real = @('-S', 'Alpha')
            Want = @('case.txt:2', 'sub/Deep.TXT:1') }
        @{ Name = '-i ignores case'; Mine = @{ Pattern = 'ALPHA'; IgnoreCase = $true }; Real = @('-i', 'ALPHA')
            Want = @('case.txt:1', 'case.txt:2', 'case.txt:3', 'sub/deep.md:1', 'sub/Deep.TXT:1') }
        @{ Name = '-s is case-sensitive'; Mine = @{ Pattern = 'alpha'; CaseSensitive = $true }; Real = @('-s', 'alpha')
            Want = @('case.txt:1', 'sub/deep.md:1') }
        @{ Name = '-w matches whole words'; Mine = @{ Pattern = 'cat'; Word = $true }; Real = @('-w', 'cat')
            Want = @('words.txt:1', 'words.txt:3') }
        @{ Name = '-F matches plain text'; Mine = @{ Pattern = 'b@e'; SimpleMatch = $true }; Real = @('-F', 'b@e')
            Want = @('mail.txt:1') }
        @{ Name = 'UTF-8 and UTF-16 text with a byte order mark is read'; Mine = @{ Pattern = $accent }; Real = @($accent)
            Want = @('utf16be.txt:1', 'utf16le.txt:1', 'utf8bom.txt:1', 'utf8.txt:1') }
        @{ Name = 'a dollar sign matches before CRLF, as rg --crlf'; Mine = @{ Pattern = 'foo$' }; Real = @('--crlf', 'foo$')
            Want = @('crlf.txt:1') }
        @{ Name = 'a lone CR is not a line break and a last line needs no line ending'; Mine = @{ Pattern = 'needle' }; Real = @('needle')
            Want = @('nofinal.txt:2', 'mixed.txt:1', 'mixed.txt:3') }
        @{ Name = '-Hidden searches dot files, as rg --hidden'; Mine = @{ Pattern = 'alpha'; Hidden = $true }; Real = @('-S', '--hidden', 'alpha')
            Want = @('.hid/secret.txt:1', 'case.txt:1', 'case.txt:2', 'case.txt:3', 'sub/deep.md:1', 'sub/Deep.TXT:1') }
        @{ Name = '-g takes a glob on the name'; Mine = @{ Pattern = 'alpha'; Glob = '*.md' }; Real = @('-S', 'alpha'); Config = '--glob=*.md'
            Want = @('sub/deep.md:1') }
        @{ Name = '-g ignores the case of the name, as rg --glob-case-insensitive'; Mine = @{ Pattern = 'alpha'; Glob = '*.txt' }
            Real = @('-S', '--glob-case-insensitive', 'alpha'); Config = '--glob=*.txt'
            Want = @('case.txt:1', 'case.txt:2', 'case.txt:3', 'sub/Deep.TXT:1') }
        @{ Name = '-g with an exclamation mark excludes'; Mine = @{ Pattern = 'alpha'; Glob = '!*.txt' }
            Real = @('-S', '--glob-case-insensitive', 'alpha'); Config = '--glob=!*.txt'
            Want = @('sub/deep.md:1') }
        @{ Name = '-g takes a glob on the path'; Mine = @{ Pattern = 'alpha'; Glob = 'sub/**' }; Real = @('-S', 'alpha'); Config = '--glob=sub/**'
            Want = @('sub/deep.md:1', 'sub/Deep.TXT:1') }
        @{ Name = '-l gives the files only'; Mine = @{ Pattern = 'alpha'; FilesWithMatches = $true }; Real = @('-S', '-l', 'alpha'); Files = $true
            Want = @('case.txt', 'sub/deep.md', 'sub/Deep.TXT') }
        @{ Name = 'a binary file is skipped'; Mine = @{ Pattern = 'match' }; Real = @('match')
            Want = @() }
        @{ Name = 'ignored files are skipped'; Root = 'ign'; Path = 'c01-basic'; Mine = @{ Pattern = 'x' }; Real = @('x')
            Want = @('c01-basic/a.txt:1', 'c01-basic/sub/b.txt:1') }
        @{ Name = '-u searches ignored files, as rg --no-ignore'; Root = 'ign'; Path = 'c01-basic'; Mine = @{ Pattern = 'x'; NoIgnore = $true }; Real = @('--no-ignore', 'x')
            Want = @('c01-basic/a.txt:1', 'c01-basic/a.log:1', 'c01-basic/sub/b.txt:1', 'c01-basic/sub/b.log:1') }
        @{ Name = 'a file given by name is searched when a rule ignores it'; Root = 'ign'; Path = 'c01-basic/a.log'; Mine = @{ Pattern = 'x' }; Real = @('x')
            Want = @('c01-basic/a.log:1') }
    )

    function Get-RgRoot([hashtable]$Case) {
        if ($Case.ContainsKey('Root')) { $Ign } else { $Txt }
    }

    foreach ($c in $RgCases) {
        Test-Case ('rg: {0}' -f $c.Name) {
            $root = Get-RgRoot $c
            $mine = $c.Mine.Clone()
            if ($c.ContainsKey('Path')) { $mine.Path = Join-Rel $root $c.Path } else { $mine.Path = $root }
            $run = Invoke-Captured { rg @mine }
            Assert-Quiet $run 'rg'
            $got = @($run.Out | ForEach-Object {
                if ($c.ContainsKey('Files')) { ConvertTo-Rel $root "$_" } else { '{0}:{1}' -f (ConvertTo-Rel $root $_.Path), $_.LineNumber }
            })
            Assert-Same $got $c.Want 'matches'
        }
    }

    Test-Case 'real rg gives the same matches for these searches' {
        if (-not $RealRg) { throw 'SKIP: rg is not on this computer' }
        $bad = @(foreach ($c in $RgCases) {
            $root = Get-RgRoot $c
            $path = '.'
            if ($c.ContainsKey('Path')) { $path = $c.Path }
            $config = ''
            if ($c.ContainsKey('Config')) { $config = $c.Config }
            Set-Content -LiteralPath $RgConfig -Value $config -Encoding Ascii
            $lines = Invoke-Tool $RealRg $root (@('--no-ignore-global', '--no-heading', '-n', '--with-filename', '--path-separator', '/') + $c.Real + @($path))
            $got = @(foreach ($l in $lines) {
                $l = $l -replace '^\./', ''
                if ($c.ContainsKey('Files')) { $l } elseif ($l -match '^(.+?):(\d+):') { $Matches[1] + ':' + $Matches[2] }
            })
            try { Assert-Same $got $c.Want $c.Name } catch { $_.Exception.Message }
        })
        Assert-Equal ($bad -join ' | ') '' 'searches that differ'
    }

    Test-Case 'rg: Windows-1252 text is read when it is not valid UTF-8' {
        $run = Invoke-Captured { rg ('caf' + $E9) $Txt }
        Assert-Quiet $run 'rg'
        Assert-Same @($run.Out | ForEach-Object { '{0}:{1}' -f (ConvertTo-Rel $Txt $_.Path), $_.LineNumber }) @('cp1252.txt:1') 'matches'
    }

    Test-Case 'rg: a pattern that is not valid gives one error and no exception' {
        $run = Invoke-Captured { rg '(?P<n>al)' $Txt }
        Assert-Equal $run.Threw '' 'exception'
        Assert-Equal $run.Err.Count 1 'errors'
    }

    Test-Case 'rg: piped text is filtered' {
        $run = Invoke-Captured { 'one', 'two needle', 'three' | rg needle }
        Assert-Quiet $run 'rg'
        Assert-Same @($run.Out | ForEach-Object { "$_" }) @('two needle') 'lines'
    }

    $FdCases = @(
        @{ Name = 'lower-case text ignores case'; Mine = @{ Pattern = 'deep' }; Real = @('deep'); Want = @('sub/deep.md', 'sub/Deep.TXT') }
        @{ Name = 'an upper-case letter makes the search case-sensitive'; Mine = @{ Pattern = 'Deep' }; Real = @('Deep'); Want = @('sub/Deep.TXT') }
        @{ Name = '-e filters by extension without regard to case'; Mine = @{ Ext = 'txt' }; Real = @('-e', 'txt', '-t', 'f')
            Want = @('case.txt', 'crlf.txt', 'words.txt', 'utf16le.txt', 'utf16be.txt', 'utf8bom.txt', 'utf8.txt', 'cp1252.txt', 'nofinal.txt', 'mixed.txt',
                'blank.txt', 'empty.txt', 'mail.txt', 'sub/Deep.TXT') }
        @{ Name = '-t d gives folders only'; Mine = @{ Type = 'd' }; Real = @('-t', 'd'); Want = @('sub') }
        @{ Name = '-H includes dot files'; Mine = @{ Pattern = 'secret'; Hidden = $true }; Real = @('-H', 'secret'); Want = @('.hid/secret.txt') }
    )

    foreach ($c in $FdCases) {
        Test-Case ('fd: {0}' -f $c.Name) {
            $mine = $c.Mine.Clone()
            $mine.Path = $Txt
            $run = Invoke-Captured { fd @mine }
            Assert-Quiet $run 'fd'
            Assert-Same @($run.Out | ForEach-Object { ConvertTo-Rel $Txt "$_" }) $c.Want 'items'
        }
    }

    Test-Case 'real fd gives the same items for these searches' {
        if (-not $RealFd) { throw 'SKIP: fd is not on this computer' }
        $bad = @(foreach ($c in $FdCases) {
            $lines = Invoke-Tool $RealFd $Txt (@('--no-global-ignore-file', '--path-separator', '/') + $c.Real)
            try { Assert-Same @($lines | ForEach-Object { ($_ -replace '^\./', '').TrimEnd('/') }) $c.Want $c.Name } catch { $_.Exception.Message }
        })
        Assert-Equal ($bad -join ' | ') '' 'searches that differ'
    }

    Test-Case 'sd without -Apply changes no byte and no file time' {
        $dir = New-TextTree 'sd-preview'
        $before = Get-State $dir -Time
        $run = Invoke-Captured { sd '[oa]' '0' $dir -Hidden }
        Assert-Quiet $run 'sd'
        Assert-True ($run.Out.Count -ge 10) "the preview found only $($run.Out.Count) line(s)"
        Assert-Same (Get-State $dir -Time) $before 'files'
    }

    $SdCases = @(
        @{ File = 'case.txt'; Find = 'alpha'; Put = 'X'; About = 'lower-case text ignores case'; Hex = ConvertTo-Hex "X`nX`nX`n" }
        @{ File = 'crlf.txt'; Find = 'bar$'; Put = 'B'; About = 'CRLF stays and a dollar sign matches before it'; Hex = ConvertTo-Hex "foo`r`nB`r`n" }
        @{ File = 'utf8bom.txt'; Find = 'bom'; Put = 'mob'; About = 'the byte order mark of UTF-8 stays'; Hex = 'efbbbf 68 c3a9 6c6c6f 20 6d6f62 0a' }
        @{ File = 'utf8.txt'; Find = 'plain'; Put = ('pl' + $E9 + 'in'); About = 'UTF-8 without a byte order mark gets none'; Hex = '68 c3a9 6c6c6f 20 706c c3a9 696e 0a' }
        @{ File = 'utf16le.txt'; Find = 'w.rld'; Put = 'there'; About = 'UTF-16 little-endian stays'; Hex = 'fffe 6800 e900 6c00 6c00 6f00 2000 7400 6800 6500 7200 6500 0a00' }
        @{ File = 'utf16be.txt'; Find = 'w.rld'; Put = 'there'; About = 'UTF-16 big-endian stays'; Hex = 'feff 0068 00e9 006c 006c 006f 0020 0074 0068 0065 0072 0065 000a' }
        @{ File = 'cp1252.txt'; Find = 'lait'; Put = ('th' + $E9); About = 'Windows-1252 stays'; Hex = '636166 e9 20 6175 20 7468 e9 0a' }
        @{ File = 'nofinal.txt'; Find = 'needle'; Put = 'pin'; About = 'a last line without a line ending gets none'; Hex = ConvertTo-Hex "first`nlast pin" }
        @{ File = 'mixed.txt'; Find = 'needle'; Put = 'pin'; About = 'each line keeps its own line ending'; Hex = ConvertTo-Hex "one pin`r`ntwo`nthree pin`rfour pin" }
        @{ File = 'blank.txt'; Find = '^$'; Put = '-'; About = 'an empty line can match'; Hex = ConvertTo-Hex "a`n-`nb`n" }
        @{ File = 'mail.txt'; Find = '(\w+)@(\w+)'; Put = '$2 at $1'; About = 'groups go in the replacement'; Hex = ConvertTo-Hex "example at bob`n" }
        @{ File = 'words.txt'; Find = 'cat'; Put = 'c\nt'; About = 'a backslash in the replacement is literal'; Hex = ConvertTo-Hex "c\nt`nc\ntalog`nbob-c\nt`n" }
    )
    $SdDir = New-TextTree 'sd-apply'

    foreach ($c in $SdCases) {
        Test-Case ('sd -Apply: {0} ({1})' -f $c.About, $c.File) {
            $file = Join-Rel $SdDir $c.File
            $run = Invoke-Captured { sd $c.Find $c.Put $file -Apply }
            Assert-Quiet $run 'sd'
            Assert-Equal (Get-Hex $file) ($c.Hex -replace '\s', '') 'bytes'
        }
    }

    Test-Case 'real sd writes the same bytes where the contract says it does' {
        if (-not $RealSd) { throw 'SKIP: sd is not on this computer' }
        $mineDir = New-TextTree 'sd-diff-profile'
        $realDir = New-TextTree 'sd-diff-real'
        $bad = @(foreach ($c in @(@('crlf.txt', 'foo', 'baz'), @('utf8bom.txt', 'bom', 'mob'), @('nofinal.txt', 'needle', 'pin'), @('mixed.txt', 'needle', 'pin'),
                    @('mail.txt', '(\w+)@(\w+)', '$2 at $1'), @('blank.txt', '^$', '-'))) {
            $null = Invoke-Captured { sd $c[1] $c[2] (Join-Rel $mineDir $c[0]) -Apply }
            $null = Invoke-Tool $RealSd $realDir @($c[1], $c[2], $c[0])
            $mine = Get-Hex (Join-Rel $mineDir $c[0])
            $real = Get-Hex (Join-Rel $realDir $c[0])
            if ($mine -cne $real) { '{0}: the profile wrote {1} and sd wrote {2}' -f $c[0], $mine, $real }
        })
        Assert-Equal ($bad -join ' | ') '' 'files that differ'
    }

    Test-Case 'sd -Apply then sd-undo gives back every byte, and no temporary file stays' {
        $dir = New-TextTree 'sd-undo'
        $before = Get-State $dir
        $run = Invoke-Captured { sd '[oa]' '0' $dir -Hidden -Apply }
        Assert-Quiet $run 'sd'
        $after = Get-State $dir
        $changed = @($after | Where-Object { $before -cnotcontains $_ }).Count
        Assert-True ($changed -ge 12) "sd changed only $changed file(s)"
        $undo = Invoke-Captured { sd-undo }
        Assert-Quiet $undo 'sd-undo'
        Assert-Same (Get-State $dir) $before 'files after sd-undo'
        Assert-Equal @(Get-ChildItem -LiteralPath $env:TEMP -Force | Where-Object { $_.Name -like 'ps-profile-sd-*' }).Count 0 'temporary files'
    }

    Test-Case 'sd skips read-only, binary, Office, hidden and ignored files' {
        $dir = Join-Path $WorkDir 'sd-skip'
        foreach ($f in 'plain.txt', 'ro.txt', 'doc.docx', '.dot.txt', 'ign.txt') { Add-File $dir $f (ConvertTo-Hex "alpha`n") }
        Add-File $dir 'bin.dat' '616c706861 00 0a'
        Add-File $dir '.gitignore' (ConvertTo-Hex "ign.txt`n")
        New-Item -ItemType Directory -Path (Join-Path $dir '.git') -Force | Out-Null
        Set-ItemProperty -LiteralPath (Join-Path $dir 'ro.txt') -Name IsReadOnly -Value $true
        try {
            $before = Get-State $dir
            $run = Invoke-Captured { sd alpha beta $dir -Apply }
            Assert-Quiet $run 'sd'
            $changed = @(Get-State $dir | Where-Object { $before -cnotcontains $_ } | ForEach-Object { ($_ -split ' ')[0] })
            Assert-Same $changed @('plain.txt') 'files that sd changed'
            $run = Invoke-Captured { sd alpha beta $dir -Hidden -u -Apply }
            Assert-Quiet $run 'sd -Hidden -u'
            $changed = @(Get-State $dir | Where-Object { $before -cnotcontains $_ } | ForEach-Object { ($_ -split ' ')[0] })
            Assert-Same $changed @('plain.txt', '.dot.txt', 'ign.txt') 'files that sd -Hidden -u changed'
        } finally {
            Set-ItemProperty -LiteralPath (Join-Path $dir 'ro.txt') -Name IsReadOnly -Value $false
        }
    }

    Test-Case 'sd -g takes a glob on the path and an exclamation mark excludes' {
        $dir = New-TextTree 'sd-glob'
        $before = Get-State $dir
        $run = Invoke-Captured { sd alpha X $dir -g 'sub/**', '!*.md' -Apply }
        Assert-Quiet $run 'sd -g'
        $changed = @(Get-State $dir | Where-Object { $before -cnotcontains $_ } | ForEach-Object { ($_ -split ' ')[0] })
        Assert-Same $changed @('sub/Deep.TXT') 'files that sd changed'
    }

    Test-Case 'sd leaves a file alone when another program makes it longer during the run' {
        $dir = New-TextTree 'sd-fault-longer'
        $file = Join-Path $dir 'case.txt'
        $seen = @{ N = 0 }
        $run = Invoke-Captured {
            sd alpha X $file -Apply | ForEach-Object {
                if ($seen.N -eq 0) { Add-Content -LiteralPath $file -Value 'other' -NoNewline -Encoding Ascii }
                $seen.N++
            }
        }
        Assert-Equal $run.Threw '' 'exception'
        Assert-True ($seen.N -gt 0) 'sd gave no line before it wrote'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "alpha`nAlpha`nALPHA`nother") 'bytes'
    }

    Test-Case 'sd leaves a file alone when another program changes it during the run and keeps its length and time' {
        $dir = New-TextTree 'sd-fault-same'
        $file = Join-Path $dir 'case.txt'
        $time = (Get-Item -LiteralPath $file).LastWriteTimeUtc
        $seen = @{ N = 0 }
        $run = Invoke-Captured {
            sd alpha X $file -Apply | ForEach-Object {
                if ($seen.N -eq 0) {
                    Add-File $dir 'case.txt' (ConvertTo-Hex "omega`nAlpha`nALPHA`n")
                    Set-ItemProperty -LiteralPath $file -Name LastWriteTimeUtc -Value $time
                }
                $seen.N++
            }
        }
        Assert-Equal $run.Threw '' 'exception'
        Assert-True ($seen.N -gt 0) 'sd gave no line before it wrote'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "omega`nAlpha`nALPHA`n") 'bytes'
    }

    Test-Case 'sd fails cleanly when the folder goes away during the run, as when a share drops' {
        $dir = New-TextTree 'sd-fault-gone'
        $file = Join-Path $dir 'case.txt'
        $moved = Join-Path $WorkDir 'sd-fault-gone-moved'
        $seen = @{ N = 0 }
        $run = Invoke-Captured {
            sd alpha X $file -Apply | ForEach-Object {
                if ($seen.N -eq 0) { Rename-Item -LiteralPath $dir -NewName 'sd-fault-gone-moved' }
                $seen.N++
            }
        }
        Assert-Equal $run.Threw '' 'exception'
        Assert-True ($seen.N -gt 0) 'sd gave no line before it wrote'
        Assert-True (-not (Test-Path -LiteralPath $dir)) 'sd made the folder again'
        Assert-Equal (Get-Hex (Join-Path $moved 'case.txt')) (ConvertTo-Hex "alpha`nAlpha`nALPHA`n") 'bytes of the file in the moved folder'
        Assert-Equal @(Get-ChildItem -LiteralPath $env:TEMP -Force | Where-Object { $_.Name -like 'ps-profile-sd-*' }).Count 0 'temporary files'
        Assert-True (@($run.Info) -match 'changed 0 of 1').Count 'sd did not report 0 of 1 file(s) changed'
    }

    Test-Case 'sd leaves a file alone when another program holds it open' {
        if (-not $OnWindows) { throw 'SKIP: a file lock needs Windows. This case has not run on any computer yet.' }
        $dir = New-TextTree 'sd-fault-locked'
        $file = Join-Path $dir 'case.txt'
        $holder = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c (ping -n 15 127.0.0.1 >nul) 9>>"{0}"' -f $file) -WindowStyle Minimized -PassThru
        try {
            Start-Sleep -Milliseconds 1500
            $run = Invoke-Captured { sd alpha X $file -Apply }
            Assert-Equal $run.Threw '' 'exception'
        } finally {
            Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "alpha`nAlpha`nALPHA`n") 'bytes'
    }

    Test-Case 'sd-undo leaves a file alone when it changed after sd, and keeps its copy of the original' {
        $dir = New-TextTree 'sd-undo-changed'
        $file = Join-Path $dir 'case.txt'
        $run = Invoke-Captured { sd alpha X $file -Apply }
        Assert-Quiet $run 'sd'
        Add-Content -LiteralPath $file -Value 'later' -NoNewline -Encoding Ascii
        $undo = Invoke-Captured { sd-undo }
        Assert-Equal $undo.Threw '' 'exception'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "X`nX`nX`nlater") 'bytes'
        Assert-True (Test-Path -LiteralPath (Join-Path $UndoDir 'manifest.txt')) 'sd-undo deleted its list of files'
        $copies = @(Get-ChildItem -LiteralPath $UndoDir -Force | Where-Object { $_.Name -ne 'manifest.txt' } | ForEach-Object { Get-Hex $_.FullName })
        Assert-True ($copies -ccontains (ConvertTo-Hex "alpha`nAlpha`nALPHA`n")) 'sd-undo did not keep the original bytes'
    }

    Test-Case 'sd-undo leaves a file alone when it changed after sd and kept its length and time' {
        $dir = New-TextTree 'sd-undo-same'
        $file = Join-Path $dir 'case.txt'
        $run = Invoke-Captured { sd alpha X $file -Apply }
        Assert-Quiet $run 'sd'
        $time = (Get-Item -LiteralPath $file).LastWriteTimeUtc
        Add-File $dir 'case.txt' (ConvertTo-Hex "Y`nY`nY`n")
        Set-ItemProperty -LiteralPath $file -Name LastWriteTimeUtc -Value $time
        $undo = Invoke-Captured { sd-undo }
        Assert-Equal $undo.Threw '' 'exception'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "Y`nY`nY`n") 'bytes'
    }

    Test-Case 'sd leaves a file alone when its encoding cannot hold the new text' {
        $dir = New-TextTree 'sd-encoding'
        $file = Join-Path $dir 'cp1252.txt'
        $run = Invoke-Captured { sd lait ('l' + [string][char]0x151) $file -Apply }
        Assert-Equal $run.Threw '' 'exception'
        Assert-Equal (Get-Hex $file) '636166e9206175206c6169740a' 'bytes'
    }

    Test-Case 'a name with square brackets works in fd, rg, sd, sd-undo and rnm' {
        $dir = Join-Path $WorkDir 'brackets'
        Add-File $dir 'note[1].txt' (ConvertTo-Hex "needle here`n")
        Add-File $dir 'note1.txt' (ConvertTo-Hex "other`n")
        $file = Join-Path $dir 'note[1].txt'
        $run = Invoke-Captured { fd 'note\[' $dir }
        Assert-Quiet $run 'fd'
        Assert-Same @($run.Out | ForEach-Object { "$_" }) @($file) 'fd'
        $run = Invoke-Captured { rg needle $dir }
        Assert-Quiet $run 'rg'
        Assert-Same @($run.Out | ForEach-Object { $_.Path }) @($file) 'rg'
        $run = Invoke-Captured { sd needle pin $dir -Apply }
        Assert-Quiet $run 'sd'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "pin here`n") 'bytes after sd'
        $run = Invoke-Captured { sd-undo }
        Assert-Quiet $run 'sd-undo'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "needle here`n") 'bytes after sd-undo'
        $run = Invoke-Captured { rnm 'note\[' 'memo[' $dir -Apply }
        Assert-Quiet $run 'rnm'
        Assert-Same @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { $_.Name }) @('memo[1].txt', 'note1.txt') 'names after rnm'
    }

    function New-RenameTree([string]$Name) {
        $dir = Join-Path $WorkDir $Name
        foreach ($f in @(@('draft-1.txt', 'one'), @('draft-2.txt', 'two'), @('sub/draft-3.txt', 'three'), @('ab.txt', 'AB'), @('ba.txt', 'BA'), @('readme.md', 'r'),
                @('.draft-hidden.txt', 'h'), @('ign/draft-x.txt', 'x'), @('draft-dir/in.txt', 'in'), @('.gitignore', "ign/`n"))) {
            Add-File $dir $f[0] (ConvertTo-Hex $f[1])
        }
        New-Item -ItemType Directory -Path (Join-Path $dir '.git') -Force | Out-Null
        $dir
    }

    function Rename-State([string[]]$State, [hashtable]$Map) {
        @(foreach ($line in $State) {
            $pair = $line -split ' (?=[0-9A-F]{64}$)', 2
            $name = $pair[0]
            if ($Map.ContainsKey($name)) { $name = $Map[$name] }
            $name + ' ' + $pair[1]
        })
    }

    Test-Case 'rnm without -Apply changes no name' {
        $dir = New-RenameTree 'rnm-preview'
        $before = Get-State $dir
        $run = Invoke-Captured { rnm draft final $dir }
        Assert-Quiet $run 'rnm'
        Assert-Same @($run.Out | ForEach-Object { $_.NewName }) @('final-1.txt', 'final-2.txt') 'new names in the preview'
        Assert-Same (Get-State $dir) $before 'files'
    }

    Test-Case 'rnm -Apply renames the files of one folder, and the reverse rename gives back the tree' {
        $dir = New-RenameTree 'rnm-apply'
        $before = Get-State $dir
        $run = Invoke-Captured { rnm draft final $dir -Apply }
        Assert-Quiet $run 'rnm'
        Assert-Same (Get-State $dir) (Rename-State $before @{ 'draft-1.txt' = 'final-1.txt'; 'draft-2.txt' = 'final-2.txt' }) 'files after the rename'
        $run = Invoke-Captured { rnm final draft $dir -Apply }
        Assert-Quiet $run 'rnm back'
        Assert-Same (Get-State $dir) $before 'files after the reverse rename'
    }

    Test-Case 'rnm -r renames in subfolders and skips hidden and ignored files' {
        $dir = New-RenameTree 'rnm-recurse'
        $before = Get-State $dir
        $run = Invoke-Captured { rnm draft final $dir -r -Apply }
        Assert-Quiet $run 'rnm -r'
        Assert-Same (Get-State $dir) (Rename-State $before @{ 'draft-1.txt' = 'final-1.txt'; 'draft-2.txt' = 'final-2.txt'; 'sub/draft-3.txt' = 'sub/final-3.txt' }) 'files after the rename'
        $run = Invoke-Captured { rnm final draft $dir -r -Apply }
        Assert-Quiet $run 'rnm -r back'
        Assert-Same (Get-State $dir) $before 'files after the reverse rename'
    }

    Test-Case 'rnm -Folders renames folders too, and the reverse rename gives back the tree' {
        $dir = New-RenameTree 'rnm-folders'
        $before = Get-State $dir
        $run = Invoke-Captured { rnm draft final $dir -Folders -Apply }
        Assert-Quiet $run 'rnm -Folders'
        Assert-Same (Get-State $dir) (Rename-State $before @{ 'draft-1.txt' = 'final-1.txt'; 'draft-2.txt' = 'final-2.txt'; 'draft-dir/in.txt' = 'final-dir/in.txt' }) 'files after the rename'
        $run = Invoke-Captured { rnm final draft $dir -Folders -Apply }
        Assert-Quiet $run 'rnm -Folders back'
        Assert-Same (Get-State $dir) $before 'files after the reverse rename'
    }

    Test-Case 'rnm swaps two names' {
        $dir = New-RenameTree 'rnm-swap'
        $before = Get-State $dir
        $run = Invoke-Captured { rnm '^(a|b)(a|b)\.txt$' '$2$1.txt' $dir -Apply }
        Assert-Quiet $run 'rnm'
        Assert-Same (Get-State $dir) (Rename-State $before @{ 'ab.txt' = 'ba.txt'; 'ba.txt' = 'ab.txt' }) 'files after the swap'
    }

    Test-Case 'rnm changes only the case of a name' {
        $dir = New-RenameTree 'rnm-case'
        $run = Invoke-Captured { rnm readme README $dir -Apply }
        Assert-Quiet $run 'rnm'
        $names = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { $_.Name })
        Assert-True ($names -ccontains 'README.md') "the folder has $($names -join ', ')"
        Assert-True ($names -cnotcontains 'readme.md') 'readme.md is still there'
    }

    Test-Case 'rnm changes no name when two files would get one name, a name exists or a name is not valid' {
        $dir = New-RenameTree 'rnm-conflict'
        $before = Get-State $dir
        foreach ($c in @(@('draft-\d', 'same'), @('draft-1', 'draft-2'), @('draft', 'a:b'))) {
            $run = Invoke-Captured { rnm $c[0] $c[1] $dir -Apply }
            Assert-Equal $run.Threw '' "exception for $($c[0])"
            Assert-True ($run.Err.Count -ge 1) "rnm $($c[0]) $($c[1]) gave no error"
            Assert-Same (Get-State $dir) $before "files after rnm $($c[0]) $($c[1])"
        }
    }

    Test-Case 'rnm undoes its renames when one rename fails' {
        $dir = New-RenameTree 'rnm-rollback'
        $before = Get-State $dir
        $seen = @{ N = 0 }
        $run = Invoke-Captured {
            rnm draft final $dir -Apply | ForEach-Object {
                if ($seen.N -eq 0) { Add-File $dir 'final-2.txt' (ConvertTo-Hex 'blocker') }
                $seen.N++
            }
        }
        Assert-Equal $run.Threw '' 'exception'
        Assert-True ($seen.N -gt 0) 'rnm gave no name before it renamed'
        Assert-True ($run.Err.Count -ge 1) 'rnm gave no error'
        $after = @(Get-State $dir | Where-Object { $_ -notlike 'final-2.txt *' })
        Assert-Same $after $before 'files, without the file that blocked the rename'
        Assert-Equal (Get-Hex (Join-Path $dir 'final-2.txt')) (ConvertTo-Hex 'blocker') 'bytes of the file that blocked the rename'
    }

    Test-Case 'a path of more than 260 characters works in fd, rg, sd, sd-undo and rnm' {
        $top = Join-Path $WorkDir 'long'
        $deep = $top
        foreach ($i in 1..6) { $deep = Join-Path $deep ('segment-' + $i + ('x' * 41)) }
        $file = Join-Path $deep 'long-draft.txt'
        try {
            New-Item -ItemType Directory -Path $deep -Force -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath $file -Value "needle here`n" -NoNewline -Encoding Ascii -ErrorAction Stop
        } catch { throw 'SKIP: this computer cannot make a path of more than 260 characters' }
        Assert-True ($file.Length -gt 260) "the path has only $($file.Length) characters"
        $run = Invoke-Captured { fd long-draft $top }
        Assert-Quiet $run 'fd'
        Assert-Same @($run.Out | ForEach-Object { "$_" }) @($file) 'fd'
        $run = Invoke-Captured { rg needle $top }
        Assert-Quiet $run 'rg'
        Assert-Equal $run.Out.Count 1 'rg matches'
        $run = Invoke-Captured { sd needle pin $top -Apply }
        Assert-Quiet $run 'sd'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "pin here`n") 'bytes after sd'
        $run = Invoke-Captured { sd-undo }
        Assert-Quiet $run 'sd-undo'
        Assert-Equal (Get-Hex $file) (ConvertTo-Hex "needle here`n") 'bytes after sd-undo'
        $run = Invoke-Captured { rnm long-draft long-final $top -r -Apply }
        Assert-Quiet $run 'rnm'
        Assert-True (Test-Path -LiteralPath (Join-Path $deep 'long-final.txt')) 'rnm did not rename the file'
    }
} finally {
    foreach ($k in $saved.Keys) { Set-Item -LiteralPath "Env:$k" -Value $saved[$k] }
    if (-not $Keep) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { $_.Status -eq 'FAIL' })
$skipped = @($Results | Where-Object { $_.Status -eq 'SKIP' })
Write-Output ''
Write-Output ('{0} passed, {1} failed, {2} skipped' -f ($Results.Count - $failed.Count - $skipped.Count), $failed.Count, $skipped.Count)
if ($failed.Count) { exit 1 }
