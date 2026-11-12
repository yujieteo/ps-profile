$global:PSProfileVersion = '2.0.0'
$global:ShareRoots = @()

$global:PSProfileDataDir = Join-Path $env:LOCALAPPDATA 'ps-profile'
if (-not (Test-Path -LiteralPath $global:PSProfileDataDir)) {
    New-Item -ItemType Directory -Path $global:PSProfileDataDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath Variable:global:PSProfileIndexCache)) { $global:PSProfileIndexCache = @{} }
foreach ($name in 'PSProfileLastId', 'PSProfileLastPwd', 'PSProfileOldPwd', 'PSProfileGitDir') {
    if (-not (Test-Path -LiteralPath "Variable:global:$name")) { Set-Variable -Name $name -Scope Global -Value $null }
}
Remove-Variable name
$global:PSProfileSdUndoDir = Join-Path $global:PSProfileDataDir 'sd-undo'
$global:PSProfileRootsFile = Join-Path $global:PSProfileDataDir 'share-roots.txt'
if (Test-Path -LiteralPath $global:PSProfileRootsFile) {
    $global:ShareRoots += @(Get-Content -LiteralPath $global:PSProfileRootsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    $global:PSProfileByteArgs = @{ Encoding = 'Byte' }
    $global:PSProfileAnsi = 'Default'
    $global:PSProfileUtf8Bom = 'UTF8'
    $global:PSDefaultParameterValues['Out-File:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Set-Content:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Add-Content:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Export-Csv:Encoding'] = 'UTF8'
} else {
    $global:PSProfileByteArgs = @{ AsByteStream = $true }
    $global:PSProfileAnsi = 1252
    $global:PSProfileUtf8Bom = 'utf8BOM'
    $global:PSDefaultParameterValues['Out-File:Encoding'] = 'utf8NoBOM'
    $global:PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8NoBOM'
    $global:PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8NoBOM'
    $global:PSDefaultParameterValues['Export-Csv:Encoding'] = 'utf8BOM'
}

function global:Test-PSProfileToHost {
    [OutputType([bool])]
    param($Invocation)
    $Invocation.CommandOrigin -eq 'Runspace' -and
    $Invocation.PipelinePosition -eq $Invocation.PipelineLength -and
    $Invocation.Line.Substring(0, $Invocation.OffsetInLine - 1) -notmatch '[=(]\s*$'
}

function global:Get-PSProfileProperty($Item, [string]$Name) {
    if ($null -eq $Item) { return }
    if ($Item -is [hashtable]) { return $Item[$Name] }
    $property = $Item.PSObject.Properties[$Name]
    if ($property) { $property.Value }
}

function global:Test-PSProfileUpper {
    [OutputType([bool])]
    param([string]$Pattern)
    ($Pattern -creplace '\\.', '') -cmatch '\p{Lu}'
}

function global:ConvertTo-PSProfileQuoted {
    [OutputType([string])]
    param([string]$Text)
    if ($Text -match "[\s'`$&()\[\]{};,@#]") { return "'" + ($Text -replace "'", "''") + "'" }
    $Text
}

function global:Get-PSProfileFullPath {
    [OutputType([string])]
    param([string]$Path)
    if (-not $Path) { $Path = '.' }
    $r = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { return $r.ProviderPath }
    $Path
}

function global:ConvertTo-PSProfileUnc {
    [OutputType([string])]
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):(.*)$') {
        $rest = $Matches[2]
        $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($d -and $d.DisplayRoot -like '\\*') { return $d.DisplayRoot.TrimEnd('\') + $rest }
    }
    $Path
}

function global:Get-PSProfileItemPath($Item) {
    if ($Item -is [string]) { return $Item }
    $full = Get-PSProfileProperty $Item 'FullName'
    if ($full) { return $full }
    $path = Get-PSProfileProperty $Item 'Path'
    if ($path) { return $path }
    "$Item"
}

function global:Read-PSProfileEncoded {
    [OutputType([hashtable])]
    param([string]$Path)
    $byteArgs = $global:PSProfileByteArgs
    $b = Get-Content -LiteralPath $Path -TotalCount 1024 -ReadCount 0 @byteArgs -ErrorAction SilentlyContinue
    if ($null -eq $b) { $b = @() } elseif ($b -isnot [array]) { $b = @($b) }
    $enc = 'UTF8'
    $bom = $false
    if ($b.Count -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = 'Unicode'; $bom = $true }
    elseif ($b.Count -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $enc = 'BigEndianUnicode'; $bom = $true }
    elseif ($b.Count -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bom = $true }
    if ($enc -eq 'UTF8' -and $b -contains 0) { return @{ Text = $null; Enc = $enc; Bom = $bom } }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding $enc -ErrorAction SilentlyContinue
    if ($null -eq $text) { return @{ Text = ''; Enc = $enc; Bom = $bom } }
    if ($enc -eq 'UTF8' -and $text.IndexOf([char]0xFFFD) -ge 0) {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding $global:PSProfileAnsi
        $enc = $global:PSProfileAnsi
        $bom = $false
    }
    if ($text.IndexOf([char]0) -ge 0) { $text = $null }
    @{ Text = $text; Enc = $enc; Bom = $bom }
}

function global:Read-PSProfileText {
    [OutputType([string])]
    param([string]$Path)
    (Read-PSProfileEncoded $Path).Text
}

function global:Split-PSProfileLines([string]$Text) {
    $lines = $Text -split '\r?\n'
    if ($lines.Count -gt 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    , $lines
}

function global:ConvertFrom-PSProfileXmlText {
    [OutputType([string])]
    param([string]$s)
    $s -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&apos;', "'" -replace '&amp;', '&'
}

function global:Get-PSProfileXmlAttr {
    [OutputType([string])]
    param([string]$Tag, [string]$Name)
    if ($Tag -match ('(?:^|\s)' + [regex]::Escape($Name) + '="([^"]*)"')) { return $Matches[1] }
    ''
}

function global:Get-PSProfileRels {
    [OutputType([hashtable])]
    param([string]$File)
    $map = @{}
    if (Test-Path -LiteralPath $File) {
        $xml = Get-Content -LiteralPath $File -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($xml, '<Relationship\b[^>]*>')) {
            $map[(Get-PSProfileXmlAttr $m.Value 'Id')] = Get-PSProfileXmlAttr $m.Value 'Target'
        }
    }
    $map
}

function global:Join-PSProfilePart {
    [OutputType([string])]
    param([string]$Dir, [string]$Base, [string]$Target)
    if ($Target.StartsWith('/')) { return Join-Path $Dir $Target.TrimStart('/') }
    Join-Path (Join-Path $Dir $Base) $Target
}

function global:Get-PSProfileRunText {
    [OutputType([string])]
    param([string]$Xml)
    $parts = foreach ($m in [regex]::Matches($Xml, '<(?:w|a):t(?:\s[^>]*)?>([^<]*)</(?:w|a):t>|<w:tab/>')) {
        if ($m.Value -eq '<w:tab/>') { "`t" } else { $m.Groups[1].Value }
    }
    ConvertFrom-PSProfileXmlText (@($parts) -join '')
}

function global:ConvertFrom-PSProfileOffice([string]$Path) {
    $ext = ([regex]::Match($Path, '\.[^.\\/]*$').Value).ToLower()
    $ProgressPreference = 'SilentlyContinue'
    $tmp = Join-Path $env:TEMP ('ps-profile-' + (Get-Random))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp 'file.zip'
        Copy-Item -LiteralPath $Path -Destination $zip
        $x = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
        if ($ext -eq '.docx') {
            $xml = Get-Content -LiteralPath (Join-Path $x 'word/document.xml') -Raw -Encoding UTF8
            foreach ($p in [regex]::Matches($xml, '(?s)<w:p[ >].*?</w:p>')) {
                $t = Get-PSProfileRunText $p.Value
                if ($t.Trim()) { $t }
            }
        } elseif ($ext -eq '.xlsx') {
            $ss = @()
            $ssFile = Join-Path $x 'xl/sharedStrings.xml'
            if (Test-Path -LiteralPath $ssFile) {
                $xml = Get-Content -LiteralPath $ssFile -Raw -Encoding UTF8
                $ss = @(foreach ($si in [regex]::Matches($xml, '(?s)<si>(.*?)</si>')) {
                    $t = foreach ($m in [regex]::Matches($si.Groups[1].Value, '<t(?:\s[^>]*)?>([^<]*)</t>')) { $m.Groups[1].Value }
                    ConvertFrom-PSProfileXmlText (@($t) -join '')
                })
            }
            $rels = Get-PSProfileRels (Join-Path $x 'xl/_rels/workbook.xml.rels')
            $wb = Get-Content -LiteralPath (Join-Path $x 'xl/workbook.xml') -Raw -Encoding UTF8
            foreach ($s in [regex]::Matches($wb, '<sheet\b[^>]*>')) {
                $name = ConvertFrom-PSProfileXmlText (Get-PSProfileXmlAttr $s.Value 'name')
                $file = Join-PSProfilePart $x 'xl' $rels[(Get-PSProfileXmlAttr $s.Value 'r:id')]
                $xml = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                foreach ($c in [regex]::Matches($xml, '(?s)<c\b([^>]*?)(?:/>|>(.*?)</c>)')) {
                    $body = $c.Groups[2].Value
                    if (-not $body) { continue }
                    $type = Get-PSProfileXmlAttr $c.Groups[1].Value 't'
                    $v = ''
                    if ($body -match '<v>([^<]*)</v>') { $v = ConvertFrom-PSProfileXmlText $Matches[1] }
                    if ($type -eq 's') { $v = $ss[[int]$v] }
                    elseif ($type -eq 'inlineStr') {
                        $t = foreach ($m in [regex]::Matches($body, '<t(?:\s[^>]*)?>([^<]*)</t>')) { $m.Groups[1].Value }
                        $v = ConvertFrom-PSProfileXmlText (@($t) -join '')
                    } elseif ($type -eq 'b') { if ($v -eq '1') { $v = 'TRUE' } else { $v = 'FALSE' } }
                    if ($v -ne '') { '{0}!{1}: {2}' -f $name, (Get-PSProfileXmlAttr $c.Groups[1].Value 'r'), ($v -replace '\r?\n', ' ') }
                }
            }
        } elseif ($ext -eq '.pptx') {
            $rels = Get-PSProfileRels (Join-Path $x 'ppt/_rels/presentation.xml.rels')
            $pres = Get-Content -LiteralPath (Join-Path $x 'ppt/presentation.xml') -Raw -Encoding UTF8
            $n = 0
            foreach ($s in [regex]::Matches($pres, '<p:sldId\b[^>]*>')) {
                $n++
                $file = Join-PSProfilePart $x 'ppt' $rels[(Get-PSProfileXmlAttr $s.Value 'r:id')]
                $xml = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                $shapes = $xml -split '<p:cNvPr\b'
                for ($i = 1; $i -lt $shapes.Count; $i++) {
                    $name = ConvertFrom-PSProfileXmlText (Get-PSProfileXmlAttr ($shapes[$i] -replace '>.*', '') 'name')
                    $paras = foreach ($p in ($shapes[$i] -split '</a:p>')) {
                        $t = Get-PSProfileRunText $p
                        if ($t.Trim()) { $t }
                    }
                    if ($paras) { 'Slide {0} / {1}: {2}' -f $n, $name, (@($paras) -join ' / ') }
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function global:ConvertTo-PSProfileRoot {
    [OutputType([hashtable])]
    param([object[]]$ShareRoots)
    foreach ($r in $ShareRoots) {
        if ($r -isnot [string] -or -not $r.Trim()) {
            Write-Warning ("`$ShareRoots: '{0}' is not a folder path. Use a UNC path or a mapped drive folder, for example 'S:\Finance'." -f $r)
            continue
        }
        $unc = ConvertTo-PSProfileUnc ($r.TrimEnd('\', '/'))
        if ($unc -match '^[A-Za-z]:') {
            Write-Warning ("`$ShareRoots: '{0}' is not on a mapped network drive, so the index uses the path as typed. Example of a mapped drive folder: 'S:\Finance'." -f $r)
        }
        $sep = '\'
        if ($unc.StartsWith('/')) { $sep = '/' }
        @{
            Unc  = $unc
            Sep  = $sep
            Base = Join-Path $global:PSProfileDataDir ('idx2_' + ($unc -replace '[^A-Za-z0-9]+', '_'))
        }
    }
}

$global:PSProfileRoots = @(ConvertTo-PSProfileRoot $global:ShareRoots)

$global:PSProfileIndexBuilder = {
    param([string]$RootList, [string]$DataDir, [string]$Start, [int]$PauseMs, [int]$MaxAgeHours)
    $saveIntervalSeconds = 120
    $lock = Join-Path $DataDir 'index.lock'
    if (Test-Path -LiteralPath $lock) {
        $owner = Get-Content -LiteralPath $lock -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -match '^\d+$' -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
            Write-Warning 'An index build is already running in another window.'
            return
        }
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
    try { New-Item -ItemType File -Path $lock -Value "$PID" -ErrorAction Stop | Out-Null }
    catch { Write-Warning 'An index build is already running in another window.'; return }
    try {
        foreach ($root in ($RootList -split "`n")) {
            if (-not $root) { continue }
            $sep = '\'
            if ($root.StartsWith('/')) { $sep = '/' }
            $base = Join-Path $DataDir ('idx2_' + ($root -replace '[^A-Za-z0-9]+', '_'))
            if ($MaxAgeHours -gt 0) {
                $i = Get-Item -LiteralPath "$base.idx" -ErrorAction SilentlyContinue
                if ($i -and -not (Test-Path -LiteralPath "$base.partial") -and $i.LastWriteTime -gt (Get-Date).AddHours(-$MaxAgeHours)) { continue }
            }
            $from = $root
            if ($Start) { $from = $Start }
            if (-not (Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue)) {
                Write-Warning "Index: '$from' is not reachable. The old index stays."
                continue
            }
            $fromLower = $from.ToLower()
            $prefixLower = $fromLower + $sep

            $old = @{}
            if (Test-Path -LiteralPath "$base.state") {
                foreach ($line in (Get-Content -LiteralPath "$base.state" -Encoding UTF8 -ReadCount 0)) {
                    $old[$line.Split("`t")[1]] = $line
                }
            }

            $save = {
                param($New, $Visited)
                $keep = foreach ($k in $old.Keys) {
                    $kl = $k.ToLower()
                    if ($Visited) {
                        if (-not $Visited.ContainsKey($k)) { $old[$k] }
                    } elseif ($kl -ne $fromLower -and -not $kl.StartsWith($prefixLower)) { $old[$k] }
                }
                $all = @($keep) + @(for ($q = 0; $q -lt $New.Count; $q++) { $New[$q] })
                Set-Content -LiteralPath "$base.state.tmp" -Value $all -Encoding UTF8
                Move-Item -LiteralPath "$base.state.tmp" -Destination "$base.state" -Force
                $paths = foreach ($line in $all) {
                    $f = $line.Split("`t")
                    "`t`t" + $f[1]
                    if ($f[2]) {
                        $n = $f[2].Split('|')
                        for ($j = 0; $j + 2 -lt $n.Count; $j += 3) { $n[$j + 2] + "`t" + $n[$j + 1] + "`t" + $f[1] + $sep + $n[$j] }
                    }
                }
                Set-Content -LiteralPath "$base.idx.tmp" -Value $paths -Encoding UTF8
                Move-Item -LiteralPath "$base.idx.tmp" -Destination "$base.idx" -Force
            }
            Set-Content -LiteralPath "$base.partial" -Value 'partial' -Encoding UTF8
            $nextSave = (Get-Date).AddSeconds($saveIntervalSeconds)

            $queue = @{}
            $head = 0
            $tail = 0
            $queue[$tail++] = $from
            $done = @{}
            $new = @{}
            while ($head -lt $tail) {
                $dir = $queue[$head]
                $queue.Remove($head)
                $head++
                if ($PauseMs) { Start-Sleep -Milliseconds $PauseMs }
                if ((Get-Date) -gt $nextSave) {
                    & $save $new $done
                    $nextSave = (Get-Date).AddSeconds($saveIntervalSeconds)
                }
                $line = $old[$dir]
                $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                $failed = -not $item
                if ($item) {
                    $ticks = '' + $item.LastWriteTimeUtc.Ticks
                    if (-not $line -or $line.Split("`t")[0] -ne $ticks) {
                        $kids = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable listErr)
                        if ($listErr.Count -and $line) { $failed = $true }
                        else {
                            $files = @(foreach ($k in $kids) {
                                if (-not $k.PSIsContainer) { $k.Name + '|' + $k.Length + '|' + $k.LastWriteTimeUtc.Ticks }
                            }) -join '|'
                            $subs = @(foreach ($k in $kids) {
                                if ($k.PSIsContainer -and -not ([int]$k.Attributes -band 1024)) { $k.Name }
                            }) -join '|'
                            $line = "$ticks`t$dir`t$files`t$subs"
                        }
                    }
                }
                if ($failed) {
                    Write-Verbose "Index: '$dir' is not reachable. Its old lines and the old lines below it stay."
                    $dirLower = $dir.ToLower()
                    foreach ($k in @($old.Keys)) {
                        $kl = $k.ToLower()
                        if ($kl -eq $dirLower -or $kl.StartsWith($dirLower + $sep)) { $new[$new.Count] = $old[$k]; $done[$k] = $true }
                    }
                    continue
                }
                $new[$new.Count] = $line
                $done[$dir] = $true
                $subs = $line.Split("`t")[3]
                if ($subs) { foreach ($s in $subs.Split('|')) { $queue[$tail++] = $dir + $sep + $s } }
            }

            & $save $new $null
            Remove-Item -LiteralPath "$base.partial" -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

function global:Find-PSProfileRoot([string]$Unc) {
    $u = $Unc.ToLower()
    foreach ($r in $global:PSProfileRoots) {
        $ru = $r.Unc.ToLower()
        if ($u -eq $ru -or $u.StartsWith($ru + $r.Sep)) { return $r }
    }
}

function global:Get-PSProfileIndexState {
    [OutputType([string])]
    param()
    if (-not $global:PSProfileRoots.Count) { return '' }
    $lock = Join-Path $global:PSProfileDataDir 'index.lock'
    if (Test-Path -LiteralPath $lock) {
        $owner = Get-Content -LiteralPath $lock -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -match '^\d+$' -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { return 'building' }
    }
    $limit = (Get-Date).AddHours(-24)
    foreach ($r in $global:PSProfileRoots) {
        $i = Get-Item -LiteralPath "$($r.Base).idx" -ErrorAction SilentlyContinue
        if (-not $i -or $i.LastWriteTime -lt $limit -or (Test-Path -LiteralPath "$($r.Base).partial")) { return 'old' }
    }
    ''
}

function global:Get-PSProfileIndex([hashtable]$Root) {
    $i = Get-Item -LiteralPath "$($Root.Base).idx" -ErrorAction SilentlyContinue
    if (-not $i) { return $null }
    $c = $global:PSProfileIndexCache[$Root.Unc]
    if (-not $c -or $c.Time -ne $i.LastWriteTime) {
        $c = @{ Time = $i.LastWriteTime; Lines = (Get-Content -LiteralPath $i.FullName -Encoding UTF8 -ReadCount 0) }
        $global:PSProfileIndexCache[$Root.Unc] = $c
    }
    , $c.Lines
}

function global:Update-Index {
    param([Parameter(Position = 0)][string]$Path)
    $roots = @($global:PSProfileRoots | ForEach-Object { $_.Unc })
    $start = ''
    if ($Path) {
        $unc = ConvertTo-PSProfileUnc (Get-PSProfileFullPath $Path)
        $root = Find-PSProfileRoot $unc
        if (-not $root) { Write-Error "Update-Index: '$Path' is not under a root in `$ShareRoots."; return }
        $roots = @($root.Unc)
        $start = $unc.TrimEnd($root.Sep)
    }
    if (-not $roots.Count) { Write-Warning 'Update-Index: $ShareRoots is empty.'; return }
    & $global:PSProfileIndexBuilder ($roots -join "`n") $global:PSProfileDataDir $start 0 0
}

function global:ConvertTo-PSProfileIgnoreRule([string]$Line, [string]$Base, [string]$File) {
    $t = $Line.TrimEnd()
    if (-not $t -or $t.StartsWith('#')) { return }
    $negate = $t.StartsWith('!')
    if ($negate) { $t = $t.Substring(1) }
    $dirOnly = $t.EndsWith('/')
    $t = $t.TrimEnd('/')
    if (-not $t) { return }
    $anchored = $t.Contains('/')
    $t = $t.TrimStart('/')
    $valid = $true
    $skipSlash = $false
    $parts = foreach ($m in [regex]::Matches($t, '\\.|\\$|\*+|\?|\[[!^]?\]?(?:\\.|[^\]\\])*\]|\[|/|[^\\*?\[/]+')) {
        $v = $m.Value
        if ($skipSlash) {
            $skipSlash = $false
            if ($v -eq '/') { continue }
        }
        if ($v.StartsWith('\')) {
            if ($v.Length -eq 1) { $valid = $false } else { [regex]::Escape($v.Substring(1)) }
        } elseif ($v.StartsWith('*')) {
            $end = $m.Index + $v.Length
            $open = $m.Index -eq 0 -or $t.Substring($m.Index - 1, 1) -eq '/'
            if ($v.Length -eq 1 -or -not $open) { '[^/]*' }
            elseif ($end -eq $t.Length) { '.*' }
            elseif ($t.Substring($end, 1) -eq '/') { '(?:.*/)?'; $skipSlash = $true }
            else { '[^/]*' }
        } elseif ($v -eq '?') { '[^/]' }
        elseif ($v.Length -gt 1 -and $v.StartsWith('[')) {
            $body = $v.Substring(1, $v.Length - 2)
            $not = ''
            if ($body.StartsWith('!') -or $body.StartsWith('^')) { $not = '^/'; $body = $body.Substring(1) }
            $set = foreach ($c in [regex]::Matches($body, '\\.|.')) {
                $x = $c.Value
                if ($x.Length -eq 2) {
                    $x = $x.Substring(1)
                    if ('\]^[-'.Contains($x)) { '\' + $x } else { $x }
                } elseif ('\]^['.Contains($x)) { '\' + $x }
                else { $x }
            }
            '[' + $not + (@($set) -join '') + ']'
        } else { [regex]::Escape($v) }
    }
    $prefix = '(?i)(?:^|/)'
    if ($anchored) { $prefix = '(?i)^' }
    $rx = $prefix + (@($parts) -join '') + '$'
    if ($valid) { try { $null = '' -match $rx } catch { $valid = $false } }
    if (-not $valid) {
        $where = ''
        if ($File) { $where = " in '$File'" }
        Write-Warning "The pattern '$($Line.TrimEnd())'$where is not valid. The profile does not use it."
        return
    }
    @{ Base = $Base; Rx = $rx; Negate = [bool]$negate; DirOnly = [bool]$dirOnly }
}

function global:Get-PSProfileIgnoreFile([string]$File, [string]$Base) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return }
    foreach ($line in @(Get-Content -LiteralPath $File -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        ConvertTo-PSProfileIgnoreRule $line $Base $File
    }
}

function global:Test-PSProfileGlob {
    [OutputType([bool])]
    param([string]$Rel, [object[]]$Rules)
    $keep = $true
    foreach ($r in $Rules) { if (-not $r.Negate) { $keep = $false; break } }
    foreach ($r in $Rules) { if ($Rel -match $r.Rx) { $keep = -not $r.Negate } }
    $keep
}

function global:Get-PSProfileRepoRules([string]$Root) {
    $above = @()
    $dir = $Root
    $top = ''
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $top = $dir; break }
        $dir = Split-Path -Parent $dir
        if ($dir) { $above = @($dir) + $above }
    }
    if (-not $top) { return @{ InRepo = $false; Rules = @() } }
    $rules = @(Get-PSProfileIgnoreFile (Join-Path (Join-Path (Join-Path $top '.git') 'info') 'exclude') $top)
    foreach ($d in $above) { $rules += @(Get-PSProfileIgnoreFile (Join-Path $d '.gitignore') $d) }
    @{ InRepo = $true; Rules = $rules }
}

function global:Test-PSProfileIgnored {
    [OutputType([bool])]
    param([string]$FullName, [bool]$IsDir, [object[]]$Rules)
    $ignored = $false
    $base = $null
    $rel = ''
    foreach ($r in $Rules) {
        if ($ignored -ne $r.Negate) { continue }
        if ($r.DirOnly -and -not $IsDir) { continue }
        if ($r.Base -cne $base) {
            $base = $r.Base
            $rel = $FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        }
        if ($rel -match $r.Rx) { $ignored = -not $r.Negate }
    }
    $ignored
}

function global:Get-PSProfileTree {
    param([string]$Root, [switch]$SkipHidden, [switch]$UseIgnore)
    $repo = @{ InRepo = $false; Rules = @() }
    if ($UseIgnore) { $repo = Get-PSProfileRepoRules $Root }
    $queue = @{}
    $head = 0
    $tail = 0
    $queue[$tail++] = @{ Dir = $Root; Rules = $repo.Rules }
    while ($head -lt $tail) {
        $entry = $queue[$head]
        $queue.Remove($head)
        $head++
        $kids = @(Get-ChildItem -LiteralPath $entry.Dir -Force -ErrorAction SilentlyContinue)
        $rules = @($entry.Rules)
        if ($repo.InRepo) {
            $own = $null
            foreach ($k in $kids) {
                if ($k.Name -eq '.gitignore' -and -not ([int]$k.Attributes -band 16)) { $own = $k }
                elseif ($k.Name -eq '.git' -and $head -gt 1) {
                    $rules = @(Get-PSProfileIgnoreFile (Join-Path (Join-Path $k.FullName 'info') 'exclude') $entry.Dir)
                }
            }
            if ($own) { $rules += @(Get-PSProfileIgnoreFile $own.FullName $entry.Dir) }
        }
        foreach ($k in $kids) {
            $attr = [int]$k.Attributes
            if ($SkipHidden -and ($k.Name.StartsWith('.') -or ($attr -band 2))) { continue }
            $isDir = [bool]($attr -band 16)
            if ($repo.InRepo) {
                if ($k.Name -eq '.git') { continue }
                if ($rules.Count -and (Test-PSProfileIgnored $k.FullName $isDir $rules)) { continue }
            }
            $k
            if ($isDir -and -not ($attr -band 1024)) { $queue[$tail++] = @{ Dir = $k.FullName; Rules = $rules } }
        }
    }
}

function global:Find-PSProfileFile {
    [CmdletBinding()]
    param(
        [string]$Pattern = '.',
        [string]$Path = '.',
        [string[]]$Ext,
        [string]$Changed,
        [string]$Size,
        [string]$Type,
        [switch]$SkipHidden,
        [switch]$SmartCase,
        [switch]$UseIgnore,
        [switch]$Meta,
        [int]$Limit = 0
    )
    $filter = $Ext -or $Changed -or $Size
    $onlyDirs = $Type -like 'd*'
    $onlyFiles = $filter -or $Type -like 'f*'
    $caseSensitive = $SmartCase -and (Test-PSProfileUpper $Pattern)
    $hiddenRx = '(?:^|[\\/])\.'
    $extRx = ''
    if ($Ext) { $extRx = '\.(?:' + ((@($Ext) | ForEach-Object { [regex]::Escape($_.TrimStart('.')) }) -join '|') + ')$' }
    $since = ''
    if ($Changed) {
        if ($Changed -notmatch '^(\d+)d?$') { Write-Error "fd: -Changed '$Changed' is not valid. Use days, for example 30d."; return }
        $since = '' + (Get-Date).ToUniversalTime().AddDays(- [int]$Matches[1]).Ticks
    }
    $min = -1
    $max = -1
    if ($Size) {
        if ($Size -notmatch '^([+-]?)(\d+(?:\.\d+)?)(B|KB|MB|GB)?$') { Write-Error "fd: -Size '$Size' is not valid. Use for example +1MB or -10KB."; return }
        $unit = @{ '' = 1; 'B' = 1; 'KB' = 1KB; 'MB' = 1MB; 'GB' = 1GB }[('' + $Matches[3]).ToUpper()]
        $bytes = [double]$Matches[2] * $unit
        if ($Matches[1] -eq '-') { $max = $bytes } else { $min = $bytes }
    }
    $typed = Get-PSProfileFullPath $Path
    $unc = ConvertTo-PSProfileUnc $typed
    $root = Find-PSProfileRoot $unc
    if (-not $root) {
        $take = [int]::MaxValue
        if ($Limit -gt 0) { $take = $Limit }
        $scan = @(if ($UseIgnore) {
            Get-PSProfileTree $typed -SkipHidden:$SkipHidden -UseIgnore | Where-Object { $isDir = [int]$_.Attributes -band 16; -not ($onlyFiles -and $isDir) -and -not ($onlyDirs -and -not $isDir) } | Select-Object -First $take
        } else {
            Get-ChildItem -LiteralPath $typed -Recurse -Force:(-not $SkipHidden) -File:$onlyFiles -Directory:$onlyDirs -ErrorAction SilentlyContinue | Select-Object -First $take
        })
        $scanLength = $typed.TrimEnd('\', '/').Length
        if ($Limit -gt 0 -and $scan.Count -ge $Limit) { Write-Warning "fd: stopped after $Limit items. Give a smaller folder." }
        foreach ($i in $scan) {
            if ($i.Name -notmatch $Pattern) { continue }
            if ($caseSensitive -and $i.Name -cnotmatch $Pattern) { continue }
            if ($SkipHidden -and $i.FullName.Substring($scanLength) -match $hiddenRx) { continue }
            if ($extRx -and $i.Name -notmatch $extRx) { continue }
            if ($since -and $i.LastWriteTimeUtc.Ticks -lt [long]$since) { continue }
            if ($min -ge 0 -and $i.Length -lt $min) { continue }
            if ($max -ge 0 -and $i.Length -gt $max) { continue }
            if (-not $Meta) { $i.FullName }
            elseif ([int]$i.Attributes -band 16) { "`t`t" + $i.FullName }
            else { '{0}{1}{2}{1}{3}' -f $i.LastWriteTimeUtc.Ticks, "`t", $i.Length, $i.FullName }
        }
        return
    }
    $lines = Get-PSProfileIndex $root
    if ($null -eq $lines) { Write-Warning "fd: no index yet for $($root.Unc). Run Update-Index."; return }
    $sep = $root.Sep
    $uncPrefix = $unc.TrimEnd($sep) + $sep
    $typedPrefix = $typed.TrimEnd('\', '/') + $sep
    $full = $Pattern
    if ($full.StartsWith('^')) { $full = '(?:^|[\\/])' + $full.Substring(1) }
    $hits = @($lines)
    if ($full -ne '.') { $hits = $hits -match $full }
    $hits = $hits -like ("*`t" + ($uncPrefix -replace '([\[\]\*\?`])', '`$1') + '*')
    if ($extRx) { $hits = $hits -match $extRx }
    if ($since) { $hits = $hits -ge $since }
    foreach ($h in $hits) {
        $f = $h.Split("`t")
        $leaf = $f[2].Substring($f[2].LastIndexOf($sep) + 1)
        if ($leaf -notmatch $Pattern) { continue }
        if ($caseSensitive -and $leaf -cnotmatch $Pattern) { continue }
        if ($SkipHidden -and $f[2].Substring($uncPrefix.Length) -match $hiddenRx) { continue }
        if ($onlyFiles -and -not $f[1]) { continue }
        if ($onlyDirs -and $f[1]) { continue }
        if ($min -ge 0 -and [long]$f[1] -lt $min) { continue }
        if ($max -ge 0 -and [long]$f[1] -gt $max) { continue }
        $p = $typedPrefix + $f[2].Substring($uncPrefix.Length)
        if ($Meta) { $f[0] + "`t" + $f[1] + "`t" + $p } else { $p }
    }
}

function global:fd {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Pattern = '.',
        [Parameter(Position = 1)][string]$Path = '.',
        [Alias('e')][string[]]$Ext,
        [string]$Changed,
        [string]$Size,
        [Alias('t')][ValidateSet('f', 'd', 'file', 'directory')][string]$Type,
        [Alias('H')][switch]$Hidden,
        [Alias('I')][switch]$NoIgnore
    )
    $toHost = Test-PSProfileToHost $MyInvocation
    $a = @{ Pattern = $Pattern; Path = $Path; Ext = $Ext; Changed = $Changed; Size = $Size; Type = $Type; SkipHidden = (-not $Hidden); SmartCase = $true; UseIgnore = (-not $NoIgnore) }
    if (-not $toHost) { Find-PSProfileFile @a; return }
    Find-PSProfileFile @a -Meta | ForEach-Object {
        $f = $_.Split("`t")
        Write-PSProfilePath $f[2] (-not $f[1])
    }
}

function global:Write-PSProfilePath([string]$Path, [bool]$IsDir) {
    $at = $Path.LastIndexOf('\')
    if ($Path.LastIndexOf('/') -gt $at) { $at = $Path.LastIndexOf('/') }
    $leaf = $Path.Substring($at + 1)
    if ($at -ge 0) { Write-Host $Path.Substring(0, $at + 1) -ForegroundColor DarkGray -NoNewline }
    $ext = [regex]::Match($leaf, '\.[^.]*$').Value.ToLower()
    $c = 'Gray'
    if ($IsDir) { $c = 'Cyan' }
    elseif ($global:PSProfileColors.ContainsKey($ext)) { $c = $global:PSProfileColors[$ext] }
    Write-Host $leaf -ForegroundColor $c
}

function global:Format-PSProfileSize {
    [OutputType([string])]
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:0.0} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0.0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:0.0} KB' -f ($Bytes / 1KB) }
    '{0} B' -f $Bytes
}

function global:recent {
    param(
        [Parameter(Position = 0)][string]$Path = '.',
        [int]$Days = 7,
        [int]$Count = 20
    )
    $toHost = Test-PSProfileToHost $MyInvocation
    $lines = @(Find-PSProfileFile -Path $Path -Changed "${Days}d" -SkipHidden -UseIgnore -Meta | Sort-Object -Descending | Select-Object -First $Count)
    foreach ($l in $lines) {
        $f = $l.Split("`t")
        if (-not $toHost) { $f[2]; continue }
        $t = (New-Object DateTime ([long]$f[0]), 'Utc').ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Write-Host ('{0}  {1,10}  ' -f $t, (Format-PSProfileSize $f[1])) -ForegroundColor DarkGray -NoNewline
        Write-PSProfilePath $f[2] $false
    }
}

function global:Write-PSProfileMatchLine([string]$Line, $Matches_) {
    $pos = 0
    foreach ($m in $Matches_) {
        if ($m.Length -eq 0) { continue }
        if ($m.Index -gt $pos) { Write-Host $Line.Substring($pos, $m.Index - $pos) -NoNewline }
        Write-Host $m.Value -ForegroundColor Red -NoNewline
        $pos = $m.Index + $m.Length
    }
    Write-Host $Line.Substring($pos)
}

function global:Test-PSProfilePipedPath {
    [OutputType([bool])]
    param([string]$Text)
    if ($Text -notmatch '^(?:[A-Za-z]:[\\/]|\\\\|/)') { return $false }
    try { return (Test-Path -LiteralPath $Text -ErrorAction Stop) } catch { return $false }
}

function global:rg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
        [Parameter(Position = 1, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')][string[]]$Path,
        [Alias('i')][switch]$IgnoreCase,
        [Alias('F')][switch]$SimpleMatch,
        [Alias('g')][string[]]$Glob,
        [Alias('C')][int]$Context = 0,
        [Alias('A')][int]$After = -1,
        [Alias('B')][int]$Before = -1,
        [Alias('l')][switch]$FilesWithMatches,
        [Alias('v')][switch]$InvertMatch,
        [Alias('w')][switch]$Word,
        [Alias('n')][switch]$LineNumber,
        [Alias('s')][switch]$CaseSensitive,
        [Alias('u')][switch]$NoIgnore,
        [switch]$Hidden,
        [int]$MaxSizeMB = 20,
        [switch]$Office
    )
    begin {
        $toHost = Test-PSProfileToHost $MyInvocation
        $rx = $Pattern
        if ($SimpleMatch) { $rx = [regex]::Escape($Pattern) }
        if ($Word) { $rx = '\b(?:' + $rx + ')\b' }
        $invalid = $false
        try { $null = '' -match $rx } catch {
            $invalid = $true
            Write-Error "rg: '$Pattern' is not a valid pattern. Use -F for plain text."
        }
        $globRules = @(foreach ($g in $Glob) { if ($g) { ConvertTo-PSProfileIgnoreRule $g '' } })
        $ignore = $IgnoreCase -or (-not $CaseSensitive -and -not (Test-PSProfileUpper $Pattern))
        $selectArgs = @{ Pattern = $rx; CaseSensitive = (-not $ignore) }
        if ($InvertMatch) { $selectArgs.NotMatch = $true } else { $selectArgs.AllMatches = $true }
        $pre = $Context
        $post = $Context
        if ($Before -ge 0) { $pre = $Before }
        if ($After -ge 0) { $post = $After }
        $skipped = @{ Legacy = 0; Large = 0 }
        $seen = 0
        $window = {
            param($Found, [int]$Total)
            $hit = @{}
            foreach ($m in $Found) { $hit[$m.LineNumber - 1] = $m.Matches }
            $show = @{}
            foreach ($n in $hit.Keys) {
                for ($j = $n - $pre; $j -le $n + $post; $j++) {
                    if ($j -ge 0 -and $j -lt $Total) { $show[$j] = $true }
                }
            }
            @{ Hit = $hit; Show = $show }
        }
        $search = {
            param($file, $rel)
            if ($globRules.Count -and -not (Test-PSProfileGlob $rel $globRules)) { return }
            $ext = $file.Extension.ToLower()
            if ($ext -eq '.doc' -or $ext -eq '.xls' -or $ext -eq '.ppt') { $skipped.Legacy++; return }
            if ($file.Length -gt $MaxSizeMB * 1MB) { $skipped.Large++; return }
            if ($Office -and ($ext -eq '.docx' -or $ext -eq '.xlsx' -or $ext -eq '.pptx')) {
                $lines = @(ConvertFrom-PSProfileOffice $file.FullName)
            } else {
                $text = Read-PSProfileText $file.FullName
                if ($null -eq $text) { return }
                $lines = Split-PSProfileLines $text
            }
            if (-not $InvertMatch) {
                if ($ignore) { $any = @($lines) -match $rx } else { $any = @($lines) -cmatch $rx }
                if (-not @($any).Count) { return }
            }
            $ms = @($lines | Select-String @selectArgs)
            if (-not $ms.Count) { return }
            if ($FilesWithMatches) { $file.FullName; return }
            if (-not $toHost) {
                foreach ($m in $ms) {
                    $n = $m.LineNumber - 1
                    $a = $n - $pre
                    if ($a -lt 0) { $a = 0 }
                    $b = $n + $post
                    if ($b -gt $lines.Count - 1) { $b = $lines.Count - 1 }
                    New-Object PSObject -Property @{
                        Path        = $file.FullName
                        LineNumber  = $m.LineNumber
                        Line        = $m.Line
                        PreContext  = @(if ($n -gt $a) { $lines[$a..($n - 1)] })
                        PostContext = @(if ($b -gt $n) { $lines[($n + 1)..$b] })
                    } | Select-Object Path, LineNumber, Line, PreContext, PostContext
                }
                return
            }
            Write-Host $file.FullName -ForegroundColor Magenta
            $w = & $window $ms $lines.Count
            $hit = $w.Hit
            $show = $w.Show
            $last = -2
            foreach ($j in ($show.Keys | Sort-Object)) {
                if (($pre -or $post) -and $last -ge 0 -and $j -gt $last + 1) { Write-Host '--' -ForegroundColor DarkGray }
                $last = $j
                if ($hit.ContainsKey($j)) {
                    Write-Host ('{0}:' -f ($j + 1)) -ForegroundColor Green -NoNewline
                    Write-PSProfileMatchLine $lines[$j] $hit[$j]
                } else {
                    Write-Host ('{0}-{1}' -f ($j + 1), $lines[$j]) -ForegroundColor DarkGray
                }
            }
            Write-Host ''
        }
        $searchPath = {
            param($p)
            $full = Get-PSProfileFullPath $p
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if (-not $item) { Write-Error "rg: '$p' not found."; return }
            if (-not $item.PSIsContainer) { & $search $item $item.Name; return }
            if (Test-PSProfileWholeShare $full) {
                Write-Error "rg: refusing a whole-share content search of '$full'. Give a folder or pipe fd results."
                return
            }
            $top = $full.TrimEnd('\', '/').Length + 1
            Get-PSProfileTree $full -SkipHidden:(-not $Hidden) -UseIgnore:(-not $NoIgnore) | Where-Object { -not ([int]$_.Attributes -band 16) } | ForEach-Object {
                $rel = ''
                if ($globRules.Count) { $rel = $_.FullName.Substring($top) -replace '\\', '/' }
                & $search $_ $rel
            }
        }
        $piped = @{}
        $searchText = {
            $lines = @(for ($q = 0; $q -lt $piped.Count; $q++) { $piped[$q] })
            $ms = @($lines | Select-String @selectArgs)
            if (-not $ms.Count) { return }
            if ($FilesWithMatches) { '(standard input)'; return }
            $w = & $window $ms $lines.Count
            $hit = $w.Hit
            $show = $w.Show
            $last = -2
            foreach ($j in ($show.Keys | Sort-Object)) {
                if (($pre -or $post) -and $last -ge 0 -and $j -gt $last + 1) {
                    if ($toHost) { Write-Host '--' -ForegroundColor DarkGray } else { '--' }
                }
                $last = $j
                if (-not $toHost) {
                    if ($LineNumber) { '{0}:{1}' -f ($j + 1), $lines[$j] } else { $lines[$j] }
                    continue
                }
                if ($LineNumber) { Write-Host ('{0}:' -f ($j + 1)) -ForegroundColor Green -NoNewline }
                if ($hit.ContainsKey($j)) { Write-PSProfileMatchLine $lines[$j] $hit[$j] }
                else { Write-Host $lines[$j] -ForegroundColor DarkGray }
            }
        }
    }
    process {
        if ($invalid) { return }
        foreach ($p in $Path) {
            if ($MyInvocation.ExpectingInput -and -not (Test-PSProfilePipedPath $p)) {
                $piped[$piped.Count] = $p
                continue
            }
            $seen++
            & $searchPath $p
        }
    }
    end {
        if ($invalid) { return }
        if ($piped.Count) { & $searchText }
        if (-not $seen -and -not $MyInvocation.ExpectingInput) { & $searchPath '.' }
        if ($skipped.Legacy -or $skipped.Large) {
            Write-Warning ('rg: skipped {0} legacy Office file(s) (.doc .xls .ppt) and {1} file(s) over {2} MB.' -f $skipped.Legacy, $skipped.Large, $MaxSizeMB)
        }
    }
}

function global:Get-PSProfilePreview($Item, [int]$Rows) {
    $path = $null
    $line = 0
    if ($Item -is [string]) { $path = $Item }
    elseif (Get-PSProfileProperty $Item 'FullName') { $path = Get-PSProfileProperty $Item 'FullName' }
    elseif (Get-PSProfileProperty $Item 'Path') {
        $path = Get-PSProfileProperty $Item 'Path'
        $line = [int](Get-PSProfileProperty $Item 'LineNumber')
    }
    if (-not $path) { return }
    try { $i = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { return }
    if ($i.PSIsContainer) {
        $sep = '\'
        if ($i.FullName.StartsWith('/')) { $sep = '/' }
        foreach ($c in @(Get-ChildItem -LiteralPath $i.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First $Rows)) {
            $n = $c.Name
            if ($c.PSIsContainer) { $n += $sep }
            @{ N = ''; Text = $n; Mark = $false }
        }
        return
    }
    if ($i.Length -gt 20MB) { return @{ N = ''; Text = '(file over 20 MB)'; Mark = $false } }
    try { $lines = Get-PSProfileFileLines $i.FullName } catch { return @{ N = ''; Text = '(binary file)'; Mark = $false } }
    $a = 1
    if ($line) { $a = $line - [int]($Rows / 2) }
    if ($a -lt 1) { $a = 1 }
    for ($n = $a; $n -lt $a + $Rows -and $n -le $lines.Count; $n++) {
        @{ N = $n; Text = $lines[$n - 1]; Mark = ($n -eq $line) }
    }
}

function global:Format-PSProfileFit {
    [OutputType([string])]
    param([string]$Text, [int]$Width, [switch]$End)
    $t = $Text -replace '\t', '    ' -replace '[\x00-\x1f]', ' '
    if ($t.Length -gt $Width) {
        if ($End) { $t = '..' + $t.Substring($t.Length - $Width + 2) } else { $t = $t.Substring(0, $Width - 2) + '..' }
    }
    $t.PadRight($Width)
}

function global:fzf {
    param([string]$Query = '')
    $items = @($input)
    if (-not $items.Count) { return }
    $texts = @(foreach ($it in $items) {
        $t = $it
        if ($it -isnot [string]) {
            $display = Get-PSProfileProperty $it 'Display'
            $full = Get-PSProfileProperty $it 'FullName'
            $matchPath = Get-PSProfileProperty $it 'Path'
            $matchLine = Get-PSProfileProperty $it 'LineNumber'
            if ($display) { $t = $display }
            elseif ($full) { $t = $full }
            elseif ($matchPath -and $matchLine) { $t = '{0}:{1}: {2}' -f $matchPath, $matchLine, (Get-PSProfileProperty $it 'Line') }
            else { $t = (($it | Out-String).Trim() -replace '\s+', ' ') }
        }
        $t
    })
    $width = 0
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { $width = 0 }
    $maxRows = 20
    try { $maxRows = $Host.UI.RawUI.WindowSize.Height - 6 } catch { $maxRows = 20 }
    if ($maxRows -lt 20) { $maxRows = 20 }
    if ($maxRows -gt 50) { $maxRows = 50 }
    while ($true) {
        $tokens = @($Query -split '\s+' | Where-Object { $_ })
        $cand = $texts
        $rxs = @(foreach ($tok in $tokens) {
            $rx = (@($tok.ToCharArray() | ForEach-Object { [regex]::Escape([string]$_) })) -join '.*?'
            if ($tok -match '[\\^$.|?*+()\[\]{}]') {
                $valid = $true
                try { $null = '' -match $tok } catch { $valid = $false }
                if ($valid) { $rx = $tok }
            }
            '(?i)' + $rx
        })
        foreach ($rx in $rxs) { $cand = @($cand -match $rx) }
        $total = $cand.Count
        if ($tokens.Count) {
            if ($cand.Count -gt 5000) { $cand = $cand[0..4999] }
            $lowerTokens = @(foreach ($tok in $tokens) { $tok.ToLower() })
            $top = @(@(foreach ($t in $cand) {
                $lower = $t.ToLower()
                $leaf = $t.LastIndexOf('\')
                if ($t.LastIndexOf('/') -gt $leaf) { $leaf = $t.LastIndexOf('/') }
                $leaf++
                $score = - $t.Length / 20
                for ($k = 0; $k -lt $tokens.Count; $k++) {
                    $at = $lower.IndexOf($lowerTokens[$k])
                    if ($at -ge 0) { $score += 100 } else {
                        $m = [regex]::Match($t, $rxs[$k])
                        $at = $m.Index
                        $score -= $m.Length - $tokens[$k].Length
                    }
                    if ($at -ge $leaf) { $score += 50 }
                    if ($at -eq $leaf) { $score += 25 }
                    if ($at -eq 0 -or $t.Substring($at - 1, 1) -match '[^A-Za-z0-9]') { $score += 15 }
                }
                @{ Text = $t; Score = $score }
            }) | Sort-Object { $_.Score } -Descending | Select-Object -First $maxRows | ForEach-Object { $_.Text })
        } else {
            $top = @($cand | Select-Object -First $maxRows)
        }
        $prev = @()
        if ($top.Count -and $width -ge 60) {
            for ($i = 0; $i -lt $texts.Count; $i++) {
                if ($texts[$i] -ceq $top[0]) { $prev = @(Get-PSProfilePreview $items[$i] $maxRows); break }
            }
        }
        Write-Host ('{0} of {1} match' -f $total, $texts.Count) -ForegroundColor DarkGray
        if ($prev.Count) {
            $lw = ($width - $width % 2) / 2 - 1
            $rw = $width - $lw - 4
            $rows = $top.Count
            if ($prev.Count -gt $rows) { $rows = $prev.Count }
            for ($i = 0; $i -lt $rows; $i++) {
                if ($i -lt $top.Count) {
                    Write-Host ('{0,3} ' -f ('#' + ($i + 1))) -ForegroundColor Cyan -NoNewline
                    Write-Host (Format-PSProfileFit $top[$i] ($lw - 4) -End:($top[$i] -match '[\\/]')) -NoNewline
                } else {
                    Write-Host (''.PadRight($lw)) -NoNewline
                }
                Write-Host ' | ' -ForegroundColor DarkGray -NoNewline
                if ($i -ge $prev.Count) { Write-Host ''; continue }
                $p = $prev[$i]
                $tw = $rw
                if ($p.N) {
                    Write-Host ('{0,5} ' -f $p.N) -ForegroundColor DarkGray -NoNewline
                    $tw -= 6
                }
                $c = 'Gray'
                if ($p.Mark) { $c = 'Yellow' }
                Write-Host (Format-PSProfileFit $p.Text $tw).TrimEnd() -ForegroundColor $c
            }
        } else {
            for ($i = 0; $i -lt $top.Count; $i++) {
                Write-Host ('{0,3} ' -f ('#' + ($i + 1))) -ForegroundColor Cyan -NoNewline
                Write-Host ($top[$i] -replace '\s*[\r\n]+\s*', ' ')
            }
        }
        $r = Read-Host 'Type #number to pick, text to filter, Enter to quit'
        if (-not $r) { return }
        if ($r -match '^#(\d+)$' -and [int]$Matches[1] -ge 1 -and [int]$Matches[1] -le $top.Count) {
            $pick = $top[[int]$Matches[1] - 1]
            for ($i = 0; $i -lt $texts.Count; $i++) { if ($texts[$i] -ceq $pick) { return $items[$i] } }
        }
        $Query = $r
    }
}

$global:PSProfileZFile = Join-Path $global:PSProfileDataDir 'z.txt'

function global:Read-PSProfileZ {
    [OutputType([hashtable])]
    param()
    $db = @{}
    if (Test-Path -LiteralPath $global:PSProfileZFile) {
        foreach ($line in (Get-Content -LiteralPath $global:PSProfileZFile -Encoding UTF8)) {
            $f = $line.Split("`t")
            if ($f.Count -ge 3) { $db[$f[0]] = @{ Rank = [double]$f[1]; Time = [long]$f[2] } }
        }
    }
    $db
}

function global:Save-PSProfileZ([hashtable]$Db) {
    $lines = foreach ($k in $Db.Keys) { '{0}{1}{2}{1}{3}' -f $k, "`t", $Db[$k].Rank, $Db[$k].Time }
    Set-Content -LiteralPath $global:PSProfileZFile -Value @($lines) -Encoding UTF8
}

function global:Get-PSProfileNow {
    [OutputType([long])]
    param()
    [long]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds
}

function global:Add-PSProfileZ([string]$Path) {
    $db = Read-PSProfileZ
    $now = Get-PSProfileNow
    if ($db.ContainsKey($Path)) { $db[$Path].Rank += 1; $db[$Path].Time = $now }
    else { $db[$Path] = @{ Rank = 1; Time = $now } }
    $sum = 0
    foreach ($v in $db.Values) { $sum += $v.Rank }
    if ($sum -gt 9000) {
        foreach ($k in @($db.Keys)) {
            $db[$k].Rank *= 0.99
            if ($db[$k].Rank -lt 1) { $db.Remove($k) }
        }
    }
    Save-PSProfileZ $db
}

function global:Remove-PSProfileZ([string]$Path) {
    $db = Read-PSProfileZ
    $db.Remove($Path)
    Save-PSProfileZ $db
}

function global:Get-PSProfileZ([string[]]$Terms) {
    $db = Read-PSProfileZ
    $now = Get-PSProfileNow
    $rx = (@($Terms) | ForEach-Object { [regex]::Escape($_) }) -join '.*'
    $db.Keys | Where-Object { $_ -match $rx } | ForEach-Object {
        $age = $now - $db[$_].Time
        $w = 0.25
        if ($age -lt 3600) { $w = 4 } elseif ($age -lt 86400) { $w = 2 } elseif ($age -lt 604800) { $w = 0.5 }
        New-Object PSObject -Property @{ Path = $_; Score = $db[$_].Rank * $w }
    } | Sort-Object Score -Descending | ForEach-Object { $_.Path }
}

function global:Enter-PSProfileZ {
    [OutputType([bool])]
    param([string]$Path)
    try { Set-Location -LiteralPath $Path -ErrorAction Stop }
    catch { Remove-PSProfileZ $Path; Write-Warning "z: removed dead entry '$Path'."; return $false }
    Add-PSProfileZ (Get-Location).ProviderPath
    return $true
}

function global:z([string]$Query) {
    $terms = @(@($Query) + $args | Where-Object { $_ })
    foreach ($p in @(Get-PSProfileZ $terms)) {
        if (Enter-PSProfileZ $p) { return }
    }
    Write-Warning "z: no match for '$terms'."
}

function global:zi([string]$Query) {
    $terms = @(@($Query) + $args | Where-Object { $_ })
    $pick = Get-PSProfileZ $terms | fzf
    if ($pick) { $null = Enter-PSProfileZ $pick }
}

Remove-Item Alias:cd -Force -ErrorAction SilentlyContinue
function global:cd {
    try {
        if ($args.Count -eq 1 -and $args[0] -ceq '-') {
            if (-not $global:PSProfileOldPwd) { Write-Error 'cd: no previous folder.'; return }
            Set-Location -LiteralPath $global:PSProfileOldPwd -ErrorAction Stop
        } else {
            Set-Location @args -ErrorAction Stop
        }
    } catch { Write-Error $_; return }
    if ($args.Count -and $MyInvocation.CommandOrigin -eq 'Runspace') { Add-PSProfileZ (Get-Location).ProviderPath }
}

function global:Get-PSProfileDiff([string[]]$A, [string[]]$B) {
    $lenA = $A.Count
    $lenB = $B.Count
    $pre = 0
    while ($pre -lt $lenA -and $pre -lt $lenB -and $A[$pre] -ceq $B[$pre]) { $pre++ }
    $suf = 0
    while ($suf -lt $lenA - $pre -and $suf -lt $lenB - $pre -and $A[$lenA - 1 - $suf] -ceq $B[$lenB - 1 - $suf]) { $suf++ }
    $coreA = $lenA - $pre - $suf
    $coreB = $lenB - $pre - $suf
    for ($i = 0; $i -lt $pre; $i++) { @{ T = ' '; A = $i; B = $i } }
    if ($coreA -eq 0) {
        for ($j = 0; $j -lt $coreB; $j++) { @{ T = '+'; A = $pre; B = $pre + $j } }
    } elseif ($coreB -eq 0) {
        for ($i = 0; $i -lt $coreA; $i++) { @{ T = '-'; A = $pre + $i; B = $pre } }
    } else {
        $v = @{ 1 = 0 }
        $trace = @{}
        $done = $false
        for ($d = 0; -not $done; $d++) {
            $trace[$d] = $v.Clone()
            for ($k = - $d; $k -le $d; $k += 2) {
                if ($k -eq - $d -or ($k -ne $d -and $v[$k - 1] -lt $v[$k + 1])) { $x = $v[$k + 1] } else { $x = $v[$k - 1] + 1 }
                $y = $x - $k
                while ($x -lt $coreA -and $y -lt $coreB -and $A[$pre + $x] -ceq $B[$pre + $y]) { $x++; $y++ }
                $v[$k] = $x
                if ($x -ge $coreA -and $y -ge $coreB) { $done = $true; break }
            }
        }
        $x = $coreA
        $y = $coreB
        $rev = @(for ($d = $d - 1; $d -ge 0; $d--) {
            $vd = $trace[$d]
            $k = $x - $y
            if ($k -eq - $d -or ($k -ne $d -and $vd[$k - 1] -lt $vd[$k + 1])) { $pk = $k + 1 } else { $pk = $k - 1 }
            $px = $vd[$pk]
            $py = $px - $pk
            while ($x -gt $px -and $y -gt $py -and $x -gt 0 -and $y -gt 0) {
                $x--; $y--
                @{ T = ' '; A = $pre + $x; B = $pre + $y }
            }
            if ($d -gt 0) {
                if ($x -eq $px) { @{ T = '+'; A = $pre + $px; B = $pre + $py } }
                else { @{ T = '-'; A = $pre + $px; B = $pre + $py } }
                $x = $px
                $y = $py
            }
        })
        for ($i = $rev.Count - 1; $i -ge 0; $i--) { $rev[$i] }
    }
    for ($i = 0; $i -lt $suf; $i++) { @{ T = ' '; A = $lenA - $suf + $i; B = $lenB - $suf + $i } }
}

function global:Get-PSProfileFileLines([string]$Path) {
    if ($Path -match '\.(docx|xlsx|pptx)$') { return , @(ConvertFrom-PSProfileOffice (Get-PSProfileFullPath $Path)) }
    $text = Read-PSProfileText $Path
    if ($null -eq $text) { throw "'$Path' is a binary file." }
    $lines = Split-PSProfileLines $text
    , $lines
}

function global:Write-PSProfileWordLine([string]$Mark, [string[]]$Tokens, [hashtable]$Changed, [string]$Dark, [string]$Bright) {
    Write-Host $Mark -ForegroundColor $Dark -NoNewline
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $c = $Dark
        if ($Changed[$i]) { $c = $Bright }
        Write-Host $Tokens[$i] -ForegroundColor $c -NoNewline
    }
    Write-Host ''
}

function global:Write-PSProfileSideRow($LeftNo, [string]$Left, [string]$LeftColor, $RightNo, [string]$Right, [string]$RightColor, [int]$Width) {
    Write-Host ('{0,5} ' -f $LeftNo) -ForegroundColor DarkGray -NoNewline
    Write-Host (Format-PSProfileFit $Left $Width) -ForegroundColor $LeftColor -NoNewline
    Write-Host ' | ' -ForegroundColor DarkGray -NoNewline
    Write-Host ('{0,5} ' -f $RightNo) -ForegroundColor DarkGray -NoNewline
    Write-Host (Format-PSProfileFit $Right $Width).TrimEnd() -ForegroundColor $RightColor
}

function global:delta {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path1,
        [Parameter(Mandatory = $true, Position = 1)][string]$Path2,
        [Alias('s')][switch]$SideBySide
    )
    $toHost = Test-PSProfileToHost $MyInvocation
    $side = $toHost -and $SideBySide
    $half = 0
    if ($side) {
        $width = 0
        try { $width = $Host.UI.RawUI.WindowSize.Width } catch { $width = 0 }
        if (-not $width) { $width = 120 }
        $half = [int](($width - 16 - $width % 2) / 2)
        if ($half -lt 20) {
            Write-Warning 'delta: the window is too narrow for side by side. The output is a unified diff.'
            $side = $false
        }
    }
    if (-not (Test-Path -LiteralPath $Path1)) { Write-Error "delta: '$Path1' not found."; return }
    if (-not (Test-Path -LiteralPath $Path2)) { Write-Error "delta: '$Path2' not found."; return }
    $a = Get-PSProfileFileLines $Path1
    $b = Get-PSProfileFileLines $Path2
    if ($a.Count -gt 20000 -or $b.Count -gt 20000) {
        Write-Warning ('delta: large input ({0} and {1} lines). This can be slow.' -f $a.Count, $b.Count)
    }
    $ops = @(Get-PSProfileDiff $a $b)
    $changes = @(for ($i = 0; $i -lt $ops.Count; $i++) { if ($ops[$i].T -ne ' ') { $i } })
    if (-not $changes.Count) { return }

    if ($toHost) {
        Write-Host "--- $Path1" -ForegroundColor Red
        Write-Host "+++ $Path2" -ForegroundColor Green
    } else {
        "--- $Path1"
        "+++ $Path2"
    }
    $h = 0
    while ($h -lt $changes.Count) {
        $last = $h
        while ($last + 1 -lt $changes.Count -and $changes[$last + 1] - $changes[$last] -le 7) { $last++ }
        $s = $changes[$h] - 3
        if ($s -lt 0) { $s = 0 }
        $e = $changes[$last] + 3
        if ($e -gt $ops.Count - 1) { $e = $ops.Count - 1 }
        $h = $last + 1
        $aCount = 0
        $bCount = 0
        for ($i = $s; $i -le $e; $i++) {
            if ($ops[$i].T -ne '+') { $aCount++ }
            if ($ops[$i].T -ne '-') { $bCount++ }
        }
        $aStart = $ops[$s].A
        $bStart = $ops[$s].B
        if ($aCount) { $aStart++ }
        if ($bCount) { $bStart++ }
        $header = '@@ -{0},{1} +{2},{3} @@' -f $aStart, $aCount, $bStart, $bCount
        if ($toHost) { Write-Host $header -ForegroundColor Cyan } else { $header }
        $i = $s
        while ($i -le $e) {
            $op = $ops[$i]
            if ($op.T -eq ' ') {
                if ($side) { Write-PSProfileSideRow ($op.A + 1) $a[$op.A] 'Gray' ($op.B + 1) $b[$op.B] 'Gray' $half }
                elseif ($toHost) { Write-Host (' ' + $a[$op.A]) } else { ' ' + $a[$op.A] }
                $i++
                continue
            }
            $dels = @()
            while ($i -le $e -and $ops[$i].T -eq '-') { $dels += $ops[$i]; $i++ }
            $adds = @()
            while ($i -le $e -and $ops[$i].T -eq '+') { $adds += $ops[$i]; $i++ }
            if ($side) {
                $count = $dels.Count
                if ($adds.Count -gt $count) { $count = $adds.Count }
                for ($p = 0; $p -lt $count; $p++) {
                    $leftNo = ''
                    $leftText = ''
                    $rightNo = ''
                    $rightText = ''
                    if ($p -lt $dels.Count) { $leftNo = $dels[$p].A + 1; $leftText = $a[$dels[$p].A] }
                    if ($p -lt $adds.Count) { $rightNo = $adds[$p].B + 1; $rightText = $b[$adds[$p].B] }
                    Write-PSProfileSideRow $leftNo $leftText 'Red' $rightNo $rightText 'Green' $half
                }
                continue
            }
            if (-not $toHost) {
                foreach ($d in $dels) { '-' + $a[$d.A] }
                foreach ($d in $adds) { '+' + $b[$d.B] }
                continue
            }
            $pairs = $dels.Count
            if ($adds.Count -lt $pairs) { $pairs = $adds.Count }
            $delLines = @()
            $addLines = @()
            for ($p = 0; $p -lt $pairs; $p++) {
                $ta = @([regex]::Matches($a[$dels[$p].A], '\w+|\s+|[^\w\s]') | ForEach-Object { $_.Value })
                $tb = @([regex]::Matches($b[$adds[$p].B], '\w+|\s+|[^\w\s]') | ForEach-Object { $_.Value })
                $ca = @{}
                $cb = @{}
                foreach ($w in (Get-PSProfileDiff $ta $tb)) {
                    if ($w.T -eq '-') { $ca[$w.A] = $true } elseif ($w.T -eq '+') { $cb[$w.B] = $true }
                }
                $delLines += , @($ta, $ca)
                $addLines += , @($tb, $cb)
            }
            for ($p = 0; $p -lt $dels.Count; $p++) {
                if ($p -lt $pairs) { Write-PSProfileWordLine '-' $delLines[$p][0] $delLines[$p][1] 'DarkRed' 'Red' }
                else { Write-Host ('-' + $a[$dels[$p].A]) -ForegroundColor Red }
            }
            for ($p = 0; $p -lt $adds.Count; $p++) {
                if ($p -lt $pairs) { Write-PSProfileWordLine '+' $addLines[$p][0] $addLines[$p][1] 'DarkGreen' 'Green' }
                else { Write-Host ('+' + $b[$adds[$p].B]) -ForegroundColor Green }
            }
        }
    }
}

$global:PSProfileSyntaxRules = @{
    PowerShell = @{ Prefix = '(?i)'; Comment = '#.*$'; Block = @{ '<#' = '#>' }; Keywords = 'begin|break|catch|class|continue|do|else|elseif|end|exit|filter|finally|for|foreach|function|if|in|param|process|return|switch|throw|try|until|while' }
    Python     = @{ Prefix = ''; Comment = '#.*$'; Block = @{ '"""' = '"""'; "'''" = "'''" }; Keywords = 'and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield' }
    Shell      = @{ Prefix = ''; Comment = '#.*$'; Keywords = 'case|do|done|elif|else|esac|exit|export|fi|for|function|if|in|local|return|then|until|while' }
    CLike      = @{ Prefix = ''; Comment = '//.*$'; Block = @{ '/*' = '*/' }; Keywords = 'async|await|bool|break|case|catch|char|class|const|continue|def|default|double|else|enum|export|extends|false|final|finally|float|fn|for|foreach|from|func|function|if|implements|import|in|int|interface|let|long|namespace|new|null|package|private|protected|public|return|static|string|struct|switch|this|throw|true|try|type|typeof|using|var|void|while' }
    Sql        = @{ Prefix = '(?i)'; Comment = '--.*$'; Block = @{ '/*' = '*/' }; Keywords = 'alter|and|as|asc|begin|by|case|create|delete|desc|distinct|drop|else|end|exists|from|group|having|in|index|inner|insert|into|is|join|left|like|limit|not|null|on|or|order|outer|right|select|set|table|then|union|update|values|when|where|with' }
    Config     = @{ Prefix = ''; Comment = '(?:^|\s)[#;].*$'; Keywords = 'false|no|null|off|on|true|yes' }
    Json       = @{ Prefix = ''; Comment = ''; Keywords = 'false|null|true' }
    Batch      = @{ Prefix = '(?i)'; Comment = '^\s*(?:rem\b|::).*$'; Keywords = 'call|cd|echo|else|exit|for|goto|if|in|not|set|setlocal|endlocal' }
}

$global:PSProfileSyntaxExt = @{
    '.ps1' = 'PowerShell'; '.psm1' = 'PowerShell'; '.psd1' = 'PowerShell'; '.py' = 'Python'; '.sh' = 'Shell'; '.bash' = 'Shell'
    '.js' = 'CLike'; '.jsx' = 'CLike'; '.ts' = 'CLike'; '.tsx' = 'CLike'; '.cs' = 'CLike'; '.java' = 'CLike'; '.c' = 'CLike'; '.h' = 'CLike'
    '.cpp' = 'CLike'; '.hpp' = 'CLike'; '.go' = 'CLike'; '.rs' = 'CLike'; '.sql' = 'Sql'; '.json' = 'Json'; '.yml' = 'Config'; '.yaml' = 'Config'
    '.toml' = 'Config'; '.ini' = 'Config'; '.cfg' = 'Config'; '.conf' = 'Config'; '.bat' = 'Batch'; '.cmd' = 'Batch'
}

function global:Get-PSProfileSyntax {
    param([string]$Path)
    $language = $global:PSProfileSyntaxExt[[regex]::Match($Path, '\.[^.\\/]*$').Value.ToLower()]
    if (-not $language) { return $null }
    $rule = $global:PSProfileSyntaxRules[$language]
    $parts = @()
    if ($rule.Comment) { $parts += '(?<c>' + $rule.Comment + ')' }
    if ($rule.Block) { $parts += '(?<b>' + ((@($rule.Block.Keys) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')' }
    $parts += '(?<s>"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*'')'
    $parts += '(?<n>\b\d+(?:\.\d+)?\b)'
    $parts += '(?<k>\b(?:' + $rule.Keywords + ')\b)'
    @{ Rx = [regex]($rule.Prefix + ($parts -join '|')); Close = $rule.Block }
}

function global:Write-PSProfileSyntaxLine([string]$Line, [hashtable]$Syntax, [string]$Block) {
    $pos = 0
    while ($pos -lt $Line.Length) {
        if ($Block) {
            $end = $Line.IndexOf($Block, $pos)
            $stop = $Line.Length
            if ($end -ge 0) { $stop = $end + $Block.Length }
            Write-Host $Line.Substring($pos, $stop - $pos) -ForegroundColor DarkGray -NoNewline
            $pos = $stop
            if ($end -ge 0) { $Block = '' }
            continue
        }
        $m = $Syntax.Rx.Match($Line, $pos)
        if (-not $m.Success -or $m.Length -eq 0) { break }
        if ($m.Index -gt $pos) { Write-Host $Line.Substring($pos, $m.Index - $pos) -NoNewline }
        if ($m.Groups['b'].Success) {
            $Block = $Syntax.Close[$m.Value]
            Write-Host $m.Value -ForegroundColor DarkGray -NoNewline
            $pos = $m.Index + $m.Length
            continue
        }
        $c = 'Cyan'
        if ($m.Groups['c'].Success) { $c = 'DarkGray' }
        elseif ($m.Groups['s'].Success) { $c = 'Green' }
        elseif ($m.Groups['n'].Success) { $c = 'Magenta' }
        Write-Host $m.Value -ForegroundColor $c -NoNewline
        $pos = $m.Index + $m.Length
    }
    Write-Host $Line.Substring($pos)
    $Block
}

function global:bat {
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')][string[]]$Path,
        [ValidatePattern('^\d*-\d*$')][string]$Range,
        [string]$Pattern
    )
    begin {
        $toHost = Test-PSProfileToHost $MyInvocation
        $from = 1
        $to = 0
        if ($Range -match '^(\d*)-(\d*)$') {
            if ($Matches[1]) { $from = [int]$Matches[1] }
            if ($Matches[2]) { $to = [int]$Matches[2] }
        }
    }
    process {
        foreach ($p in $Path) {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Write-Error "bat: '$p' not found."; continue }
            try { $lines = Get-PSProfileFileLines $p } catch { Write-Error "bat: $($_.Exception.Message)"; continue }
            $last = $lines.Count
            if ($to -and $to -lt $last) { $last = $to }
            if (-not $toHost) {
                for ($n = $from; $n -le $last; $n++) { $lines[$n - 1] }
                continue
            }
            Write-Host (Get-PSProfileFullPath $p) -ForegroundColor Magenta
            $syntax = $null
            $block = ''
            if ($lines.Count -le 5000) { $syntax = Get-PSProfileSyntax $p }
            if ($syntax) {
                for ($n = 1; $n -lt $from -and $n -le $lines.Count; $n++) { $block = Write-PSProfileSyntaxLine $lines[$n - 1] $syntax $block 6>$null }
            }
            $fmt = '{0,' + ('' + $last).Length + '} '
            for ($n = $from; $n -le $last; $n++) {
                Write-Host ($fmt -f $n) -ForegroundColor DarkGray -NoNewline
                $ms = $null
                if ($Pattern) { $ms = [regex]::Matches($lines[$n - 1], '(?i)' + $Pattern) }
                if ($ms -and $ms.Count) {
                    if ($syntax) { $block = Write-PSProfileSyntaxLine $lines[$n - 1] $syntax $block 6>$null }
                    Write-PSProfileMatchLine $lines[$n - 1] $ms
                }
                elseif ($syntax -and $lines[$n - 1].Length -le 2000) { $block = Write-PSProfileSyntaxLine $lines[$n - 1] $syntax $block }
                else { Write-Host $lines[$n - 1] }
            }
        }
    }
}

function global:Get-PSProfileHistory {
    $file = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path -LiteralPath $file)) { return }
    $cur = ''
    $cmds = @(foreach ($l in (Get-Content -LiteralPath $file -Encoding UTF8 -ReadCount 0)) {
        if ($l -match '`$') { $cur += $l.Substring(0, $l.Length - 1) + "`n"; continue }
        $cur + $l
        $cur = ''
    })
    $seen = @{}
    for ($i = $cmds.Count - 1; $i -ge 0; $i--) {
        $c = $cmds[$i]
        if ($c.Trim() -and -not $seen.ContainsKey($c)) { $seen[$c] = $true; $c }
    }
}

function global:Test-PSProfileWholeShare {
    [OutputType([bool])]
    param([string]$Full)
    $unc = ConvertTo-PSProfileUnc $Full
    $root = Find-PSProfileRoot $unc
    $unc -match '^\\\\[^\\]+\\[^\\]+\\?$' -or [bool]($root -and $unc.TrimEnd('\', '/') -eq $root.Unc)
}

function global:Get-PSProfileReplacer {
    param(
        [string]$Command,
        [string]$Pattern,
        [string]$Replacement,
        [bool]$IgnoreCase,
        [bool]$CaseSensitive,
        [bool]$SimpleMatch,
        [bool]$Word
    )
    $rx = $Pattern
    $rep = $Replacement
    if ($SimpleMatch) {
        $rx = [regex]::Escape($Pattern)
        $rep = $Replacement -replace '\$', '$$$$'
    }
    if ($Word) { $rx = '\b(?:' + $rx + ')\b' }
    try {
        $null = '' -match $rx
    } catch {
        Write-Error "${Command}: '$Pattern' is not a valid pattern. Use -F for plain text."
        return
    }
    $ignore = $IgnoreCase -or (-not $CaseSensitive -and -not (Test-PSProfileUpper $Pattern))
    @{ Rx = $rx; Rep = $rep; Case = (-not $ignore) }
}

function global:Get-PSProfileHash {
    [OutputType([string])]
    param([string]$Path)
    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
    if (-not $h) { throw "Cannot read '$Path'." }
    $h.Hash
}

function global:Copy-PSProfileBytes([string]$From, [string]$To, [switch]$NoBom) {
    $byteArgs = $global:PSProfileByteArgs
    $b = Get-Content -LiteralPath $From -ReadCount 0 @byteArgs -ErrorAction Stop
    if ($null -eq $b) { $b = @() } elseif ($b -isnot [array]) { $b = @($b) }
    if ($NoBom) {
        if ($b.Count -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { return }
        if ($b.Count -eq 3) { $b = @() } else { $b = $b[3..($b.Count - 1)] }
    }
    if ($b.Count) { Set-Content -LiteralPath $To -Value $b @byteArgs -Force -WarningAction SilentlyContinue -ErrorAction Stop }
    else { Set-Content -LiteralPath $To -Value '' -NoNewline -Encoding Ascii -Force -ErrorAction Stop }
}

function global:Write-PSProfileEncoded {
    param([string]$Path, [string]$Text, [hashtable]$Source, [string]$Staged)
    $enc = $Source.Enc
    if ("$enc" -eq 'UTF8') {
        if ($Source.Bom) { $enc = $global:PSProfileUtf8Bom }
        elseif ($Text -cnotmatch '[^\x00-\x7F]') { $enc = 'Ascii' }
        elseif ($Staged) { Copy-PSProfileBytes $Staged $Path; return }
        else {
            Set-Content -LiteralPath $Path -Value $Text -NoNewline -Encoding $global:PSProfileUtf8Bom -Force -ErrorAction Stop
            Copy-PSProfileBytes $Path $Path -NoBom
            return
        }
    }
    Set-Content -LiteralPath $Path -Value $Text -NoNewline -Encoding $enc -Force -ErrorAction Stop
}

function global:Save-PSProfileUndo([string]$Copy, [hashtable]$Undo) {
    if (-not $Undo.Ready) {
        Remove-Item -LiteralPath $Undo.Dir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $Undo.Dir -Force -ErrorAction Stop | Out-Null
        $Undo.Ready = $true
    }
    $Undo.N++
    $name = "$($Undo.N).orig"
    Copy-Item -LiteralPath $Copy -Destination (Join-Path $Undo.Dir $name) -Force -ErrorAction Stop
    $name
}

function global:Update-PSProfileTextFile {
    [OutputType([bool])]
    param($File, [hashtable]$Source, [string]$OldText, [string]$NewText, [hashtable]$Undo)
    $stem = Join-Path $env:TEMP ('ps-profile-sd-' + (Get-Random))
    $keep = "$stem.orig"
    $next = "$stem.new"
    $path = $File.FullName
    try {
        Write-PSProfileEncoded $keep $OldText $Source
        $oldHash = Get-PSProfileHash $path
        if ((Get-PSProfileHash $keep) -ne $oldHash) {
            $now = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($now.LastWriteTimeUtc -ne $File.LastWriteTimeUtc -or $now.Length -ne $File.Length) { Write-Warning "sd: skipped '$path'. The file changed during the run." }
            else { Write-Warning "sd: skipped '$path'. The profile cannot write this file back with the same bytes." }
            return $false
        }
        Write-PSProfileEncoded $next $NewText $Source
        $check = '' + (Get-Content -LiteralPath $next -Raw -Encoding $Source.Enc -ErrorAction Stop)
        if ($check -cne $NewText) {
            Write-Warning "sd: skipped '$path'. Its encoding cannot hold the new text."
            return $false
        }
        $newHash = Get-PSProfileHash $next
        $slot = Save-PSProfileUndo $keep $Undo
        $copy = Join-Path $Undo.Dir $slot
        Add-Content -LiteralPath (Join-Path $Undo.Dir 'manifest.txt') -Value ("{0}`t{1}`t{2}`t{3}" -f $slot, $oldHash, $newHash, $path) -Encoding UTF8 -ErrorAction Stop
        try {
            Write-PSProfileEncoded $path $NewText $Source $next
            if ((Get-PSProfileHash $path) -ne $newHash) { throw 'The bytes on disk are not the new text.' }
        } catch {
            $why = $_.Exception.Message
            try {
                if ((Get-PSProfileHash $path) -ne $oldHash) {
                    Copy-PSProfileBytes $copy $path
                    if ((Get-PSProfileHash $path) -ne $oldHash) { throw 'The bytes on disk are not the original.' }
                }
                Write-Warning "sd: could not write '$path'. The file has its original text. $why"
            } catch {
                Write-Warning "sd: could not write '$path' or put the original back. A copy of the original is at '$copy'. $why"
            }
            return $false
        }
        $true
    } catch {
        Write-Warning "sd: skipped '$path'. $($_.Exception.Message)"
        $false
    } finally {
        Remove-Item -LiteralPath $keep, $next -Force -ErrorAction SilentlyContinue
    }
}

function global:sd-undo {
    [CmdletBinding()]
    param()
    $dir = $global:PSProfileSdUndoDir
    $manifest = Join-Path $dir 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifest)) { Write-Host 'sd-undo: nothing to undo.' -ForegroundColor DarkGray; return }
    $left = @()
    $restored = 0
    foreach ($line in @(Get-Content -LiteralPath $manifest -Encoding UTF8)) {
        $f = $line.Split("`t")
        $copy = Join-Path $dir $f[0]
        $now = ''
        try { $now = Get-PSProfileHash $f[3] } catch { $now = '' }
        if ($now -and $now -eq $f[1]) { continue }
        if ($now -ne $f[2]) {
            Write-Warning "sd-undo: skipped '$($f[3])'. The file changed after sd ran. A copy of the original is at '$copy'."
            $left += $line
            continue
        }
        try {
            Copy-PSProfileBytes $copy $f[3]
            if ((Get-PSProfileHash $f[3]) -ne $f[1]) { throw 'The bytes on disk are not the original.' }
            $restored++
        } catch {
            Write-Warning "sd-undo: could not restore '$($f[3])'. A copy of the original is at '$copy'. $($_.Exception.Message)"
            $left += $line
        }
    }
    if ($left.Count) { Set-Content -LiteralPath $manifest -Value $left -Encoding UTF8 }
    else { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ('sd-undo: restored {0} file(s), {1} not restored.' -f $restored, $left.Count) -ForegroundColor Cyan
}

function global:sd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
        [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Replacement,
        [Parameter(Position = 2, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')][string[]]$Path,
        [Alias('i')][switch]$IgnoreCase,
        [Alias('F')][switch]$SimpleMatch,
        [Alias('g')][string[]]$Glob,
        [Alias('w')][switch]$Word,
        [Alias('s')][switch]$CaseSensitive,
        [Alias('u')][switch]$NoIgnore,
        [switch]$Hidden,
        [int]$MaxSizeMB = 20,
        [switch]$Apply
    )
    begin {
        $toHost = Test-PSProfileToHost $MyInvocation
        $r = Get-PSProfileReplacer -Command 'sd' -Pattern $Pattern -Replacement $Replacement -IgnoreCase:$IgnoreCase -CaseSensitive:$CaseSensitive -SimpleMatch:$SimpleMatch -Word:$Word
        $n = @{ Files = 0; Lines = 0; Written = 0; Failed = 0; ReadOnly = 0; Large = 0; Office = 0; Given = 0 }
        $done = @{}
        $undo = @{ Dir = $global:PSProfileSdUndoDir; Ready = $false; N = 0 }
        $globRules = @(foreach ($g in $Glob) { if ($g) { ConvertTo-PSProfileIgnoreRule $g '' } })
        $edit = {
            param($file, $rel)
            $key = $file.FullName.ToLower()
            if ($done.ContainsKey($key)) { return }
            $done[$key] = $true
            if ($file.FullName -match '[\\/]\.git[\\/]') { return }
            if ([int]$file.Attributes -band 1024) { return }
            if ($globRules.Count -and -not (Test-PSProfileGlob $rel $globRules)) { return }
            if ($file.Extension -match '^\.(docx|xlsx|pptx|doc|xls|ppt)$') { $n.Office++; return }
            if ($file.Length -gt $MaxSizeMB * 1MB) { $n.Large++; return }
            $source = Read-PSProfileEncoded $file.FullName
            $text = $source.Text
            if (-not $text) { return }
            $parts = $text -split '(\r\n|\n|\r)'
            if ($r.Case) { $any = @($parts) -cmatch $r.Rx } else { $any = @($parts) -match $r.Rx }
            if (-not @($any).Count) { return }
            $lines = 0
            $last = $parts.Count - 1
            if ($last -gt 0 -and $parts[$last] -eq '') { $last -= 2 }
            for ($j = 0; $j -le $last; $j += 2) {
                $old = $parts[$j]
                if ($r.Case) { $new = $old -creplace $r.Rx, $r.Rep } else { $new = $old -replace $r.Rx, $r.Rep }
                if ($new -ceq $old) { continue }
                if ($lines -eq 0 -and $toHost) { Write-Host $file.FullName -ForegroundColor Magenta }
                $lines++
                $parts[$j] = $new
                $ln = $j / 2 + 1
                if ($toHost) {
                    Write-Host ('{0}: - {1}' -f $ln, $old) -ForegroundColor Red
                    Write-Host ('{0}: + {1}' -f $ln, $new) -ForegroundColor Green
                } else {
                    New-Object PSObject -Property @{ Path = $file.FullName; LineNumber = $ln; Old = $old; New = $new } | Select-Object Path, LineNumber, Old, New
                }
            }
            if (-not $lines) { return }
            $n.Files++
            $n.Lines += $lines
            if ($toHost) { Write-Host '' }
            if (-not $Apply) { return }
            if ([int]$file.Attributes -band 1) { $n.ReadOnly++; return }
            if (Update-PSProfileTextFile $file $source $text (($parts) -join '') $undo) { $n.Written++ } else { $n.Failed++ }
        }
        $editPath = {
            param($p)
            $full = Get-PSProfileFullPath $p
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if (-not $item) { Write-Error "sd: '$p' not found."; return }
            if (-not $item.PSIsContainer) { & $edit $item $item.Name; return }
            if (Test-PSProfileWholeShare $full) { Write-Error "sd: refusing to change a whole share at '$full'. Give a folder or pipe fd results."; return }
            $top = $full.TrimEnd('\', '/').Length + 1
            Get-PSProfileTree $full -SkipHidden:(-not $Hidden) -UseIgnore:(-not $NoIgnore) | Where-Object { -not ([int]$_.Attributes -band 16) } | ForEach-Object {
                $rel = ''
                if ($globRules.Count) { $rel = $_.FullName.Substring($top) -replace '\\', '/' }
                & $edit $_ $rel
            }
        }
    }
    process {
        if (-not $r) { return }
        foreach ($p in $Path) {
            $n.Given++
            & $editPath $p
        }
    }
    end {
        if (-not $r) { return }
        if (-not $n.Given -and -not $MyInvocation.ExpectingInput) { & $editPath '.' }
        if ($n.Office -or $n.Large) { Write-Warning ('sd: skipped {0} Office file(s) and {1} file(s) over {2} MB.' -f $n.Office, $n.Large, $MaxSizeMB) }
        if ($n.ReadOnly) { Write-Warning ('sd: skipped {0} read-only file(s).' -f $n.ReadOnly) }
        if (-not $n.Files) { Write-Host 'sd: no matches.' -ForegroundColor DarkGray; return }
        if ($Apply) {
            Write-Host ('sd: changed {0} of {1} file(s), {2} line(s) found.' -f $n.Written, $n.Files, $n.Lines) -ForegroundColor Cyan
            if ($n.Written) { Write-Host 'Run sd-undo to restore the files.' -ForegroundColor DarkGray }
        } else {
            Write-Host ('sd: preview of {0} line(s) in {1} file(s). No file changed. Add -Apply to write.' -f $n.Lines, $n.Files) -ForegroundColor Cyan
        }
    }
}

function global:rnm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
        [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Replacement,
        [Parameter(Position = 2, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')][string[]]$Path,
        [Alias('i')][switch]$IgnoreCase,
        [Alias('F')][switch]$SimpleMatch,
        [Alias('s')][switch]$CaseSensitive,
        [Alias('r')][switch]$Recurse,
        [switch]$Folders,
        [Alias('H')][switch]$Hidden,
        [Alias('u')][switch]$NoIgnore,
        [switch]$Apply
    )
    begin {
        $toHost = Test-PSProfileToHost $MyInvocation
        $r = Get-PSProfileReplacer -Command 'rnm' -Pattern $Pattern -Replacement $Replacement -IgnoreCase:$IgnoreCase -CaseSensitive:$CaseSensitive -SimpleMatch:$SimpleMatch
        $piped = $MyInvocation.ExpectingInput
        $items = @{}
        $given = @{ N = 0 }
        $add = {
            param($i)
            if ($i.Name -eq '.git' -or $i.FullName -match '[\\/]\.git[\\/]') { return }
            $items[$i.FullName.ToLower()] = $i
        }
        $list = {
            param($p)
            $full = Get-PSProfileFullPath $p
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if (-not $item) { Write-Error "rnm: '$p' not found."; return }
            if (-not $item.PSIsContainer -or $piped) { & $add $item; return }
            if ($Recurse -and (Test-PSProfileWholeShare $full)) { Write-Error "rnm: refusing to walk a whole share at '$full'. Give a folder or pipe fd results."; return }
            $kids = @(if ($Recurse) {
                Get-PSProfileTree $full -SkipHidden:(-not $Hidden) -UseIgnore:(-not $NoIgnore)
            } else {
                Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Where-Object { $Hidden -or -not ($_.Name.StartsWith('.') -or ([int]$_.Attributes -band 2)) }
            })
            foreach ($k in $kids) { if ($Folders -or -not ([int]$k.Attributes -band 16)) { & $add $k } }
        }
    }
    process {
        if (-not $r) { return }
        foreach ($p in $Path) {
            $given.N++
            & $list $p
        }
    }
    end {
        if (-not $r) { return }
        if (-not $given.N -and -not $MyInvocation.ExpectingInput) { & $list '.' }
        $plan = @(foreach ($key in @($items.Keys)) {
            $i = $items[$key]
            if ($r.Case) { $name = $i.Name -creplace $r.Rx, $r.Rep } else { $name = $i.Name -replace $r.Rx, $r.Rep }
            if ($name -ceq $i.Name) { continue }
            $dir = $i.FullName.Substring(0, $i.FullName.Length - $i.Name.Length).TrimEnd('\', '/')
            if (-not $dir) { $dir = $i.FullName.Substring(0, 1) }
            @{ Old = $i.FullName; Dir = $dir; OldName = $i.Name; NewName = $name; New = (Join-Path $dir $name); IsDir = [bool]([int]$i.Attributes -band 16); Chain = $false; Tmp = '' }
        })
        if (-not $plan.Count) { Write-Host 'rnm: no names to change.' -ForegroundColor DarkGray; return }
        $plan = @($plan | Sort-Object @{ Expression = { @($_.Old -split '[\\/]').Count }; Descending = $true }, @{ Expression = { $_.Old } })
        $sources = @{}
        foreach ($p in $plan) { $sources[$p.Old.ToLower()] = $p }
        $targets = @{}
        $problems = @(foreach ($p in $plan) {
            $bad = $p.NewName -match '[<>:"/\\|?*\x00-\x1F]|[. ]$|^$' -or $p.NewName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
            if ($bad) { "'$($p.OldName)' would get the name '$($p.NewName)', which is not a valid file name."; continue }
            $key = $p.New.ToLower()
            if ($targets.ContainsKey($key)) { "'$($p.OldName)' and '$($targets[$key].OldName)' would get the same name '$($p.NewName)'."; continue }
            $targets[$key] = $p
            if ($key -eq $p.Old.ToLower() -or -not (Test-Path -LiteralPath $p.New)) { continue }
            $other = $sources[$key]
            if (-not $other) { "'$($p.NewName)' already exists, so '$($p.OldName)' cannot take that name."; continue }
            if ($p.IsDir -or $other.IsDir) { "'$($p.OldName)' would take the name of the folder or file '$($other.OldName)', which also changes. Rename the folders in two steps."; continue }
            $p.Chain = $true
            $other.Chain = $true
        })
        $dirShown = ''
        foreach ($p in $plan) {
            if ($toHost) {
                if ($p.Dir -cne $dirShown) { Write-Host $p.Dir -ForegroundColor Magenta; $dirShown = $p.Dir }
                Write-Host ('  ' + $p.OldName) -ForegroundColor Red -NoNewline
                Write-Host ' -> ' -ForegroundColor DarkGray -NoNewline
                Write-Host $p.NewName -ForegroundColor Green
            } else {
                New-Object PSObject -Property @{ Path = $p.Old; NewName = $p.NewName } | Select-Object Path, NewName
            }
        }
        if ($problems.Count) {
            foreach ($m in $problems) { Write-Error "rnm: $m" }
            Write-Host ('rnm: {0} problem(s). No name changed.' -f $problems.Count) -ForegroundColor Yellow
            return
        }
        if (-not $Apply) {
            Write-Host ('rnm: preview of {0} name(s). No name changed. Add -Apply to rename.' -f $plan.Count) -ForegroundColor Cyan
            return
        }
        $journal = @{}
        $move = {
            param($From, $Dir, $Name)
            Rename-Item -LiteralPath $From -NewName $Name -Force -ErrorAction Stop
            $journal[$journal.Count] = @{ From = $From; To = (Join-Path $Dir $Name); Back = ($From -split '[\\/]')[-1] }
        }
        $stamp = 'ps-profile-rnm-' + (Get-Random)
        $seq = 0
        try {
            foreach ($p in $plan) {
                if (-not $p.Chain) { continue }
                $seq++
                $p.Tmp = "$stamp-$seq"
                & $move $p.Old $p.Dir $p.Tmp
            }
            foreach ($p in $plan) {
                if ($p.Chain) { & $move (Join-Path $p.Dir $p.Tmp) $p.Dir $p.NewName; continue }
                if ($p.Old -ieq $p.New) {
                    $seq++
                    $via = "$stamp-$seq"
                    & $move $p.Old $p.Dir $via
                    & $move (Join-Path $p.Dir $via) $p.Dir $p.NewName
                    continue
                }
                & $move $p.Old $p.Dir $p.NewName
            }
        } catch {
            Write-Error "rnm: a rename failed, so the renames made so far are being undone. $($_.Exception.Message)"
            for ($k = $journal.Count - 1; $k -ge 0; $k--) {
                $j = $journal[$k]
                try { Rename-Item -LiteralPath $j.To -NewName $j.Back -Force -ErrorAction Stop }
                catch { Write-Error "rnm: could not undo '$($j.To)'. Its old name is '$($j.Back)'." }
            }
            return
        }
        Write-Host ('rnm: renamed {0} item(s).' -f $plan.Count) -ForegroundColor Cyan
    }
}

function global:Get-PSProfileAppLocker {
    [OutputType([hashtable])]
    param()
    $state = @{ Available = $false; Policy = $null; Rules = 0; Audit = $false; Error = '' }
    if (-not (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) -or -not (Get-Command Test-AppLockerPolicy -ErrorAction SilentlyContinue)) { return $state }
    $state.Available = $true
    try {
        $state.Policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
    } catch {
        $state.Error = $_.Exception.Message
        return $state
    }
    if (-not $state.Policy.PSObject.Properties['RuleCollections']) {
        $state.Rules = -1
        return $state
    }
    foreach ($c in @(Get-PSProfileProperty $state.Policy 'RuleCollections')) {
        if ($null -eq $c) { continue }
        $state.Rules += @($c).Count
        if ("$(Get-PSProfileProperty $c 'EnforcementMode')" -match 'Audit') { $state.Audit = $true }
    }
    $state
}

function global:New-PSProfileCheck([string]$Check, [string]$Status, [string]$Detail) {
    New-Object PSObject -Property @{ Check = $Check; Status = $Status; Detail = $Detail } | Select-Object Status, Check, Detail
}

function global:Test-PSProfileWritable {
    [OutputType([bool])]
    param([string]$Dir)
    if (-not $Dir) { return $false }
    $probe = Join-Path $Dir ('ps-profile-probe-' + (Get-Random))
    try {
        Set-Content -LiteralPath $probe -Value '' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        $true
    } catch {
        $false
    }
}

function global:doctor {
    [CmdletBinding()]
    param()
    $toHost = Test-PSProfileToHost $MyInvocation
    $rows = @(
        New-PSProfileCheck 'Profile version' 'INFO' $global:PSProfileVersion
        New-PSProfileCheck 'PowerShell version' 'INFO' "$($PSVersionTable.PSVersion)"
        New-PSProfileCheck 'Language mode' 'INFO' "$($ExecutionContext.SessionState.LanguageMode)"
        New-PSProfileCheck 'Execution policy' 'INFO' "$(Get-ExecutionPolicy)"
        foreach ($d in @(@('Data folder', $global:PSProfileDataDir), @('Temp folder', $env:TEMP))) {
            if (Test-PSProfileWritable $d[1]) { New-PSProfileCheck $d[0] 'OK' $d[1] }
            else { New-PSProfileCheck $d[0] 'FAIL' "Cannot write to '$($d[1])'." }
        }
        $needs = [ordered]@{
            'Expand-Archive'       = 'rg -Office, bat, delta and the preview of Office files'
            'Get-Clipboard'        = 'pb'
            'Set-Clipboard'        = 'cb, cpath, Ctrl+R and Ctrl+T'
            'Start-Job'            = 'the background index build'
            'Set-PSReadLineOption' = 'Ctrl+R and Ctrl+T'
        }
        foreach ($k in $needs.Keys) {
            if (Get-Command $k -ErrorAction SilentlyContinue) { New-PSProfileCheck $k 'OK' $needs[$k] }
            else { New-PSProfileCheck $k 'WARN' "Missing. These do not work: $($needs[$k])." }
        }
        $state = Get-PSProfileAppLocker
        if (-not $state.Available) { New-PSProfileCheck 'AppLocker' 'WARN' 'The AppLocker commands are missing.' }
        elseif ($state.Error) { New-PSProfileCheck 'AppLocker' 'WARN' "Cannot read the policy: $($state.Error)" }
        elseif ($state.Rules -lt 0) { New-PSProfileCheck 'AppLocker' 'WARN' 'Cannot count the rules in the policy.' }
        elseif ($state.Rules -eq 0) { New-PSProfileCheck 'AppLocker' 'INFO' 'No rules in Group Policy. Rules from MDM do not show here.' }
        elseif ($state.Audit) { New-PSProfileCheck 'AppLocker' 'INFO' "$($state.Rules) rule(s), some in audit mode." }
        else { New-PSProfileCheck 'AppLocker' 'INFO' "$($state.Rules) rule(s)." }
        if (-not $global:PSProfileRoots.Count) { New-PSProfileCheck 'Share roots' 'INFO' 'None set.' }
        foreach ($root in $global:PSProfileRoots) {
            if (Test-Path -LiteralPath $root.Unc) { New-PSProfileCheck 'Share root' 'OK' $root.Unc }
            else { New-PSProfileCheck 'Share root' 'FAIL' "Cannot reach '$($root.Unc)'." }
            $idx = Get-Item -LiteralPath "$($root.Base).idx" -ErrorAction SilentlyContinue
            if (-not $idx) { New-PSProfileCheck 'Index' 'WARN' "No index for '$($root.Unc)'. Run Update-Index."; continue }
            if (Test-Path -LiteralPath "$($root.Base).partial") { New-PSProfileCheck 'Index' 'WARN' "The build for '$($root.Unc)' did not end. Run Update-Index."; continue }
            $hours = ((Get-Date) - $idx.LastWriteTime).TotalHours
            if ($hours -gt 24) { New-PSProfileCheck 'Index' 'WARN' ("'{0}' is {1:0} hours old. Run Update-Index." -f $root.Unc, $hours) }
            else { New-PSProfileCheck 'Index' 'OK' ("'{0}' is {1:0} hours old." -f $root.Unc, $hours) }
        }
    )
    if (-not $toHost) { return $rows }
    $colors = @{ OK = 'Green'; INFO = 'DarkGray'; WARN = 'Yellow'; FAIL = 'Red' }
    foreach ($row in $rows) {
        Write-Host ('{0,-5} ' -f $row.Status) -ForegroundColor $colors[$row.Status] -NoNewline
        Write-Host ('{0,-21} ' -f $row.Check) -ForegroundColor Cyan -NoNewline
        Write-Host $row.Detail
    }
}

$global:PSProfileTldr = [ordered]@{
    'fd'           = 'Find files by name. Uses the index under ShareRoots.',
                     'fd report  # Files and folders with report in the name',
                     "fd '\.pdf$' S:\Finance  # PDF files under a folder",
                     'fd -e docx,xlsx  # Files with these extensions',
                     'fd -t d report  # Folders only (-t f for files only)',
                     'fd -H config  # Also show hidden files and dot files',
                     'fd -I build  # Also show files that .gitignore ignores',
                     'fd Report  # An upper-case letter makes the search case-sensitive',
                     'fd -Changed 30d  # Files changed in the last 30 days',
                     'fd -Size +1MB  # Files of 1 MB or more (-10KB for 10 KB or less)'
    'recent'       = 'The most recently changed files under the current folder.',
                     'recent  # 20 files changed in the last 7 days',
                     'recent -Days 30 -Count 50  # 50 files changed in the last 30 days'
    'rg'           = 'Search file content. Alias grep.',
                     'rg TODO  # Lines with TODO under the current folder',
                     'rg invoice  # Lower-case text ignores case',
                     'rg Invoice  # An upper-case letter makes the search case-sensitive',
                     'rg -s invoice  # Always case-sensitive',
                     'rg -i Invoice -g *.txt  # Always ignore case, only .txt files',
                     'rg -v debug log.txt  # Lines that do not match',
                     'rg -w cat notes.txt  # Whole words only',
                     'rg -u token  # Also search files that .gitignore ignores',
                     'rg -Hidden token  # Also search hidden files and dot files',
                     'rg -A 2 -B 1 error log.txt  # 2 lines after and 1 before each match',
                     'ipconfig | rg -n IPv4  # Filter piped text. -n adds line numbers',
                     'rg budget -Office  # Also search .docx, .xlsx and .pptx files',
                     'rg error -C 2  # Show 2 lines before and after each match',
                     'fd -Ext csv | rg total  # Search only the files that fd finds'
    'grep'         = 'Alias of rg.',
                     'grep -i error log.txt  # Same as rg -i error log.txt'
    'fzf'          = 'Pick an item from a list. Type text to filter. The preview shows item 1.',
                     'fd report | fzf  # Pick a file. Type #2 to pick item 2.',
                     'Get-Process | fzf  # Pick any object'
    'bat'          = 'Show a file with line numbers. Office files show as text.',
                     'bat notes.txt  # Whole file',
                     'bat report.docx  # Text of a Word file',
                     'bat log.txt -Range 100-200  # Lines 100 to 200',
                     'bat log.txt -Pattern error  # Highlight error'
    'z'            = 'Go to a folder that you used before. zi shows a picker.',
                     'z fin  # Best folder that matches fin',
                     'zi  # Pick a folder from the list'
    'zi'           = 'Pick a folder that you used before.',
                     'zi fin  # Pick from the folders that match fin'
    'cd'           = 'Change folder and record the visit for z.',
                     'cd S:\Finance  # Go to a folder',
                     'cd -  # Go back to the previous folder'
    'up'           = 'Go to a parent folder. .. and ... go up one and two levels.',
                     'up 3  # Go up three levels'
    'mkcd'         = 'Create a folder and enter it.',
                     'mkcd reports\2026  # Create the folders and enter the last one'
    'ls'           = 'List files. Colors show the file type.',
                     'ls *.txt  # List the text files'
    'll'           = 'List files, also hidden files.',
                     'll  # All items in the current folder'
    'head'         = 'Show the first lines.',
                     'head notes.txt -n 5  # First 5 lines of a file',
                     'head -5 notes.txt  # Same as -n 5',
                     'fd report | head -n 3  # First 3 items of piped input'
    'tail'         = 'Show the last lines.',
                     'tail log.txt -n 5  # Last 5 lines of a file',
                     'tail -5 log.txt  # Same as -n 5',
                     'tail -f log.txt  # Show new lines as they arrive. Press Ctrl+C to stop.'
    'wc'           = 'Count lines, words and characters.',
                     'wc notes.txt  # All the counts',
                     'wc -l notes.txt  # Only the number of lines',
                     'fd report | wc -l  # Count piped lines. -w counts words and -c characters.'
    'which'        = 'Show what a command name runs.',
                     'which git  # Path, alias or command type'
    'touch'        = 'Create a file or update its change time.',
                     'touch notes.txt  # Create or update the file'
    'cpath'        = 'Copy paths to the clipboard.',
                     'cpath  # Copy the current folder',
                     'fd report | cpath  # Copy the piped paths'
    'unc'          = 'Show the UNC path of a mapped drive path.',
                     'unc S:\Finance  # The \\server\share form of the path'
    'cb'           = 'Copy piped input to the clipboard.',
                     'Get-Date | cb  # Copy the output as text'
    'pb'           = 'Get the clipboard text.',
                     'pb | wc -l  # Count the lines on the clipboard'
    'open'         = 'Open a file with its default program.',
                     'open report.xlsx  # Open the file'
    'ep'           = 'Open the profile in Notepad.',
                     'ep  # Edit the profile'
    'reload'       = 'Load the profile again.',
                     'reload  # Use the changes to the profile'
    'delta'        = 'Show the differences between two files. Office files are compared as text.',
                     'delta old.docx new.docx  # Changes between two Word files',
                     'delta -s old.txt new.txt  # Side by side'
    'sd'           = 'Replace text in files. Shows a preview until you add -Apply.',
                     "sd 'old' 'new'  # Preview the changes under the current folder",
                     "sd 'old' 'new' -Apply  # Write the changes",
                     "sd 'v(\d+)' 'version `$1' notes.txt  # Use a regex group. Use single quotes.",
                     "sd -F 'a.b' 'a_b'  # Plain text, not a regex",
                     "sd -g *.txt 'old' 'new'  # Only .txt files",
                     "fd -e csv | sd 'old' 'new' -Apply  # Only the files that fd finds"
    'sd-undo'      = 'Restore the files that the last sd -Apply changed.',
                     'sd-undo  # Skips a file that changed after sd ran'
    'rnm'          = 'Rename files by regex. Shows a preview until you add -Apply.',
                     "rnm 'draft' 'final'  # Preview for the current folder",
                     "rnm 'draft' 'final' -Apply  # Rename the files",
                     "rnm '^(\d+)-' 'item-`$1-' -r  # Also in subfolders",
                     "rnm 'old' 'new' -Folders  # Also rename folders",
                     "fd -t d temp | rnm 'temp' 'tmp'  # Rename the folders that fd finds"
    'doctor'       = 'Check what the profile can use on this computer.',
                     'doctor  # Language mode, folders, commands, share roots and index'
    'Update-Index' = 'Build or refresh the file index for ShareRoots.',
                     'Update-Index  # All share roots',
                     "Update-Index 'S:\Finance\2026'  # One folder"
    'Ctrl+R'       = 'Key. Pick a command from the full history. The pick goes to the clipboard.',
                     'Ctrl+R  # Pick a command, then press Ctrl+V to insert it'
    'Ctrl+T'       = 'Key. Pick a file under the current folder. The path goes to the clipboard.',
                     'Ctrl+T  # Pick a file, then press Ctrl+V to insert its path'
    'tldr'         = 'Examples for the profile commands.',
                     'tldr  # List the commands',
                     'tldr fd  # Examples for fd'
}

function global:tldr([string]$Name) {
    $toHost = Test-PSProfileToHost $MyInvocation
    if (-not $Name) {
        foreach ($k in $global:PSProfileTldr.Keys) {
            if ($toHost) {
                Write-Host ('{0,-13} ' -f $k) -ForegroundColor Cyan -NoNewline
                Write-Host $global:PSProfileTldr[$k][0]
            } else {
                '{0,-13} {1}' -f $k, $global:PSProfileTldr[$k][0]
            }
        }
        return
    }
    $e = $global:PSProfileTldr[$Name]
    if (-not $e) { Write-Error "tldr: no page for '$Name'. Run tldr to see the list."; return }
    if ($toHost) { Write-Host $e[0] -ForegroundColor Cyan } else { $e[0] }
    for ($i = 1; $i -lt $e.Count; $i++) {
        $p = $e[$i] -split '  # ', 2
        if ($toHost) {
            Write-Host ''
            Write-Host ('  ' + $p[1]) -ForegroundColor DarkGray
            Write-Host ('    ' + $p[0]) -ForegroundColor Green
            continue
        }
        ''
        '  ' + $p[1]
        '    ' + $p[0]
    }
}

function global:Copy-PSProfilePick([string]$Pick) {
    Set-Clipboard -Value $Pick
    Write-Host 'Copied. Press Ctrl+V to insert it.' -ForegroundColor DarkGray
}

if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Chord Ctrl+r -BriefDescription PickHistory -Description 'Pick a command from the full history and copy it' -ScriptBlock {
        Write-Host ''
        $pick = Get-PSProfileHistory | fzf
        if ($pick) { Copy-PSProfilePick $pick }
    }
    Set-PSReadLineKeyHandler -Chord Ctrl+t -BriefDescription PickFile -Description 'Pick a file under the current folder and copy its path' -ScriptBlock {
        Write-Host ''
        $pick = @(Find-PSProfileFile -SkipHidden -UseIgnore -Meta -Limit 20000) -notlike "`t*" | ForEach-Object { $_.Split("`t")[2] } | fzf
        if ($pick) { Copy-PSProfilePick (ConvertTo-PSProfileQuoted $pick) }
    }
}

Register-ArgumentCompleter -CommandName z, zi -ParameterName Query -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    Get-PSProfileZ @($wordToComplete.Trim("'", '"')) | ForEach-Object { ConvertTo-PSProfileQuoted $_ }
}

Register-ArgumentCompleter -CommandName tldr -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $global:PSProfileTldr.Keys | Where-Object { $_ -like "$wordToComplete*" }
}

function global:Set-PSProfileLocation([string]$Path) {
    try { Set-Location -LiteralPath $Path -ErrorAction Stop } catch { Write-Error $_; return }
    $loc = Get-Location
    if ($loc.Provider.Name -eq 'FileSystem') { Add-PSProfileZ $loc.ProviderPath }
}
function global:.. { Set-PSProfileLocation '..' }
function global:... { Set-PSProfileLocation '../..' }
function global:up([int]$N = 1) {
    if ($N -lt 1) { return }
    Set-PSProfileLocation ((@('..') * $N) -join '/')
}
function global:mkcd([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-PSProfileLocation $Path
}

function global:which([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { Write-Error "which: '$Name' not found."; return }
    if ($c.CommandType -eq 'Application') { $c.Source }
    elseif ($c.CommandType -eq 'Alias') { '{0} -> {1}' -f $c.Name, $c.Definition }
    else { '{0} {1}' -f $c.CommandType, $c.Name }
}

function global:touch {
    foreach ($p in $args) {
        if (Test-Path -LiteralPath $p) { Set-ItemProperty -LiteralPath $p -Name LastWriteTime -Value (Get-Date) }
        else { New-Item -ItemType File -Path $p | Out-Null }
    }
}

Set-Alias -Name grep -Value rg -Scope Global
Set-Alias -Name open -Value Invoke-Item -Scope Global
Set-Alias -Name pb -Value Get-Clipboard -Scope Global

function global:Resolve-PSProfileCount($Path, $Count) {
    if ("$Path" -match '^-(\d+)$') {
        $n = [int]$Matches[1]
        $file = ''
        if ("$Count" -notmatch '^\d+$') { $file = "$Count" }
        return @{ Path = $file; N = $n }
    }
    @{ Path = "$Path"; N = [int]$Count }
}

function global:head($Path, [Alias('n')]$Count = 10) {
    $a = Resolve-PSProfileCount $Path $Count
    if ($a.Path) { Get-Content -LiteralPath $a.Path -TotalCount $a.N } else { $input | Select-Object -First $a.N }
}

function global:tail($Path, [Alias('n')]$Count = 10, [Alias('f')][switch]$Follow) {
    $a = Resolve-PSProfileCount $Path $Count
    if ($a.Path) { Get-Content -LiteralPath $a.Path -Tail $a.N -Wait:$Follow } else { $input | Select-Object -Last $a.N }
}

function global:wc([Alias('l')][switch]$Lines, [Alias('w')][switch]$Words, [Alias('c', 'm')][switch]$Chars) {
    $field = ''
    if ($Lines) { $field = 'Lines' } elseif ($Words) { $field = 'Words' } elseif ($Chars) { $field = 'Chars' }
    $paths = @($args)
    $texts = @(if ($paths.Count) {
        foreach ($p in $paths) { @{ Path = $p; Text = Read-PSProfileText $p } }
    } else {
        $pipedLines = @($input | ForEach-Object { "$_" })
        if ($pipedLines.Count) { @{ Path = ''; Text = ($pipedLines -join "`n") + "`n" } }
        elseif ($field) { @{ Path = ''; Text = '' } }
    })
    foreach ($t in $texts) {
        $s = '' + $t.Text
        $counts = @{
            Lines = [regex]::Matches($s, "`n").Count
            Words = [regex]::Matches($s, '\S+').Count
            Chars = $s.Length
            Path  = $t.Path
        }
        if ($field) { $counts[$field]; continue }
        New-Object PSObject -Property $counts | Select-Object Lines, Words, Chars, Path
    }
}

$global:PSProfileColors = @{
    '.exe' = 'Green'; '.bat' = 'Green'; '.cmd' = 'Green'; '.ps1' = 'Green'; '.com' = 'Green'; '.msi' = 'Green'
    '.docx' = 'Yellow'; '.xlsx' = 'Yellow'; '.pptx' = 'Yellow'; '.doc' = 'Yellow'; '.xls' = 'Yellow'; '.ppt' = 'Yellow'
    '.xlsm' = 'Yellow'; '.docm' = 'Yellow'; '.pptm' = 'Yellow'
    '.zip' = 'Magenta'; '.7z' = 'Magenta'; '.rar' = 'Magenta'; '.tar' = 'Magenta'; '.gz' = 'Magenta'; '.cab' = 'Magenta'
}

function global:Show-PSProfileListing([object[]]$Items) {
    $parent = $null
    foreach ($i in $Items) {
        if ($null -eq (Get-PSProfileProperty $i 'PSIsContainer')) { $i; continue }
        $dir = Split-Path -Parent $i.FullName
        if ($dir -ne $parent) {
            Write-Host "`n    Directory: $dir`n"
            $parent = $dir
        }
        $len = ''
        if (-not $i.PSIsContainer) { $len = $i.Length }
        Write-Host ('{0,-7} {1,16} {2,12} ' -f $i.Mode, $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $len) -NoNewline
        $c = 'Gray'
        if ($i.PSIsContainer) { $c = 'Cyan' }
        elseif ($global:PSProfileColors.ContainsKey($i.Extension.ToLower())) { $c = $global:PSProfileColors[$i.Extension.ToLower()] }
        Write-Host $i.Name -ForegroundColor $c
    }
}

Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
function global:ls {
    $items = Get-ChildItem @args
    if (Test-PSProfileToHost $MyInvocation) { Show-PSProfileListing $items } else { $items }
}
function global:ll {
    $items = Get-ChildItem -Force @args
    if (Test-PSProfileToHost $MyInvocation) { Show-PSProfileListing $items } else { $items }
}

function global:ep { notepad.exe $PROFILE }
function global:reload { . $PROFILE }

function global:cpath {
    $p = @($input | ForEach-Object { Get-PSProfileItemPath $_ })
    if (-not $p.Count) { $p = @((Get-Location).ProviderPath) }
    Set-Clipboard -Value $p
}

function global:unc([string]$Path) {
    $p = @($input | ForEach-Object { Get-PSProfileItemPath $_ })
    if (-not $p.Count) { $p = @($Path) }
    foreach ($x in $p) { ConvertTo-PSProfileUnc (Get-PSProfileFullPath $x) }
}

function global:cb {
    $items = @($input)
    $strings = @($items | Where-Object { $_ -is [string] })
    if ($strings.Count -eq $items.Count) { Set-Clipboard -Value $items }
    else { Set-Clipboard -Value (($items | Out-String -Width 4096).TrimEnd()) }
}

function global:Find-PSProfileGitDir {
    [OutputType([string])]
    param([string]$Path)
    if (-not $Path -or (ConvertTo-PSProfileUnc $Path) -like '\\*') { return '' }
    $dir = $Path
    while ($dir) {
        $git = Join-Path $dir '.git'
        if (Test-Path -LiteralPath $git -PathType Container) { return $git }
        if (Test-Path -LiteralPath $git -PathType Leaf) {
            $line = Get-Content -LiteralPath $git -TotalCount 1 -ErrorAction SilentlyContinue
            if ($line -notmatch '^gitdir:\s*(.+)$') { return '' }
            $target = $Matches[1]
            if ($target -notmatch '^([A-Za-z]:|[\\/])') { $target = Join-Path $dir $target }
            return $target
        }
        $dir = Split-Path -Parent $dir
    }
    ''
}

function global:Get-PSProfileGitBranch {
    [OutputType([string])]
    param([string]$GitDir)
    if (-not $GitDir) { return '' }
    $head = Get-Content -LiteralPath (Join-Path $GitDir 'HEAD') -TotalCount 1 -ErrorAction SilentlyContinue
    if ($head -match '^ref: refs/heads/(.+)$') { return $Matches[1] }
    if ($head -match '^[0-9a-f]{7}') { return $Matches[0] }
    ''
}

function global:prompt {
    $ok = $?
    $h = Get-History -Count 1
    if ($h -and $h.Id -ne $global:PSProfileLastId) {
        $global:PSProfileLastId = $h.Id
        if (-not $ok) { Write-Host 'x ' -ForegroundColor Red -NoNewline }
        $sec = ($h.EndExecutionTime - $h.StartExecutionTime).TotalSeconds
        if ($sec -gt 2) { Write-Host ('{0:0.0}s ' -f $sec) -ForegroundColor DarkYellow -NoNewline }
    }
    $state = Get-PSProfileIndexState
    if ($state) { Write-Host "[index $state] " -ForegroundColor Yellow -NoNewline }
    $loc = Get-Location
    $p = $loc.Path
    if ($p -ne $global:PSProfileLastPwd) {
        if ($global:PSProfileLastPwd) { $global:PSProfileOldPwd = $global:PSProfileLastPwd }
        $global:PSProfileLastPwd = $p
        $global:PSProfileGitDir = ''
        if ($loc.Provider.Name -eq 'FileSystem') {
            try { $global:PSProfileGitDir = Find-PSProfileGitDir $loc.ProviderPath } catch { $global:PSProfileGitDir = '' }
        }
    }
    if ($loc.Provider.Name -eq 'FileSystem') { $p = $loc.ProviderPath }
    $sep = '\'
    if ($p.StartsWith('/')) { $sep = '/' }
    $parts = @($p -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -gt 3) { $p = '..' + $sep + $parts[-2] + $sep + $parts[-1] }
    Write-Host $p -ForegroundColor Cyan -NoNewline
    $branch = Get-PSProfileGitBranch $global:PSProfileGitDir
    if ($branch) { Write-Host " ($branch)" -ForegroundColor Magenta -NoNewline }
    '> '
}

if ((Get-PSProfileIndexState) -eq 'old') {
    $roots = ($global:PSProfileRoots | ForEach-Object { $_.Unc }) -join "`n"
    try {
        Start-Job -Name 'ps-profile-index' -ScriptBlock $global:PSProfileIndexBuilder -ArgumentList $roots, $global:PSProfileDataDir, '', 10, 24 -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "The index job did not start: $($_.Exception.Message) Run Update-Index."
    }
    Remove-Variable roots
}
