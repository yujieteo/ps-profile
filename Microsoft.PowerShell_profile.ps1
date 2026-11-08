$global:PSProfileVersion = '1.2.0'
$global:ShareRoots = @()

$global:PSProfileDataDir = Join-Path $env:LOCALAPPDATA 'ps-profile'
if (-not (Test-Path -LiteralPath $global:PSProfileDataDir)) {
    New-Item -ItemType Directory -Path $global:PSProfileDataDir -Force | Out-Null
}
if (-not $global:PSProfileIndexCache) { $global:PSProfileIndexCache = @{} }
$global:PSProfileRootsFile = Join-Path $global:PSProfileDataDir 'share-roots.txt'
if (Test-Path -LiteralPath $global:PSProfileRootsFile) {
    $global:ShareRoots += @(Get-Content -LiteralPath $global:PSProfileRootsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    $global:PSProfileByteArgs = @{ Encoding = 'Byte' }
    $global:PSProfileAnsi = 'Default'
    $global:PSDefaultParameterValues['Out-File:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Set-Content:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Add-Content:Encoding'] = 'UTF8'
    $global:PSDefaultParameterValues['Export-Csv:Encoding'] = 'UTF8'
} else {
    $global:PSProfileByteArgs = @{ AsByteStream = $true }
    $global:PSProfileAnsi = 1252
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

function global:Read-PSProfileText {
    [OutputType([string])]
    param([string]$Path)
    $byteArgs = $global:PSProfileByteArgs
    $b = @(Get-Content -LiteralPath $Path -TotalCount 4 @byteArgs -ErrorAction SilentlyContinue)
    $enc = 'UTF8'
    if ($b.Count -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = 'Unicode' }
    elseif ($b.Count -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $enc = 'BigEndianUnicode' }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding $enc -ErrorAction SilentlyContinue
    if ($null -eq $text) { return '' }
    if ($enc -eq 'UTF8' -and $text.IndexOf([char]0xFFFD) -ge 0) {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding $global:PSProfileAnsi
    }
    if ($text.IndexOf([char]0) -ge 0) { return $null }
    $text
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
            $name = $root -replace '[^A-Za-z0-9]+', '_'
            $base = Join-Path $DataDir ('idx2_' + $name)
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
                            $files = @($kids | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
                                $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks
                            }) -join '|'
                            $subs = @($kids | Where-Object { $_.PSIsContainer -and -not ([int]$_.Attributes -band 1024) } | ForEach-Object { $_.Name }) -join '|'
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
            $oldBase = Join-Path $DataDir ('idx_' + $name)
            Remove-Item -LiteralPath "$oldBase.idx", "$oldBase.state" -Force -ErrorAction SilentlyContinue
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

function global:Find-PSProfileFile {
    [CmdletBinding()]
    param(
        [string]$Pattern = '.',
        [string]$Path = '.',
        [string[]]$Ext,
        [string]$Changed,
        [string]$Size,
        [switch]$Meta,
        [int]$Limit = 0
    )
    $filter = $Ext -or $Changed -or $Size
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
        $scan = @(Get-ChildItem -LiteralPath $typed -Recurse -Force -File:$filter -ErrorAction SilentlyContinue | Select-Object -First $take)
        if ($Limit -gt 0 -and $scan.Count -ge $Limit) { Write-Warning "fd: stopped after $Limit items. Give a smaller folder." }
        foreach ($i in $scan) {
            if ($i.Name -notmatch $Pattern) { continue }
            if ($extRx -and $i.Name -notmatch $extRx) { continue }
            if ($since -and $i.LastWriteTimeUtc.Ticks -lt [long]$since) { continue }
            if ($min -ge 0 -and $i.Length -lt $min) { continue }
            if ($max -ge 0 -and $i.Length -gt $max) { continue }
            if (-not $Meta) { $i.FullName }
            elseif ($i.PSIsContainer) { "`t`t" + $i.FullName }
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
    $hits = @($lines) -match $full
    $hits = $hits -like ("*`t" + ($uncPrefix -replace '([\[\]\*\?`])', '`$1') + '*')
    if ($extRx) { $hits = $hits -match $extRx }
    if ($since) { $hits = $hits -ge $since }
    foreach ($h in $hits) {
        $f = $h.Split("`t")
        $leaf = $f[2].Substring($f[2].LastIndexOf($sep) + 1)
        if ($leaf -notmatch $Pattern) { continue }
        if ($filter -and -not $f[1]) { continue }
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
        [string[]]$Ext,
        [string]$Changed,
        [string]$Size
    )
    Find-PSProfileFile @PSBoundParameters
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
    $lines = @(Find-PSProfileFile -Path $Path -Changed "${Days}d" -Meta | Sort-Object -Descending | Select-Object -First $Count)
    foreach ($l in $lines) {
        $f = $l.Split("`t")
        if (-not $toHost) { $f[2]; continue }
        $t = (New-Object DateTime ([long]$f[0]), 'Utc').ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Write-Host ('{0}  {1,10}  ' -f $t, (Format-PSProfileSize $f[1])) -ForegroundColor DarkGray -NoNewline
        Write-Host $f[2]
    }
}

function global:Write-PSProfileMatchLine([string]$Line, [System.Text.RegularExpressions.Match[]]$Matches_) {
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
        [Alias('l')][switch]$FilesWithMatches,
        [int]$MaxSizeMB = 20,
        [switch]$Office
    )
    begin {
        $toHost = Test-PSProfileToHost $MyInvocation
        $rx = $Pattern
        if ($SimpleMatch) { $rx = [regex]::Escape($Pattern) }
        $skipped = @{ Legacy = 0; Large = 0 }
        $seen = 0
        $search = {
            param($file)
            if ($Glob) {
                $ok = $false
                foreach ($g in $Glob) { if ($file.Name -like $g) { $ok = $true } }
                if (-not $ok) { return }
            }
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
            if ($IgnoreCase) { $any = $lines -match $rx } else { $any = $lines -cmatch $rx }
            if (-not $any) { return }
            $ms = @($lines | Select-String -Pattern $rx -CaseSensitive:(-not $IgnoreCase) -AllMatches)
            if (-not $ms.Count) { return }
            if ($FilesWithMatches) { $file.FullName; return }
            if (-not $toHost) {
                foreach ($m in $ms) {
                    $n = $m.LineNumber - 1
                    $a = $n - $Context
                    if ($a -lt 0) { $a = 0 }
                    $b = $n + $Context
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
            $hit = @{}
            foreach ($m in $ms) { $hit[$m.LineNumber - 1] = $m.Matches }
            $show = @{}
            foreach ($n in $hit.Keys) {
                for ($j = $n - $Context; $j -le $n + $Context; $j++) {
                    if ($j -ge 0 -and $j -lt $lines.Count) { $show[$j] = $true }
                }
            }
            $last = -2
            foreach ($j in ($show.Keys | Sort-Object)) {
                if ($Context -and $last -ge 0 -and $j -gt $last + 1) { Write-Host '--' -ForegroundColor DarkGray }
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
            if (-not $item.PSIsContainer) { & $search $item; return }
            $unc = ConvertTo-PSProfileUnc $full
            $root = Find-PSProfileRoot $unc
            if ($unc -match '^\\\\[^\\]+\\[^\\]+\\?$' -or ($root -and $unc.TrimEnd('\', '/') -eq $root.Unc)) {
                Write-Error "rg: refusing a whole-share content search of '$full'. Give a folder or pipe fd results."
                return
            }
            Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { & $search $_ }
        }
        $piped = @{}
        $searchText = {
            $lines = @(for ($q = 0; $q -lt $piped.Count; $q++) { $piped[$q] })
            $ms = @($lines | Select-String -Pattern $rx -CaseSensitive:(-not $IgnoreCase) -AllMatches)
            if (-not $ms.Count) { return }
            if ($FilesWithMatches) { '(standard input)'; return }
            $hit = @{}
            foreach ($m in $ms) { $hit[$m.LineNumber - 1] = $m.Matches }
            $show = @{}
            foreach ($n in $hit.Keys) {
                for ($j = $n - $Context; $j -le $n + $Context; $j++) {
                    if ($j -ge 0 -and $j -lt $lines.Count) { $show[$j] = $true }
                }
            }
            $last = -2
            foreach ($j in ($show.Keys | Sort-Object)) {
                if ($Context -and $last -ge 0 -and $j -gt $last + 1) {
                    if ($toHost) { Write-Host '--' -ForegroundColor DarkGray } else { '--' }
                }
                $last = $j
                if (-not $toHost) { $lines[$j] }
                elseif ($hit.ContainsKey($j)) { Write-PSProfileMatchLine $lines[$j] $hit[$j] }
                else { Write-Host $lines[$j] -ForegroundColor DarkGray }
            }
        }
    }
    process {
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
            $top = @($cand | ForEach-Object {
                $t = $_
                $lower = $t.ToLower()
                $leaf = $t.LastIndexOf('\')
                if ($t.LastIndexOf('/') -gt $leaf) { $leaf = $t.LastIndexOf('/') }
                $leaf++
                $score = - $t.Length / 20
                for ($k = 0; $k -lt $tokens.Count; $k++) {
                    $at = $lower.IndexOf($tokens[$k].ToLower())
                    if ($at -ge 0) { $score += 100 } else {
                        $m = [regex]::Match($t, $rxs[$k])
                        $at = $m.Index
                        $score -= $m.Length - $tokens[$k].Length
                    }
                    if ($at -ge $leaf) { $score += 50 }
                    if ($at -eq $leaf) { $score += 25 }
                    if ($at -eq 0 -or $t.Substring($at - 1, 1) -match '[^A-Za-z0-9]') { $score += 15 }
                }
                New-Object PSObject -Property @{ Text = $t; Score = $score }
            } | Sort-Object Score -Descending | Select-Object -First 20 | ForEach-Object { $_.Text })
        } else {
            $top = @($cand | Select-Object -First 20)
        }
        $prev = @()
        if ($top.Count -and $width -ge 60) {
            for ($i = 0; $i -lt $texts.Count; $i++) {
                if ($texts[$i] -ceq $top[0]) { $prev = @(Get-PSProfilePreview $items[$i] 20); break }
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

function global:z {
    foreach ($p in @(Get-PSProfileZ $args)) {
        if (Enter-PSProfileZ $p) { return }
    }
    Write-Warning "z: no match for '$args'."
}

function global:zi {
    $pick = Get-PSProfileZ $args | fzf
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

function global:delta {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path1,
        [Parameter(Mandatory = $true, Position = 1)][string]$Path2
    )
    $toHost = Test-PSProfileToHost $MyInvocation
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
                if ($toHost) { Write-Host (' ' + $a[$op.A]) } else { ' ' + $a[$op.A] }
                $i++
                continue
            }
            $dels = @()
            while ($i -le $e -and $ops[$i].T -eq '-') { $dels += $ops[$i]; $i++ }
            $adds = @()
            while ($i -le $e -and $ops[$i].T -eq '+') { $adds += $ops[$i]; $i++ }
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
            $fmt = '{0,' + ('' + $last).Length + '} '
            for ($n = $from; $n -le $last; $n++) {
                Write-Host ($fmt -f $n) -ForegroundColor DarkGray -NoNewline
                $ms = $null
                if ($Pattern) { $ms = [regex]::Matches($lines[$n - 1], '(?i)' + $Pattern) }
                if ($ms -and $ms.Count) { Write-PSProfileMatchLine $lines[$n - 1] $ms } else { Write-Host $lines[$n - 1] }
            }
        }
    }
}

function global:du {
    param(
        [Parameter(Position = 0)][string]$Path = '.',
        [int]$Depth = 2
    )
    $toHost = Test-PSProfileToHost $MyInvocation
    $top = (Get-PSProfileFullPath $Path).TrimEnd('\', '/')
    $sep = '\'
    if ($top.StartsWith('/')) { $sep = '/' }
    if (-not $top) { $top = $sep }
    $size = @{ $top = [long]0 }
    $kids = @{ $top = @() }
    $own = @{}
    $entries = $null
    if (Find-PSProfileRoot (ConvertTo-PSProfileUnc $top)) {
        $entries = @(Find-PSProfileFile -Path $top -Meta | ForEach-Object {
            $f = $_.Split("`t")
            New-Object PSObject -Property @{ FullName = $f[2]; PSIsContainer = (-not $f[1]); Length = [long]('0' + $f[1]) }
        })
    } else {
        $entries = @(Get-ChildItem -LiteralPath $top -Recurse -Force -ErrorAction SilentlyContinue)
    }
    foreach ($i in $entries) {
        if ($i.FullName -eq $top) { continue }
        $parent = $i.FullName.Substring(0, $i.FullName.LastIndexOf($sep))
        if (-not $parent) { $parent = $sep }
        if ($i.PSIsContainer) {
            if (-not $size.ContainsKey($i.FullName)) { $size[$i.FullName] = [long]0; $kids[$i.FullName] = @() }
            if (-not $kids.ContainsKey($parent)) { $kids[$parent] = @() }
            $kids[$parent] += $i.FullName
        } else {
            $own[$parent] += $i.Length
        }
    }
    foreach ($d in @($own.Keys)) {
        $x = $d
        while ($true) {
            $size[$x] += $own[$d]
            if ($x.Length -le $top.Length) { break }
            $x = $x.Substring(0, $x.LastIndexOf($sep))
            if (-not $x) { $x = $sep }
        }
    }
    $show = {
        param($Dir, $Level)
        if ($toHost) {
            Write-Host ('{0,10}  ' -f (Format-PSProfileSize $size[$Dir])) -ForegroundColor DarkGray -NoNewline
            $name = $Dir
            if ($Level) { $name = ('  ' * $Level) + $Dir.Substring($Dir.LastIndexOf($sep) + 1) }
            Write-Host $name -ForegroundColor Cyan
        } else {
            New-Object PSObject -Property @{ Size = $size[$Dir]; Path = $Dir } | Select-Object Size, Path
        }
        if ($Level -lt $Depth) {
            foreach ($k in @($kids[$Dir] | Sort-Object { $size[$_] } -Descending)) { & $show $k ($Level + 1) }
        }
    }
    & $show $top 0
}

function global:rgi {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Pattern,
        [Parameter(Position = 1)][string[]]$Path,
        [Alias('i')][switch]$IgnoreCase,
        [switch]$Office
    )
    $a = @{ Pattern = $Pattern; IgnoreCase = $IgnoreCase; Office = $Office }
    if ($Path) { $a.Path = $Path }
    $pick = rg @a | fzf
    if ($pick) { Invoke-Item -LiteralPath $pick.Path }
}

function global:br {
    param([Parameter(Position = 0)][string]$Path = '.')
    $dir = Get-PSProfileFullPath $Path
    $sep = '\'
    if ($dir.StartsWith('/')) { $sep = '/' }
    while ($true) {
        $base = $dir.TrimEnd('\', '/')
        $items = @()
        $up = Split-Path -Parent $dir
        if ($up) { $items += New-Object PSObject -Property @{ Display = '..' + $sep; Path = $up; IsDir = $true } }
        $items += @(Get-ChildItem -LiteralPath $dir -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object {
            $d = $_.FullName.Substring($base.Length + 1)
            if ($_.PSIsContainer) { $d += $sep }
            New-Object PSObject -Property @{ Display = $d; Path = $_.FullName; IsDir = $_.PSIsContainer }
        } | Sort-Object Display)
        Write-Host "br: $dir" -ForegroundColor Magenta
        $pick = $items | fzf
        if (-not $pick) { return }
        if (-not $pick.IsDir) { Invoke-Item -LiteralPath $pick.Path; return }
        $dir = $pick.Path
    }
}

function global:Get-PSProfileHistory {
    $file = (Get-PSReadLineOption).HistorySavePath
    if (-not (Test-Path -LiteralPath $file)) { return }
    $cmds = @()
    $cur = ''
    foreach ($l in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        if ($l -match '`$') { $cur += $l.Substring(0, $l.Length - 1) + "`n"; continue }
        $cmds += $cur + $l
        $cur = ''
    }
    $seen = @{}
    for ($i = $cmds.Count - 1; $i -ge 0; $i--) {
        $c = $cmds[$i]
        if ($c.Trim() -and -not $seen.ContainsKey($c)) { $seen[$c] = $true; $c }
    }
}

$global:PSProfileTldr = [ordered]@{
    'fd'           = 'Find files by name. Uses the index under ShareRoots.',
                     'fd report  # Files and folders with report in the name',
                     "fd '\.pdf$' S:\Finance  # PDF files under a folder",
                     'fd -Ext docx,xlsx  # Files with these extensions',
                     'fd -Changed 30d  # Files changed in the last 30 days',
                     'fd -Size +1MB  # Files of 1 MB or more (-10KB for 10 KB or less)'
    'recent'       = 'The most recently changed files under the current folder.',
                     'recent  # 20 files changed in the last 7 days',
                     'recent -Days 30 -Count 50  # 50 files changed in the last 30 days'
    'rg'           = 'Search file content. Alias grep.',
                     'rg TODO  # Lines with TODO under the current folder',
                     'rg -i invoice -g *.txt  # Ignore case, only .txt files',
                     'rg budget -Office  # Also search .docx, .xlsx and .pptx files',
                     'rg error -C 2  # Show 2 lines before and after each match',
                     'fd -Ext csv | rg total  # Search only the files that fd finds',
                     'ipconfig | rg IPv4  # Filter piped text'
    'grep'         = 'Alias of rg.',
                     'grep -i error log.txt  # Same as rg -i error log.txt'
    'rgi'          = 'Content search in the picker. A pick opens the file.',
                     'rgi budget -Office  # Pick a match. The preview shows the lines around it.'
    'fzf'          = 'Pick an item from a list. Type text to filter. The preview shows item 1.',
                     'fd report | fzf  # Pick a file. Type #2 to pick item 2.',
                     'Get-Process | fzf  # Pick any object'
    'br'           = 'Browse folders in the picker. A folder enters it, a file opens it.',
                     'br  # Browse the current folder',
                     'br S:\Finance  # Browse a share folder'
    'bat'          = 'Show a file with line numbers. Office files show as text.',
                     'bat notes.txt  # Whole file',
                     'bat report.docx  # Text of a Word file',
                     'bat log.txt -Range 100-200  # Lines 100 to 200',
                     'bat log.txt -Pattern error  # Highlight error'
    'du'           = 'Folder sizes as a tree, largest first.',
                     'du  # Two levels under the current folder',
                     'du S:\Finance -Depth 1  # One level under a folder'
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
                     'fd report | head -n 3  # First 3 items of piped input'
    'tail'         = 'Show the last lines.',
                     'tail log.txt -n 5  # Last 5 lines of a file',
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
                     'delta old.docx new.docx  # Changes between two Word files'
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
    if (-not $Name) {
        foreach ($k in $global:PSProfileTldr.Keys) { '{0,-13} {1}' -f $k, $global:PSProfileTldr[$k][0] }
        return
    }
    $e = $global:PSProfileTldr[$Name]
    if (-not $e) { Write-Error "tldr: no page for '$Name'. Run tldr to see the list."; return }
    $e[0]
    for ($i = 1; $i -lt $e.Count; $i++) {
        $p = $e[$i] -split '  # ', 2
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
        $pick = @(Find-PSProfileFile -Meta -Limit 20000) -notlike "`t*" | ForEach-Object { $_.Split("`t")[2] } | fzf
        if ($pick) {
            if ($pick -match "[\s'`$&()\[\]{};,@#]") { $pick = "'" + ($pick -replace "'", "''") + "'" }
            Copy-PSProfilePick $pick
        }
    }
}

function global:.. { Set-Location .. }
function global:... { Set-Location ../.. }
function global:up([int]$N = 1) { Set-Location ((@('..') * $N) -join '/') }
function global:mkcd([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Location -LiteralPath $Path
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

function global:head([string]$Path, [Alias('n')][int]$Count = 10) {
    if ($Path) { Get-Content -LiteralPath $Path -TotalCount $Count } else { $input | Select-Object -First $Count }
}

function global:tail([string]$Path, [Alias('n')][int]$Count = 10, [Alias('f')][switch]$Follow) {
    if ($Path) { Get-Content -LiteralPath $Path -Tail $Count -Wait:$Follow } else { $input | Select-Object -Last $Count }
}

function global:wc {
    $field = ''
    $paths = @(foreach ($arg in $args) {
        if ($arg -ceq '-l') { $field = 'Lines' }
        elseif ($arg -ceq '-w') { $field = 'Words' }
        elseif ($arg -ceq '-c' -or $arg -ceq '-m') { $field = 'Chars' }
        else { $arg }
    })
    $texts = @(if ($paths.Count) {
        foreach ($p in $paths) { @{ Path = $p; Text = Read-PSProfileText $p } }
    } else {
        $lines = @($input | ForEach-Object { "$_" })
        if ($lines.Count) { @{ Path = ''; Text = ($lines -join "`n") + "`n" } }
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
    }
    if ($loc.Provider.Name -eq 'FileSystem') { $p = $loc.ProviderPath }
    $sep = '\'
    if ($p.StartsWith('/')) { $sep = '/' }
    $parts = @($p -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -gt 3) { $p = '..' + $sep + $parts[-2] + $sep + $parts[-1] }
    Write-Host $p -ForegroundColor Cyan -NoNewline
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
