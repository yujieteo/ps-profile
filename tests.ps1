param(
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'

$OldTicks = [datetime]::new(2020, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
$Tree = Join-Path $WorkDir 'tree'
$Data = Join-Path $WorkDir 'data'
$IndexName = 'idx2_' + ($Tree -replace '[^A-Za-z0-9]+', '_')
$OldIndexName = 'idx_' + ($Tree -replace '[^A-Za-z0-9]+', '_')
$Zip = Join-Path $WorkDir 'zip'

function Write-Fixture([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding utf8NoBOM
}

function Write-OfficeFixture([string]$Name, [hashtable]$Parts) {
    $dir = Join-Path $Zip $Name
    foreach ($part in $Parts.Keys) { Write-Fixture (Join-Path $dir $part) $Parts[$part] }
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath (Join-Path $Tree "$Name.zip") -Force
    Move-Item -LiteralPath (Join-Path $Tree "$Name.zip") -Destination (Join-Path $Tree $Name)
}

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Tree, $Data | Out-Null
Write-Fixture (Join-Path $Tree 'a.txt') "alpha`nbeta`ngamma`n"
Write-Fixture (Join-Path $Tree 'b.md') "Alpha one`r`nAlpha two`r`n"
Write-Fixture (Join-Path $Tree 'sub/c.txt') "delta`nalpha again`n"
Write-Fixture (Join-Path $Tree 'sub/deep/d.csv') "total,5`n"
Write-Fixture (Join-Path $Tree 'empty/.keep') ''
[System.IO.File]::WriteAllBytes((Join-Path $Tree 'bom16.txt'), [byte[]](0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00))
[System.IO.File]::WriteAllBytes((Join-Path $Tree 'cp1252.txt'), [byte[]](0x63, 0x61, 0x66, 0xE9))
[System.IO.File]::WriteAllBytes((Join-Path $Tree 'bin.dat'), [byte[]](0x61, 0x00, 0x62))
Write-Fixture (Join-Path $Tree 'old.doc') 'legacy'
Write-OfficeFixture 'f.docx' @{
    'word/document.xml' = '<w:document><w:body><w:p><w:r><w:t>Hello &amp; world</w:t></w:r></w:p><w:p><w:r><w:t>Second</w:t></w:r><w:tab/><w:r><w:t xml:space="preserve">end</w:t></w:r></w:p><w:p></w:p></w:body></w:document>'
}
Write-OfficeFixture 'f.xlsx' @{
    'xl/workbook.xml'            = '<workbook><sheets><sheet name="S&amp;1" sheetId="1" r:id="rId1"/></sheets></workbook>'
    'xl/_rels/workbook.xml.rels' = '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>'
    'xl/sharedStrings.xml'       = '<sst><si><t>Name</t></si><si><t>x &lt; y</t></si></sst>'
    'xl/worksheets/sheet1.xml'   = '<worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c><c r="C1" t="b"><v>1</v></c><c r="D1" t="inlineStr"><is><t>inl</t></is></c><c r="E1"/><c r="A2" t="s"><v>1</v></c></row></sheetData></worksheet>'
}
Write-OfficeFixture 'f.pptx' @{
    'ppt/presentation.xml'            = '<p:presentation><p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>'
    'ppt/_rels/presentation.xml.rels' = '<Relationships><Relationship Id="rId1" Target="slides/slide1.xml"/><Relationship Id="rId2" Target="/ppt/slides/slide2.xml"/></Relationships>'
    'ppt/slides/slide1.xml'           = '<p:sld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/></p:nvSpPr><p:txBody><a:p><a:r><a:t>Hello</a:t></a:r></a:p><a:p><a:r><a:t>World</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:sld>'
    'ppt/slides/slide2.xml'           = '<p:sld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/></p:nvSpPr><p:txBody><a:p><a:r><a:t>Two</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:sld>'
}
Write-Fixture (Join-Path $WorkDir 'history.txt') ("git status`nls " + [char]96 + "`nfoo`ngit status`n`necho hi`n")
foreach ($item in @(Get-ChildItem -LiteralPath $Tree -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)) {
    $item.LastWriteTimeUtc = $OldTicks
}
(Get-Item -LiteralPath $Tree).LastWriteTimeUtc = $OldTicks

$env:LOCALAPPDATA = $Data
$env:TEMP = Join-Path $WorkDir 'tmp'
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
. $ProfilePath
if ($Strict) { Set-StrictMode -Version Latest }

$script:Outputs = @()
$script:Failures = @()

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        $result = & $Body 3>$null
        $status = 'pass'
    } catch {
        $result = $_.Exception.Message
        $status = 'fail'
        $script:Failures += $Name
    }
    $json = (ConvertTo-Json -InputObject @($result) -Depth 6 -Compress) -replace [regex]::Escape($WorkDir), '<work>'
    $script:Outputs += "$Name`t$status`t$json"
}

function Expect($Actual, $Expected) {
    $a = ConvertTo-Json -InputObject @($Actual) -Depth 6 -Compress
    $e = ConvertTo-Json -InputObject @($Expected) -Depth 6 -Compress
    if ($a -ne $e) { throw "expected $e but got $a" }
}

function Show-Host([scriptblock]$Body) {
    (& $Body 6>&1 | Out-String) -replace [regex]::Escape($WorkDir), '<work>'
}

function ConvertTo-Obj([hashtable]$Property) { New-Object PSObject -Property $Property }

function Merge-Table([hashtable]$Base, [hashtable]$Change) {
    $merged = $Base.Clone()
    foreach ($key in $Change.Keys) { $merged[$key] = $Change[$key] }
    $merged
}

function Invoke-Index {
    $global:PSProfileRoots = @(@{ Unc = $Tree; Sep = '/'; Base = Join-Path $global:PSProfileDataDir $IndexName })
    $global:PSProfileIndexCache = @{}
    & $global:PSProfileIndexBuilder $Tree $global:PSProfileDataDir '' 0 0 3>&1 | Out-String
}

function Clear-Index {
    $global:PSProfileRoots = @()
    $global:PSProfileIndexCache = @{}
    Remove-Item -Path (Join-Path $global:PSProfileDataDir 'idx*'), (Join-Path $global:PSProfileDataDir 'index.lock') -Force -ErrorAction SilentlyContinue
}

function Use-Fzf([string[]]$Answers, $Items, [string]$Query = '') {
    $global:FzfAnswers = @($Answers)
    function global:Read-Host {
        $next = $global:FzfAnswers[0]
        $global:FzfAnswers = @($global:FzfAnswers | Select-Object -Skip 1)
        $next
    }
    try { $Items | fzf -Query $Query 6>$null } finally { Remove-Item Function:\Read-Host }
}

Test-Case 'the check runs on PowerShell 7 and the 7 branch uses AsByteStream' {
    Expect $PSVersionTable.PSVersion.Major 7
    Expect ([bool]$global:PSProfileByteArgs.AsByteStream) $true
    Expect $global:PSProfileAnsi 1252
}

Test-Case 'the profile loads in ConstrainedLanguage mode' {
    Expect "$($ExecutionContext.SessionState.LanguageMode)" 'ConstrainedLanguage'
}

Test-Case 'output goes to the host only for a command typed last in the pipeline, and = or ( before the command means the caller wants objects' {
    $typed = @{ CommandOrigin = 'Runspace'; PipelinePosition = 1; PipelineLength = 1; Line = 'fd x'; OffsetInLine = 1 }
    $result = [ordered]@{
        typed      = Test-PSProfileToHost (ConvertTo-Obj $typed)
        assigned   = Test-PSProfileToHost (ConvertTo-Obj (Merge-Table $typed @{ Line = '$a = fd x'; OffsetInLine = 6 }))
        parens     = Test-PSProfileToHost (ConvertTo-Obj (Merge-Table $typed @{ Line = '(fd x)'; OffsetInLine = 2 }))
        piped      = Test-PSProfileToHost (ConvertTo-Obj (Merge-Table $typed @{ PipelineLength = 2 }))
        fromScript = Test-PSProfileToHost (ConvertTo-Obj (Merge-Table $typed @{ CommandOrigin = 'Internal' }))
    }
    Expect $result.typed $true
    Expect $result.assigned $false
    Expect $result.parens $false
    Expect $result.piped $false
    Expect $result.fromScript $false
    $result
}

Test-Case 'the profile keeps its data in the ps-profile folder under LOCALAPPDATA' {
    Expect $global:PSProfileDataDir (Join-Path $Data 'ps-profile')
    Expect (Test-Path -LiteralPath $global:PSProfileDataDir -PathType Container) $true
}

Test-Case 'a share root that is not a non-empty string or not on a mapped network drive gives a warning that names $ShareRoots' {
    $warnings = @(ConvertTo-PSProfileRoot @('', 5, 'Q:\nowhere', "$Tree/") 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
    $roots = @(ConvertTo-PSProfileRoot @('', 5, 'Q:\nowhere', "$Tree/") 3>$null)
    Expect @($roots | ForEach-Object { $_.Unc }) @('Q:\nowhere', $Tree)
    Expect @($warnings | Where-Object { $_ -like '$ShareRoots:*S:\Finance*' }).Count 3
    [ordered]@{ warnings = $warnings; seps = @($roots | ForEach-Object { $_.Sep }) }
}

Test-Case 'a full path resolves an existing folder and keeps a missing path as typed' {
    Expect (Get-PSProfileFullPath $Tree) $Tree
    Expect (Get-PSProfileFullPath (Join-Path $Tree 'missing')) (Join-Path $Tree 'missing')
    Expect (Get-PSProfileFullPath '') ((Get-Location).ProviderPath)
}

Test-Case 'a path without a mapped drive stays the same as a UNC path' {
    Expect (ConvertTo-PSProfileUnc '/tmp/x') '/tmp/x'
    Expect (ConvertTo-PSProfileUnc 'Q:\nowhere') 'Q:\nowhere'
}

Test-Case 'an item path comes from a string, FullName or Path' {
    Expect (Get-PSProfileItemPath 'p') 'p'
    Expect (Get-PSProfileItemPath (ConvertTo-Obj @{ FullName = 'f' })) 'f'
    Expect (Get-PSProfileItemPath (ConvertTo-Obj @{ Path = 'q' })) 'q'
    Expect (Get-PSProfileItemPath 5) '5'
}

Test-Case 'text reading handles a BOM, UTF-8, Windows-1252, a binary file and a missing file' {
    $result = [ordered]@{
        utf8   = Read-PSProfileText (Join-Path $Tree 'a.txt')
        utf16  = Read-PSProfileText (Join-Path $Tree 'bom16.txt')
        ansi   = Read-PSProfileText (Join-Path $Tree 'cp1252.txt')
        binary = Read-PSProfileText (Join-Path $Tree 'bin.dat')
        empty  = Read-PSProfileText (Join-Path $Tree 'empty/.keep')
    }
    Expect $result.utf16 'hi'
    Expect $result.ansi ('caf' + [char]0xE9)
    Expect $result.binary $null
    Expect $result.empty ''
    $result
}

Test-Case 'text splits into lines without a final empty line' {
    Expect (Split-PSProfileLines "a`r`nb`n") @('a', 'b')
    Expect (Split-PSProfileLines 'a') @('a')
    Expect (Split-PSProfileLines '') @('')
    Expect (Split-PSProfileLines "a`n`n") @('a', '')
}

Test-Case 'XML text decodes the ampersand last so no entity decodes twice' {
    Expect (ConvertFrom-PSProfileXmlText '&lt;&amp;lt;&quot;&apos;&gt;') '<&lt;"''>'
}

Test-Case 'an XML attribute is found by whole name and missing gives an empty string' {
    Expect (Get-PSProfileXmlAttr '<c r="A1" xr="no" t="s"/>' 'r') 'A1'
    Expect (Get-PSProfileXmlAttr '<c r="A1"/>' 't') ''
    Expect (Get-PSProfileXmlAttr '<sheet r:id="rId1"/>' 'r:id') 'rId1'
}

Test-Case 'a part path is joined from the base folder or from the package root' {
    Expect ((Join-PSProfilePart 'd' 'xl' 'worksheets/s.xml') -replace '\\', '/') 'd/xl/worksheets/s.xml'
    Expect ((Join-PSProfilePart 'd' 'xl' '/xl/s.xml') -replace '\\', '/') 'd/xl/s.xml'
}

Test-Case 'run text joins runs and turns a tab element into a tab' {
    Expect (Get-PSProfileRunText '<w:t>a</w:t><w:tab/><a:t x="1">b&amp;</a:t>') "a`tb&"
}

Test-Case 'a Word file gives one line per non-empty paragraph' {
    Expect @(ConvertFrom-PSProfileOffice (Join-Path $Tree 'f.docx')) @('Hello & world', "Second`tend")
}

Test-Case 'an Excel file gives one line per cell with sheet and address' {
    Expect @(ConvertFrom-PSProfileOffice (Join-Path $Tree 'f.xlsx')) @('S&1!A1: Name', 'S&1!B1: 42', 'S&1!C1: TRUE', 'S&1!D1: inl', 'S&1!A2: x < y')
}

Test-Case 'a PowerPoint file gives one line per slide and shape' {
    Expect @(ConvertFrom-PSProfileOffice (Join-Path $Tree 'f.pptx')) @('Slide 1 / Title 1: Hello / World', 'Slide 2 / Body: Two')
}

Test-Case 'the index uses the idx2_ name and removes the files of version 1.0.0' {
    Clear-Index
    Write-Fixture (Join-Path $global:PSProfileDataDir "$OldIndexName.idx") 'old'
    Write-Fixture (Join-Path $global:PSProfileDataDir "$OldIndexName.state") 'old'
    $warnings = Invoke-Index
    $names = @(Get-ChildItem -LiteralPath $global:PSProfileDataDir -File | ForEach-Object { $_.Name } | Sort-Object)
    Expect ($names -contains "$IndexName.idx") $true
    Expect ($names -contains "$IndexName.state") $true
    Expect ($names -contains "$OldIndexName.idx") $false
    Expect ($names -contains "$OldIndexName.state") $false
    Expect ($names -contains "$IndexName.partial") $false
    Expect ($names -contains 'index.lock') $false
    [ordered]@{ names = $names; warnings = $warnings }
}

Test-Case 'an index line has ticks, size and path and a folder line has two tabs and the path' {
    $indexLines = Get-PSProfileIndex $global:PSProfileRoots[0]
    $lines = @($indexLines | Sort-Object)
    $folders = @($lines -like "`t`t*")
    $files = @($lines -notlike "`t`t*")
    Expect ($folders -contains "`t`t$Tree/sub/deep") $true
    Expect ($files -contains ('{0}{1}{2}{1}{3}' -f $OldTicks.Ticks, "`t", 21, "$Tree/a.txt")) $false
    Expect ($files -contains ('{0}{1}{2}{1}{3}' -f $OldTicks.Ticks, "`t", 17, "$Tree/a.txt")) $true
    $lines
}

Test-Case 'the index state is empty after a build, old with a partial marker and building with a live lock' {
    $result = [ordered]@{ built = Get-PSProfileIndexState }
    Set-Content -LiteralPath (Join-Path $global:PSProfileDataDir "$IndexName.partial") -Value 'partial'
    $result.partial = Get-PSProfileIndexState
    Remove-Item -LiteralPath (Join-Path $global:PSProfileDataDir "$IndexName.partial")
    Set-Content -LiteralPath (Join-Path $global:PSProfileDataDir 'index.lock') -Value $PID
    $result.locked = Get-PSProfileIndexState
    Remove-Item -LiteralPath (Join-Path $global:PSProfileDataDir 'index.lock')
    Expect $result.built ''
    Expect $result.partial 'old'
    Expect $result.locked 'building'
    $result
}

Test-Case 'a live lock stops the build and a missing root keeps the old index' {
    $before = Get-Content -LiteralPath (Join-Path $global:PSProfileDataDir "$IndexName.idx") -Raw
    Set-Content -LiteralPath (Join-Path $global:PSProfileDataDir 'index.lock') -Value $PID
    $locked = & $global:PSProfileIndexBuilder $Tree $global:PSProfileDataDir '' 0 0 3>&1 | Out-String
    Remove-Item -LiteralPath (Join-Path $global:PSProfileDataDir 'index.lock')
    $missing = & $global:PSProfileIndexBuilder (Join-Path $Tree 'nowhere') $global:PSProfileDataDir '' 0 0 3>&1 | Out-String
    $after = Get-Content -LiteralPath (Join-Path $global:PSProfileDataDir "$IndexName.idx") -Raw
    Expect $after $before
    [ordered]@{ locked = $locked; missing = $missing }
}

Test-Case 'a root is found by its path and a longer name is not under it' {
    Expect (Find-PSProfileRoot $Tree).Unc $Tree
    Expect (Find-PSProfileRoot "$Tree/sub").Unc $Tree
    Expect ($null -eq (Find-PSProfileRoot "${Tree}x")) $true
}

Test-Case 'fd reads the index under a share root' {
    $result = [ordered]@{
        all     = @(Find-PSProfileFile -Path $Tree | Sort-Object)
        pattern = @(Find-PSProfileFile -Pattern 'txt$' -Path $Tree | Sort-Object)
        anchor  = @(Find-PSProfileFile -Pattern '^c\.' -Path $Tree | Sort-Object)
        folder  = @(Find-PSProfileFile -Path "$Tree/sub" | Sort-Object)
        ext     = @(Find-PSProfileFile -Ext 'csv', '.md' -Path $Tree | Sort-Object)
        changed = @(Find-PSProfileFile -Changed '99999d' -Path $Tree | Sort-Object)
        recent  = @(Find-PSProfileFile -Changed '1d' -Path $Tree)
        big     = @(Find-PSProfileFile -Size '+20' -Path $Tree | Sort-Object)
        small   = @(Find-PSProfileFile -Size '-8B' -Path $Tree | Sort-Object)
        meta    = @(Find-PSProfileFile -Meta -Pattern 'd.csv' -Path $Tree)
    }
    Expect $result.anchor @("$Tree/sub/c.txt")
    Expect $result.recent @()
    Expect @($result.ext).Count 2
    Expect $result.meta @("$($OldTicks.Ticks)`t8`t$Tree/sub/deep/d.csv")
    $result
}

Test-Case 'a filter returns files only and a bad filter value is an error' {
    $errors = @()
    $null = Find-PSProfileFile -Changed 'x' -Path $Tree -ErrorVariable +errors -ErrorAction SilentlyContinue
    $null = Find-PSProfileFile -Size '1TB' -Path $Tree -ErrorVariable +errors -ErrorAction SilentlyContinue
    Expect (@(Find-PSProfileFile -Ext 'txt' -Path $Tree) -contains "$Tree/sub") $false
    @($errors | ForEach-Object { "$_" })
}

Test-Case 'fd scans a folder that is not under a share root and -Limit stops the scan' {
    Clear-Index
    $all = @(Find-PSProfileFile -Path $Tree | Sort-Object)
    $limited = @(Find-PSProfileFile -Path $Tree -Limit 2 3>&1 | ForEach-Object { "$_" })
    $meta = @(Find-PSProfileFile -Meta -Path $Tree -Pattern '^(sub|d\.csv)$' | Sort-Object)
    $filtered = @(Find-PSProfileFile -Ext csv -Size '+1B' -Changed '99999d' -Path $Tree)
    Expect $filtered @("$Tree/sub/deep/d.csv")
    Expect @($limited | Where-Object { $_ -like 'fd: stopped after 2 items*' }).Count 1
    [ordered]@{ all = $all; limited = $limited.Count; meta = $meta }
}

Test-Case 'a size is written with the unit that fits' {
    $result = @(0, 1023, 1024, 1536, 1048576, 1073741824 | ForEach-Object { Format-PSProfileSize $_ })
    Expect $result @('0 B', '1023 B', '1.0 KB', '1.5 KB', '1.0 MB', '1.0 GB')
    $result
}

Test-Case 'recent lists the newest files first as paths when the output is piped' {
    @(recent $Tree -Days 99999 -Count 3)
}

Test-Case 'rg gives objects with context when the output is not for the host' {
    $result = [ordered]@{
        plain   = @(rg 'alpha' $Tree | ForEach-Object { '{0}:{1}:{2}' -f $_.Path, $_.LineNumber, $_.Line } | Sort-Object)
        ignore  = @(rg 'alpha' $Tree -IgnoreCase | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber } | Sort-Object)
        simple  = @(rg 'a.c' $Tree -SimpleMatch)
        glob    = @(rg 'alpha' $Tree -IgnoreCase -Glob '*.md' | ForEach-Object { $_.Line })
        files   = @(rg 'alpha' $Tree -FilesWithMatches | Sort-Object)
        context = @(rg 'beta' (Join-Path $Tree 'a.txt') -Context 1 | ForEach-Object { , @($_.PreContext, $_.PostContext) })
        office  = @(rg 'Hello|Name|World' $Tree -Office | ForEach-Object { $_.Line } | Sort-Object)
        piped   = @(Find-PSProfileFile -Ext txt -Path $Tree | rg 'delta' | ForEach-Object { $_.Line })
        skipped = @(rg 'legacy' $Tree 3>&1 | ForEach-Object { "$_" })
        missing = @(rg 'x' (Join-Path $Tree 'nowhere') -ErrorAction SilentlyContinue)
    }
    Expect @($result.skipped | Where-Object { $_ -like '*skipped 1 legacy*' }).Count 1
    Expect $result.glob @('Alpha one', 'Alpha two')
    $result
}

Test-Case 'rg refuses a whole-share search' {
    $global:PSProfileRoots = @(@{ Unc = $Tree; Sep = '/'; Base = Join-Path $global:PSProfileDataDir $IndexName })
    $errors = @()
    $null = rg 'x' $Tree -ErrorVariable +errors -ErrorAction SilentlyContinue
    $global:PSProfileRoots = @()
    Expect @($errors).Count 1
    "$($errors[0])"
}

Test-Case 'rg shows matches for the host with the match line number' {
    Show-Host { Write-PSProfileMatchLine 'abc abc' ([regex]::Matches('abc abc', 'b')) }
}

Test-Case 'text is cut or padded to exactly the width and -End keeps the end' {
    Expect (Format-PSProfileFit 'abcdefghij' 6) 'abcd..'
    Expect (Format-PSProfileFit 'abcdefghij' 6 -End) '..ghij'
    Expect (Format-PSProfileFit "a`tb" 8) 'a    b  '
    Expect (Format-PSProfileFit "a`nb" 4) 'a b '
    $null = Get-Random -SetSeed 7
    foreach ($n in 1..200) {
        $width = Get-Random -Minimum 3 -Maximum 40
        $text = -join (1..(Get-Random -Minimum 0 -Maximum 60) | ForEach-Object { [char](Get-Random -Minimum 0 -Maximum 127) })
        Expect (Format-PSProfileFit $text $width).Length $width
        Expect (Format-PSProfileFit $text $width -End).Length $width
    }
}

Test-Case 'the preview shows a file with line numbers, a folder with items and the lines around a match' {
    $file = Join-Path $Tree 'a.txt'
    $result = [ordered]@{
        file    = @(Get-PSProfilePreview $file 2 | ForEach-Object { '{0}|{1}|{2}' -f $_.N, $_.Text, $_.Mark })
        folder  = @(Get-PSProfilePreview "$Tree/sub" 5 | ForEach-Object { $_.Text } | Sort-Object)
        match   = @(Get-PSProfilePreview (ConvertTo-Obj @{ Path = $file; LineNumber = 3; Line = 'gamma' }) 2 | ForEach-Object { '{0}|{1}|{2}' -f $_.N, $_.Text, $_.Mark })
        binary  = @(Get-PSProfilePreview (Join-Path $Tree 'bin.dat') 5 | ForEach-Object { $_.Text })
        missing = @(Get-PSProfilePreview (Join-Path $Tree 'nowhere') 5)
        other   = @(Get-PSProfilePreview (ConvertTo-Obj @{ Name = 'x' }) 5)
    }
    Expect $result.binary @('(binary file)')
    Expect $result.match @('2|beta|False', '3|gamma|True')
    $result
}

Test-Case 'fzf picks item N with #N, filters with text and treats a regex token as a regex' {
    $items = @('apple.txt', 'banana.txt', 'cherry.md', 'a b c')
    $result = [ordered]@{
        byNumber   = Use-Fzf @('#2') $items
        filter     = Use-Fzf @('chr', '#1') $items
        regex      = Use-Fzf @('md$', '#1') $items
        quit       = Use-Fzf @('') $items
        badRegex   = Use-Fzf @('(', '') $items
        outOfRange = Use-Fzf @('#9', '') $items
        object     = (Use-Fzf @('#1') @((ConvertTo-Obj @{ Display = 'shown'; Id = 7 }))).Id
        text       = (Use-Fzf @('#1') @((ConvertTo-Obj @{ Path = 'p'; LineNumber = 3; Line = 'l' }))).LineNumber
    }
    Expect $result.byNumber 'banana.txt'
    Expect $result.filter 'cherry.md'
    Expect $result.regex 'cherry.md'
    Expect $result.quit $null
    Expect $result.object 7
    $result
}

Test-Case 'the Myers diff gives the shortest edit and rebuilds the second list from the first' {
    $ops = @(Get-PSProfileDiff @('a', 'b', 'c') @('a', 'x', 'c'))
    Expect @($ops | ForEach-Object { $_.T }) @(' ', '-', '+', ' ')
    Expect @(Get-PSProfileDiff @() @('a')).Count 1
    Expect @(Get-PSProfileDiff @('a') @()).Count 1
    $null = Get-Random -SetSeed 11
    foreach ($n in 1..150) {
        $a = @(1..(Get-Random -Maximum 12) | ForEach-Object { [string](Get-Random -Maximum 4) })
        $b = @(1..(Get-Random -Maximum 12) | ForEach-Object { [string](Get-Random -Maximum 4) })
        $built = @(Get-PSProfileDiff $a $b | Where-Object { $_.T -ne '-' } | ForEach-Object { $b[$_.B] })
        Expect $built $b
        $kept = @(Get-PSProfileDiff $a $b | Where-Object { $_.T -ne '+' } | ForEach-Object { $a[$_.A] })
        Expect $kept $a
    }
}

Test-Case 'file lines come from text and Office files and a binary file is an error' {
    $word = Get-PSProfileFileLines (Join-Path $Tree 'f.docx')
    $text = Get-PSProfileFileLines (Join-Path $Tree 'a.txt')
    Expect $word @('Hello & world', "Second`tend")
    Expect $text @('alpha', 'beta', 'gamma')
    $message = ''
    try { $null = Get-PSProfileFileLines (Join-Path $Tree 'bin.dat') } catch { $message = $_.Exception.Message }
    Expect $message ("'" + (Join-Path $Tree 'bin.dat') + "' is a binary file.")
}

Test-Case 'delta gives a unified diff of two files when the output is piped' {
    Write-Fixture (Join-Path $WorkDir 'one.txt') "1`n2`n3`n4`n5`n6`n7`n8`n9`n10`n11`n12"
    Write-Fixture (Join-Path $WorkDir 'two.txt') "1`n2`nx`n4`n5`n6`n7`n8`n9`n10`n11`n12`n13"
    $same = @(delta (Join-Path $WorkDir 'one.txt') (Join-Path $WorkDir 'one.txt'))
    Expect $same @()
    @(delta (Join-Path $WorkDir 'one.txt') (Join-Path $WorkDir 'two.txt')) -replace [regex]::Escape($WorkDir), '<work>'
}

Test-Case 'delta shows the changed words for the host' {
    Show-Host { Write-PSProfileWordLine '-' @('a', ' ', 'b') @{ 2 = $true } 'DarkRed' 'Red' }
}

Test-Case 'bat gives plain lines when piped, honours a range and an Office file' {
    $result = [ordered]@{
        whole  = @(bat (Join-Path $Tree 'a.txt'))
        range  = @(bat (Join-Path $Tree 'a.txt') -Range 2-)
        upto   = @(bat (Join-Path $Tree 'a.txt') -Range -1)
        office = @(bat (Join-Path $Tree 'f.pptx'))
        piped  = @(Find-PSProfileFile -Ext md -Path $Tree | bat)
    }
    Expect $result.range @('beta', 'gamma')
    Expect $result.upto @('alpha')
    $result
}

Test-Case 'du gives sizes with the largest folder first and reads the index under a share root' {
    $scan = @(du $Tree -Depth 2 | ForEach-Object { '{0} {1}' -f $_.Size, $_.Path })
    $null = Invoke-Index
    $index = @(du $Tree -Depth 2 | ForEach-Object { '{0} {1}' -f $_.Size, $_.Path })
    Clear-Index
    Expect $index $scan
    Expect @(du $Tree -Depth 0).Count 1
    $scan
}

Test-Case 'rgi and br pick through the picker and open the file' {
    $global:Opened = @()
    function global:Invoke-Item { param($LiteralPath) $global:Opened += $LiteralPath }
    try {
        $global:FzfAnswers = @('#1')
        function global:Read-Host {
            $next = $global:FzfAnswers[0]
            $global:FzfAnswers = @($global:FzfAnswers | Select-Object -Skip 1)
            $next
        }
        rgi 'delta' $Tree 6>$null
        $global:FzfAnswers = @('#3', '#2')
        br $Tree 6>$null
    } finally {
        Remove-Item Function:\Invoke-Item, Function:\Read-Host
    }
    @($global:Opened)
}

Test-Case 'the z database keeps rank and time and orders matches by frecency' {
    $global:PSProfileZFile = Join-Path $Data 'z.txt'
    Remove-Item -LiteralPath $global:PSProfileZFile -Force -ErrorAction SilentlyContinue
    Add-PSProfileZ '/p/one'
    Add-PSProfileZ '/p/one'
    Add-PSProfileZ '/p/two'
    $db = Read-PSProfileZ
    Expect $db['/p/one'].Rank ([double]2)
    Expect $db['/p/two'].Rank ([double]1)
    $now = Get-PSProfileNow
    Save-PSProfileZ @{
        '/p/hour'  = @{ Rank = 1; Time = $now - 10 }
        '/p/day'   = @{ Rank = 3; Time = $now - 4000 }
        '/p/week'  = @{ Rank = 6; Time = $now - 100000 }
        '/p/month' = @{ Rank = 20; Time = $now - 10000000 }
    }
    $order = @(Get-PSProfileZ 'p')
    Expect $order @('/p/day', '/p/month', '/p/hour', '/p/week')
    Expect @(Get-PSProfileZ 'p', 'ay') @('/p/day')
    $order
}

Test-Case 'the z database halves old ranks above 9000 and drops ranks below 1' {
    $global:PSProfileZFile = Join-Path $Data 'z.txt'
    Save-PSProfileZ @{ '/big' = @{ Rank = 9000; Time = 1 }; '/tiny' = @{ Rank = 1; Time = 1 } }
    Add-PSProfileZ '/big'
    $db = Read-PSProfileZ
    Expect @($db.Keys) @('/big')
    '{0:0.00}' -f $db['/big'].Rank
}

Test-Case 'a jump raises the rank and a failed jump removes the dead entry' {
    $global:PSProfileZFile = Join-Path $Data 'z.txt'
    Save-PSProfileZ @{ $Tree = @{ Rank = 1; Time = 1 }; '/dead/folder' = @{ Rank = 1; Time = 1 } }
    $start = (Get-Location).ProviderPath
    try {
        Expect (Enter-PSProfileZ $Tree) $true
        Expect (Enter-PSProfileZ '/dead/folder' 3>$null) $false
    } finally { Set-Location -LiteralPath $start }
    $db = Read-PSProfileZ
    Expect $db[$Tree].Rank ([double]2)
    Expect $db.ContainsKey('/dead/folder') $false
}

Test-Case 'z jumps to the best match and warns when nothing matches' {
    $global:PSProfileZFile = Join-Path $Data 'z.txt'
    Save-PSProfileZ @{ "$Tree/sub" = @{ Rank = 1; Time = 1 } }
    $start = (Get-Location).ProviderPath
    try {
        z sub
        $at = (Get-Location).ProviderPath
        $warn = @(z nomatch 3>&1 | ForEach-Object { "$_" })
    } finally { Set-Location -LiteralPath $start }
    Expect $at "$Tree/sub"
    $warn
}

Test-Case 'the history is newest first with each command once and a backtick joins lines' {
    function global:Get-PSReadLineOption { ConvertTo-Obj @{ HistorySavePath = (Join-Path $WorkDir 'history.txt') } }
    try { $result = @(Get-PSProfileHistory) } finally { Remove-Item Function:\Get-PSReadLineOption }
    Expect $result @('echo hi', 'git status', "ls `nfoo")
}

Test-Case 'a tldr entry is the purpose, then examples in the form command  # what it does' {
    $list = @(tldr)
    foreach ($name in $global:PSProfileTldr.Keys) {
        foreach ($example in @($global:PSProfileTldr[$name] | Select-Object -Skip 1)) {
            Expect ($example -match '  # ') $true
        }
    }
    $message = ''
    try { tldr 'nothing' } catch { $message = $_.Exception.Message }
    Expect $message "tldr: no page for 'nothing'. Run tldr to see the list."
    [ordered]@{ list = $list; page = @(tldr 'fd'); error = $message }
}

Test-Case 'every profile command has a tldr page or is a helper' {
    $without = @('cd', 'ls', 'll', 'cpath', 'unc', 'cb', 'pb', 'wc', 'head', 'tail', 'which', 'touch', 'mkcd', 'up', '..', '...', 'open', 'ep', 'reload', 'zi', 'grep', 'prompt', 'fd')
    $missing = @('fd', 'recent', 'rg', 'rgi', 'fzf', 'br', 'bat', 'du', 'z', 'delta', 'Update-Index', 'tldr') | Where-Object { -not $global:PSProfileTldr.Contains($_) }
    Expect @($missing) @()
    $without
}

Test-Case 'the small Unix commands work on files and piped input' {
    $a = Join-Path $Tree 'a.txt'
    $start = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath $Tree
        mkcd (Join-Path $Tree 'new/er')
        $made = (Get-Location).ProviderPath
        up 2
        $upped = (Get-Location).ProviderPath
        touch (Join-Path $Tree 'touched')
        touch (Join-Path $Tree 'touched')
        ..
        $dots = (Get-Location).ProviderPath
    } finally { Set-Location -LiteralPath $start }
    Expect (Test-Path -LiteralPath (Join-Path $Tree 'touched')) $true
    Expect $made "$Tree/new/er"
    Expect $upped $Tree
    Remove-Item -LiteralPath (Join-Path $Tree 'touched'), (Join-Path $Tree 'new') -Recurse -Force
    [ordered]@{
        head  = @(head $a -n 2)
        tail  = @(tail $a -n 1)
        headp = @('1', '2', '3' | head -n 2)
        tailp = @('1', '2', '3' | tail -n 2)
        wc    = @(wc $a | ForEach-Object { '{0} {1} {2}' -f $_.Lines, $_.Words, $_.Chars })
        wcp   = @('a b', 'c' | wc | ForEach-Object { '{0} {1} {2}' -f $_.Lines, $_.Words, $_.Chars })
        which = @(which 'Get-Content'; which 'dir'; which 'bash' | ForEach-Object { Split-Path -Leaf $_ })
        dots  = $dots
    }
}

