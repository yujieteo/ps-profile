# PowerShell profile for Windows PowerShell 5.1 in ConstrainedLanguage mode.
# Version: 1.0.0
# Cmdlets and core types only. Data files go to $env:LOCALAPPDATA\ps-profile.

# Share roots to index for fd. Mapped drive letters are allowed, for example 'S:\Finance'.
$global:ShareRoots = @()

$global:PSProfileDataDir = Join-Path $env:LOCALAPPDATA 'ps-profile'
if (-not (Test-Path -LiteralPath $global:PSProfileDataDir)) {
    New-Item -ItemType Directory -Path $global:PSProfileDataDir -Force | Out-Null
}
if (-not $global:PSProfileIndexCache) { $global:PSProfileIndexCache = @{} }

# Version differences between 5.1 and 7 (7 is used only for tests).
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

# ---------------------------------------------------------------- helpers

# True when the command was typed at the prompt and its output goes to the console.
# An assignment or parentheses before the command name mean the caller wants objects.
function global:Test-PSProfileToHost($Invocation) {
    $Invocation.CommandOrigin -eq 'Runspace' -and
    $Invocation.PipelinePosition -eq $Invocation.PipelineLength -and
    $Invocation.Line.Substring(0, $Invocation.OffsetInLine - 1) -notmatch '[=(]\s*$'
}

# Full path in the form typed (drive letter stays a drive letter).
function global:Get-PSProfileFullPath([string]$Path) {
    if (-not $Path) { $Path = '.' }
    $r = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($r) { return $r.ProviderPath }
    $Path
}