Test-Case 'cpath, unc and cb put text on the clipboard' {
    $global:Clip = @()
    function global:Set-Clipboard { param($Value) $global:Clip = @($Value) }
    try {
        $Tree | cpath
        $first = @($global:Clip)
        cpath
        $second = @($global:Clip)
        'a', 'b' | cb
        $third = @($global:Clip)
        (ConvertTo-Obj @{ X = 1 }) | cb
        $fourth = @($global:Clip)
    } finally { Remove-Item Function:\Set-Clipboard }
    Expect $first @($Tree)
    Expect $third @('a', 'b')
    Expect @(unc $Tree) @($Tree)
    @($first, $second.Count, $third, @($fourth | ForEach-Object { "$_" }))
}

Test-Case 'the listing shows the folder name, mode, time, size and name' {
    Show-Host { Show-PSProfileListing (Get-ChildItem -LiteralPath $Tree | Sort-Object Name) }
}

Test-Case 'ls and ll give items when piped' {
    $start = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath $Tree
        $ls = @(ls | ForEach-Object { $_.Name } | Sort-Object)
        $ll = @(ll | ForEach-Object { $_.Name } | Sort-Object)
    } finally { Set-Location -LiteralPath $start }
    Expect ($ll.Count -ge $ls.Count) $true
    [ordered]@{ ls = $ls; ll = $ll }
}

Test-Case 'the prompt shows the short folder and the index state' {
    $start = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath "$Tree/sub/deep"
        $text = Show-Host { prompt }
    } finally { Set-Location -LiteralPath $start }
    $text
}

Set-Content -LiteralPath $OutFile -Value $Outputs -Encoding utf8NoBOM
if ($Failures.Count) {
    Write-Output ("FAILED: " + ($Failures -join '; '))
    exit 1
}
Write-Output "ok: $($Outputs.Count) tests"