function global:ConvertTo-PSProfileUnc([string]$Path) {
    if ($Path -match '^([A-Za-z]):(.*)$') {
        $rest = $Matches[2]
        $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($d -and $d.DisplayRoot -like '\\*') { return $d.DisplayRoot.TrimEnd('\') + $rest }
    }
    $Path
}

function global:Get-PSProfileItemPath($Item) {
    if ($Item -is [string]) { return $Item }
    if ($Item.FullName) { return $Item.FullName }
    if ($Item.Path) { return $Item.Path }
    "$Item"
}

# Text of a file: BOM, else strict UTF-8, else Windows-1252. $null for a binary file.
function global:Read-PSProfileText([string]$Path) {
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

# ---------------------------------------------------------------- Office files as text

function global:ConvertFrom-PSProfileXmlText([string]$s) {
    $s -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&apos;', "'" -replace '&amp;', '&'
}

function global:Get-PSProfileXmlAttr([string]$Tag, [string]$Name) {
    if ($Tag -match ('(?:^|\s)' + [regex]::Escape($Name) + '="([^"]*)"')) { return $Matches[1] }
    ''
}

function global:Get-PSProfileRels([string]$File) {
    $map = @{}
    if (Test-Path -LiteralPath $File) {
        $xml = Get-Content -LiteralPath $File -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($xml, '<Relationship\b[^>]*>')) {
            $map[(Get-PSProfileXmlAttr $m.Value 'Id')] = Get-PSProfileXmlAttr $m.Value 'Target'
        }
    }
    $map
}

function global:Join-PSProfilePart([string]$Dir, [string]$Base, [string]$Target) {
    if ($Target.StartsWith('/')) { return Join-Path $Dir $Target.TrimStart('/') }
    Join-Path (Join-Path $Dir $Base) $Target
}

function global:Get-PSProfileRunText([string]$Xml) {
    $parts = foreach ($m in [regex]::Matches($Xml, '<(?:w|a):t(?:\s[^>]*)?>([^<]*)</(?:w|a):t>|<w:tab/>')) {
        if ($m.Value -eq '<w:tab/>') { "`t" } else { $m.Groups[1].Value }
    }
    ConvertFrom-PSProfileXmlText (@($parts) -join '')
}

# Lines of text from .docx (one per paragraph), .xlsx (one per cell), .pptx (one per slide and shape).
function global:ConvertFrom-PSProfileOffice([string]$Path) {
    $ext = ([regex]::Match($Path, '\.[^.\\/]*$').Value).ToLower()
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

# ---------------------------------------------------------------- index for fd on shares

$global:PSProfileRoots = @(foreach ($r in $global:ShareRoots) {
    $unc = ConvertTo-PSProfileUnc ($r.TrimEnd('\', '/'))
    $sep = '\'
    if ($unc.StartsWith('/')) { $sep = '/' }
    @{
        Unc  = $unc
        Sep  = $sep
        Base = Join-Path $global:PSProfileDataDir ('idx_' + ($unc -replace '[^A-Za-z0-9]+', '_'))
    }
})

# Builds or updates the index. Runs in a background job, so it must be self-contained.
# Per root: <base>.state holds one line per folder (ticks, path, files, subfolders), <base>.idx one path per line.
$global:PSProfileIndexBuilder = {
    param([string]$RootList, [string]$DataDir, [string]$Start, [int]$PauseMs, [int]$MaxAgeHours)
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
            $base = Join-Path $DataDir ('idx_' + ($root -replace '[^A-Za-z0-9]+', '_'))
            if ($MaxAgeHours -gt 0) {
                $i = Get-Item -LiteralPath "$base.idx" -ErrorAction SilentlyContinue
                if ($i -and $i.LastWriteTime -gt (Get-Date).AddHours(-$MaxAgeHours)) { continue }
            }
            $from = $root
            if ($Start) { $from = $Start }
            $fromLower = $from.ToLower()
            $prefixLower = $fromLower + $sep

            $old = @{}
            if (Test-Path -LiteralPath "$base.state") {
                foreach ($line in (Get-Content -LiteralPath "$base.state" -Encoding UTF8 -ReadCount 0)) {
                    $old[$line.Split("`t")[1]] = $line
                }
            }

            $queue = @{}
            $head = 0
            $tail = 0
            $queue[$tail++] = $from
            $new = while ($head -lt $tail) {
                $dir = $queue[$head]
                $queue.Remove($head)
                $head++
                if ($PauseMs) { Start-Sleep -Milliseconds $PauseMs }
                $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                if (-not $item) { continue }
                $ticks = '' + $item.LastWriteTimeUtc.Ticks
                $line = $old[$dir]
                if (-not $line -or $line.Split("`t")[0] -ne $ticks) {
                    $kids = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
                    $files = @($kids | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.Name }) -join '|'
                    $subs = @($kids | Where-Object { $_.PSIsContainer -and -not ([int]$_.Attributes -band 1024) } | ForEach-Object { $_.Name }) -join '|'
                    $line = "$ticks`t$dir`t$files`t$subs"
                }
                $line
                $subs = $line.Split("`t")[3]
                if ($subs) { foreach ($s in $subs.Split('|')) { $queue[$tail++] = $dir + $sep + $s } }
            }

            $keep = foreach ($k in $old.Keys) {
                $kl = $k.ToLower()
                if ($kl -ne $fromLower -and -not $kl.StartsWith($prefixLower)) { $old[$k] }
            }
            $all = @($keep) + @($new)
            Set-Content -LiteralPath "$base.state.tmp" -Value $all -Encoding UTF8
            Move-Item -LiteralPath "$base.state.tmp" -Destination "$base.state" -Force
            $paths = foreach ($line in $all) {
                $f = $line.Split("`t")
                $f[1]
                if ($f[2]) { foreach ($n in $f[2].Split('|')) { $f[1] + $sep + $n } }
            }
            Set-Content -LiteralPath "$base.idx.tmp" -Value $paths -Encoding UTF8
            Move-Item -LiteralPath "$base.idx.tmp" -Destination "$base.idx" -Force
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

# 'building', 'old' or ''.
function global:Get-PSProfileIndexState {
    if (-not $global:PSProfileRoots.Count) { return '' }
    $lock = Join-Path $global:PSProfileDataDir 'index.lock'
    if (Test-Path -LiteralPath $lock) {
        $owner = Get-Content -LiteralPath $lock -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner -match '^\d+$' -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { return 'building' }
    }
    $limit = (Get-Date).AddHours(-24)
    foreach ($r in $global:PSProfileRoots) {
        $i = Get-Item -LiteralPath "$($r.Base).idx" -ErrorAction SilentlyContinue
        if (-not $i -or $i.LastWriteTime -lt $limit) { return 'old' }
    }
    ''
}

# The index loads on first use and stays in memory; it reloads only when the file changes.
function global:Get-PSProfileIndex($Root) {
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

# ---------------------------------------------------------------- fd

function global:fd {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Pattern = '.',
        [Parameter(Position = 1)][string]$Path = '.'
    )
    $typed = Get-PSProfileFullPath $Path
    $unc = ConvertTo-PSProfileUnc $typed
    $root = Find-PSProfileRoot $unc
    if (-not $root) {
        Get-ChildItem -LiteralPath $typed -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $Pattern } | ForEach-Object { $_.FullName }
        return
    }
    $lines = Get-PSProfileIndex $root
    if ($null -eq $lines) { Write-Warning "fd: no index yet for $($root.Unc). Run Update-Index."; return }
    $sep = $root.Sep
    $uncPrefix = $unc.TrimEnd($sep) + $sep
    $typedPrefix = $typed.TrimEnd('\', '/') + $sep
    # Fast filter on full paths first. A leading ^ also matches after a separator, so no leaf match is lost.
    $full = $Pattern
    if ($full.StartsWith('^')) { $full = '(?:^|[\\/])' + $full.Substring(1) }
    $hits = $lines -match $full
    $hits = $hits -like (($uncPrefix -replace '([\[\]\*\?`])', '`$1') + '*')
    foreach ($h in $hits) {
        $leaf = $h.Substring($h.LastIndexOf($sep) + 1)
        if ($leaf -match $Pattern) { $typedPrefix + $h.Substring($uncPrefix.Length) }
    }
}

# ---------------------------------------------------------------- rg

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
    }
    process {
        foreach ($p in $Path) {
            $seen++
            & $searchPath $p
        }
    }
    end {
        if (-not $seen -and -not $MyInvocation.ExpectingInput) { & $searchPath '.' }
        if ($skipped.Legacy -or $skipped.Large) {
            Write-Warning ('rg: skipped {0} legacy Office file(s) (.doc .xls .ppt) and {1} file(s) over {2} MB.' -f $skipped.Legacy, $skipped.Large, $MaxSizeMB)
        }
    }
}

# ---------------------------------------------------------------- fzf

function global:fzf {
    param([string]$Query = '')
    $items = @($input)
    if (-not $items.Count) { return }
    $texts = @(foreach ($it in $items) {
        $t = $it
        if ($it -isnot [string]) {
            if ($it.FullName) { $t = $it.FullName }
            elseif ($it.Path -and $it.LineNumber) { $t = '{0}:{1}: {2}' -f $it.Path, $it.LineNumber, $it.Line }
            else { $t = (($it | Out-String).Trim() -replace '\s+', ' ') }
        }
        $t
    })
    while ($true) {
        $tokens = @($Query -split '\s+' | Where-Object { $_ })
        $cand = $texts
        # A token with regex characters is a regex. Other tokens match as a subsequence (fuzzy).
        $rxs = @(foreach ($tok in $tokens) {
            $rx = (@($tok.ToCharArray() | ForEach-Object { [regex]::Escape([string]$_) })) -join '.*?'
            if ($tok -match '[\\^$.|?*+()\[\]{}]') {
                try { $null = '' -match $tok; $rx = $tok } catch { }
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
        Write-Host ('{0} of {1} match' -f $total, $texts.Count) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $top.Count; $i++) {
            Write-Host ('{0,3} ' -f ($i + 1)) -ForegroundColor Cyan -NoNewline
            Write-Host $top[$i]
        }
        $r = Read-Host 'Number to pick, text to filter, Enter to quit'
        if (-not $r) { return }
        if ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $top.Count) {
            $pick = $top[[int]$r - 1]
            for ($i = 0; $i -lt $texts.Count; $i++) { if ($texts[$i] -ceq $pick) { return $items[$i] } }
        }
        $Query = $r
    }
}

# ---------------------------------------------------------------- z / zi

$global:PSProfileZFile = Join-Path $global:PSProfileDataDir 'z.txt'

function global:Read-PSProfileZ {
    $db = @{}
    if (Test-Path -LiteralPath $global:PSProfileZFile) {
        foreach ($line in (Get-Content -LiteralPath $global:PSProfileZFile -Encoding UTF8)) {
            $f = $line.Split("`t")
            if ($f.Count -ge 3) { $db[$f[0]] = @{ Rank = [double]$f[1]; Time = [long]$f[2] } }
        }
    }
    $db
}

function global:Save-PSProfileZ($Db) {
    $lines = foreach ($k in $Db.Keys) { '{0}{1}{2}{1}{3}' -f $k, "`t", $Db[$k].Rank, $Db[$k].Time }
    Set-Content -LiteralPath $global:PSProfileZFile -Value @($lines) -Encoding UTF8
}

function global:Get-PSProfileNow { [long]((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds }

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

# Paths that match all terms in order, best frecency first.
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

# A dead entry is removed only when a jump to it fails.
function global:Enter-PSProfileZ([string]$Path) {
    try { Set-Location -LiteralPath $Path -ErrorAction Stop; return $true }
    catch { Remove-PSProfileZ $Path; Write-Warning "z: removed dead entry '$Path'."; return $false }
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
    try { Set-Location @args -ErrorAction Stop } catch { Write-Error $_; return }
    if ($args.Count -and $MyInvocation.CommandOrigin -eq 'Runspace') { Add-PSProfileZ (Get-Location).ProviderPath }
}

# ---------------------------------------------------------------- delta

# Myers diff. Returns ops with T (' ', '-', '+'), A (index in $A) and B (index in $B).
function global:Get-PSProfileDiff($A, $B) {
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

function global:Get-PSProfileDiffLines([string]$Path) {
    if ($Path -match '\.(docx|xlsx|pptx)$') { return , @(ConvertFrom-PSProfileOffice (Get-PSProfileFullPath $Path)) }
    $text = Read-PSProfileText $Path
    if ($null -eq $text) { throw "delta: '$Path' is a binary file." }
    $lines = Split-PSProfileLines $text
    , $lines
}

# One changed line with the changed words in bright color and the rest in dark color.
function global:Write-PSProfileWordLine([string]$Mark, $Tokens, $Changed, [string]$Dark, [string]$Bright) {
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
    $a = Get-PSProfileDiffLines $Path1
    $b = Get-PSProfileDiffLines $Path2
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

# ---------------------------------------------------------------- QOL

if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
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

function global:tail([string]$Path, [Alias('n')][int]$Count = 10) {
    if ($Path) { Get-Content -LiteralPath $Path -Tail $Count } else { $input | Select-Object -Last $Count }
}

function global:wc {
    $texts = @(if ($args.Count) {
        foreach ($p in $args) { @{ Path = $p; Text = Read-PSProfileText $p } }
    } else {
        $lines = @($input | ForEach-Object { "$_" })
        if ($lines.Count) { @{ Path = ''; Text = ($lines -join "`n") + "`n" } }
    })
    foreach ($t in $texts) {
        $s = '' + $t.Text
        New-Object PSObject -Property @{
            Lines = [regex]::Matches($s, "`n").Count
            Words = [regex]::Matches($s, '\S+').Count
            Chars = $s.Length
            Path  = $t.Path
        } | Select-Object Lines, Words, Chars, Path
    }
}

$global:PSProfileColors = @{
    '.exe' = 'Green'; '.bat' = 'Green'; '.cmd' = 'Green'; '.ps1' = 'Green'; '.com' = 'Green'; '.msi' = 'Green'
    '.docx' = 'Yellow'; '.xlsx' = 'Yellow'; '.pptx' = 'Yellow'; '.doc' = 'Yellow'; '.xls' = 'Yellow'; '.ppt' = 'Yellow'
    '.xlsm' = 'Yellow'; '.docm' = 'Yellow'; '.pptm' = 'Yellow'
    '.zip' = 'Magenta'; '.7z' = 'Magenta'; '.rar' = 'Magenta'; '.tar' = 'Magenta'; '.gz' = 'Magenta'; '.cab' = 'Magenta'
}

function global:Show-PSProfileListing($Items) {
    $parent = $null
    foreach ($i in $Items) {
        if ($null -eq $i.PSIsContainer) { $i; continue }
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

# ---------------------------------------------------------------- prompt

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
    if ($loc.Provider.Name -eq 'FileSystem') { $p = $loc.ProviderPath }
    $sep = '\'
    if ($p.StartsWith('/')) { $sep = '/' }
    $parts = @($p -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -gt 3) { $p = '..' + $sep + $parts[-2] + $sep + $parts[-1] }
    Write-Host $p -ForegroundColor Cyan -NoNewline
    '> '
}

# ---------------------------------------------------------------- start the index job when the index is old

if ((Get-PSProfileIndexState) -eq 'old') {
    $roots = ($global:PSProfileRoots | ForEach-Object { $_.Unc }) -join "`n"
    try {
        Start-Job -Name 'ps-profile-index' -ScriptBlock $global:PSProfileIndexBuilder -ArgumentList $roots, $global:PSProfileDataDir, '', 10, 24 -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "The index job did not start: $($_.Exception.Message) Run Update-Index."
    }
    Remove-Variable roots
}
