<#
.SYNOPSIS
  Update #EXTINF lines in an M3U/M3U8 playlist using file metadata.

.DESCRIPTION
  Reads an M3U/M3U8 file. For each local file entry, fetches metadata (duration, artist, title)
  via Windows Media Player COM (WMPlayer.OCX), then rewrites (or inserts) a matching #EXTINF line:
    #EXTINF:<seconds>,Artist - Title
  Preserves other comments/directives and relative paths. 
  If a file is not found or metadata cannot be read, preserves the original #EXTINF if present.

.PARAMETER Path
  The path to the .m3u or .m3u8 playlist file.

.PARAMETER InPlace
  Overwrite the source playlist instead of writing a separate output.

.PARAMETER OutputPath
  If provided and not using -InPlace, write to this new file.

.PARAMETER Backup
  If -InPlace is used, create a .bak backup next to the original first.

.PARAMETER Encoding
  Output encoding. Default: utf8BOM. Options: utf8, utf8BOM, unicode, ascii.
.PARAMETER UpdateAlbumArt
  If specified, attempt to embed album art into audio files using Fix-Album-Art.ps1 when albumart files are found.
  By default, album art embedding is skipped.
.EXAMPLE
  .\Update-M3U.ps1 -Path "C:\Music\MyPlaylist.m3u8" -InPlace -Backup

.EXAMPLE
  .\Update-M3U.ps1 -Path ".\playlist.m3u" -OutputPath ".\playlist.updated.m3u"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [ValidateSet('auto','utf8','utf8BOM','unicode','ascii','ansi')]
    [string]$InputEncoding = 'auto',

    [switch]$InPlace,

    [string]$OutputPath,

    [switch]$Backup,

    [ValidateSet('utf8','utf8BOM','unicode','ascii','ansi')]
    [string]$Encoding = 'utf8',

    [switch]$UpdateAlbumArt
)

begin {
    function Get-TextEncoding {
        param([Parameter(Mandatory)][ValidateSet('utf8','utf8BOM','unicode','ascii','ansi')] [string]$Name)
        switch ($Name) {
            'utf8'     { return [System.Text.UTF8Encoding]::new($false) } # UTF-8 (no BOM)
            'utf8BOM'  { return [System.Text.UTF8Encoding]::new($true)  } # UTF-8 with BOM
            'unicode'  { return [System.Text.Encoding]::Unicode }         # UTF-16 LE with BOM
            'ascii'    { return [System.Text.Encoding]::ASCII }
            'ansi'     { return [System.Text.Encoding]::GetEncoding(1252) } # Explicit Windows-1252 (common "ANSI")
        }
    }

    function Read-PlaylistLines {
        param(
            [string]$FullPath,
            [string]$InputEncodingName,
            [System.Text.Encoding]$ExplicitEncoding
        )
        # Explicit encoding provided: use it directly
        if ($InputEncodingName -ne 'auto') {
            $lines = [System.IO.File]::ReadAllLines($FullPath, $ExplicitEncoding)
            return [pscustomobject]@{ Lines = $lines; EncodingUsed = $ExplicitEncoding }
        }

        # Auto-detect with strict UTF-8 first; fall back to Windows-1252 when bytes are not valid UTF-8
        $bytes = [System.IO.File]::ReadAllBytes($FullPath)

        function Decode-ToLines {
            param([byte[]]$Buf, [System.Text.Encoding]$Enc)
            $list = New-Object System.Collections.Generic.List[string]
            $sr = $null
            try {
                $text = $Enc.GetString($Buf)
                $sr = New-Object System.IO.StringReader($text)
                while (($line = $sr.ReadLine()) -ne $null) { $list.Add($line) }
            } finally {
                if ($sr) { $sr.Dispose() }
            }
            return $list
        }

        # BOM detection for common encodings
        $encUsed = $null
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encUsed = [System.Text.UTF8Encoding]::new($true)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encUsed = [System.Text.Encoding]::Unicode # UTF-16 LE
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encUsed = [System.Text.Encoding]::BigEndianUnicode
        }

        if ($encUsed) {
            $lines = Decode-ToLines -Buf $bytes -Enc $encUsed
            return [pscustomobject]@{ Lines = $lines; EncodingUsed = $encUsed }
        }

        # No BOM: try strict UTF-8 (error on invalid), otherwise fall back to Windows-1252 ("ANSI")
        try {
            $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
            $lines = Decode-ToLines -Buf $bytes -Enc $strictUtf8
            $encUsed = [System.Text.UTF8Encoding]::new($false)
        } catch {
            $ansiEnc = [System.Text.Encoding]::GetEncoding(1252)
            $lines = Decode-ToLines -Buf $bytes -Enc $ansiEnc
            $encUsed = $ansiEnc
        }

        return [pscustomobject]@{ Lines = $lines; EncodingUsed = $encUsed }
    }

    # Cache to avoid reprocessing the same file multiple times
    $script:AlbumArtProcessed = @{}
    $script:ScriptRoot = Split-Path -Path $PSCommandPath -Parent

    function Ensure-AlbumArt {
        param([string]$FullPath)

        if ($script:AlbumArtProcessed.ContainsKey($FullPath)) {
            Write-Verbose "Album art: cached result for $FullPath -> $($script:AlbumArtProcessed[$FullPath])"
            return $script:AlbumArtProcessed[$FullPath]
        }

        if (-not (Test-Path -LiteralPath $FullPath)) {
            Write-Verbose "Album art: file not found $FullPath"
            $script:AlbumArtProcessed[$FullPath] = $false
            return $false
        }

        $dir = Split-Path -Path $FullPath -Parent
        $covers = Get-ChildItem -LiteralPath $dir -Filter 'albumart*.jp*g' -File -ErrorAction SilentlyContinue
        if (-not $covers) {
            Write-Verbose "Album art: no albumart*.jpg in $dir"
            $script:AlbumArtProcessed[$FullPath] = $false
            return $false
        }

        $cover = $covers | Sort-Object Length -Descending | Select-Object -First 1
        Write-Verbose "Album art: selected $($cover.Name) ($([int]($cover.Length/1kb)) KB) for $FullPath"

        $fixScript = Join-Path -Path $script:ScriptRoot -ChildPath 'Fix-Album-Art.ps1'
        if (-not (Test-Path -LiteralPath $fixScript)) {
            Write-Verbose "Album art: Fix-Album-Art.ps1 not found at $fixScript; skipping art embed."
            $script:AlbumArtProcessed[$FullPath] = $false
            return $false
        }

        $withArtPath = Join-Path -Path $dir -ChildPath ("{0}.withart{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($FullPath), [System.IO.Path]::GetExtension($FullPath))

        try {
            Write-Verbose "Album art: invoking Fix-Album-Art.ps1 for $FullPath"
            & $fixScript -AudioPath $FullPath -ImagePath $cover.FullName -OutputPath $withArtPath -Force

            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Album art: Fix-Album-Art.ps1 exited with code $LASTEXITCODE for $FullPath"
                throw "Fix-Album-Art failed with exit code $LASTEXITCODE"
            }

            if (Test-Path -LiteralPath $withArtPath) {
                Move-Item -LiteralPath $withArtPath -Destination $FullPath -Force
                Write-Verbose "Album art embedded from $($cover.Name) into $FullPath"
                $script:AlbumArtProcessed[$FullPath] = $true
                return $true
            } else {
                Write-Verbose "Album art embed produced no output file for $FullPath"
            }
        } catch {
            Write-Verbose "Album art embed failed for ${FullPath}: $($_.Exception.Message)"
        }

        $script:AlbumArtProcessed[$FullPath] = $false
        return $false
    }


    function Test-IsUrl {
        param([string]$s)
        return ($s -match '^(?i)(https?|rtsp|ftp)://')
    }

    function Resolve-TrackPath {
        param(
            [string]$PlaylistDir,
            [string]$TrackLine
        )
        $clean = $TrackLine.Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
        if (Test-IsUrl $clean) { return $null }  # URLs not resolved on disk
        if ([System.IO.Path]::IsPathRooted($clean)) {
            return $clean
        } else {
            try {
                $combined = Join-Path -Path $PlaylistDir -ChildPath $clean
                return [System.IO.Path]::GetFullPath($combined)
            } catch {
                return $null
            }
        }
    }

    # Reuse a single WMP COM instance for performance
    $script:WMPlayer = $null
    function Ensure-Wmp {
        if (-not $script:WMPlayer) {
            try {
                $script:WMPlayer = New-Object -ComObject WMPlayer.OCX
            } catch {
                throw "Failed to create WMPlayer.OCX COM object. Ensure Windows Media Player components are available."
            }
        }
    }

    function Get-MediaMetadata {
        <#
          Returns [pscustomobject] with:
            Title, Artist, DurationSeconds (nullable)
          Returns $null if metadata cannot be retrieved.
        #>
        param([Parameter(Mandatory)][string]$FullPath)

        if (-not (Test-Path -LiteralPath $FullPath)) { return $null }

        function Try-ParseDurationSeconds {
            param([string]$value)
            if ([string]::IsNullOrWhiteSpace($value)) { return $null }
            $ts = $null
            # Try flexible formats
            if ([TimeSpan]::TryParse($value, [ref]$ts)) { return [int][Math]::Round($ts.TotalSeconds, 0) }
            foreach ($fmt in @('m\:ss','mm\:ss','h\:mm\:ss','hh\:mm\:ss')) {
                if ([TimeSpan]::TryParseExact($value, $fmt, $null, [ref]$ts)) { return [int][Math]::Round($ts.TotalSeconds, 0) }
            }
            return $null
        }

        Ensure-Wmp

        $result = $null
        try {
            $media = $script:WMPlayer.newMedia($FullPath)
            if ($media) {
                $duration = $null
                if ($media.duration -is [double] -and $media.duration -gt 0) {
                    $duration = [int][Math]::Round($media.duration, 0)
                }

                # Common tags
                $title  = $media.getItemInfo("Title")
                $artist = $media.getItemInfo("Author")

                # Prefer track artist over album artist
                if ([string]::IsNullOrWhiteSpace($artist)) {
                    foreach ($k in @("WM/Artist","Artist","WM/AlbumArtist","AlbumArtist")) {
                        $val = $media.getItemInfo($k)
                        if (-not [string]::IsNullOrWhiteSpace($val)) { $artist = $val; break }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($title)) {
                    $title = [System.IO.Path]::GetFileNameWithoutExtension($FullPath)
                }

                $result = [pscustomobject]@{
                    Title           = $title
                    Artist          = $artist
                    DurationSeconds = $duration
                }
            }
        } catch {
            $result = $null
        }

        # Fallback: if duration is missing, try Shell property store (handles stubborn tags / paths)
        if (-not $result -or $result.DurationSeconds -eq $null) {
            try {
                $shell = New-Object -ComObject Shell.Application
                $dirPath = [System.IO.Path]::GetDirectoryName($FullPath)
                $fileName = [System.IO.Path]::GetFileName($FullPath)

                $folder = $shell.NameSpace($dirPath)
                if (-not $folder) {
                    Write-Verbose "Shell fallback: failed to open folder $dirPath"
                }
                $item   = if ($folder) { $folder.ParseName($fileName) } else { $null }
                if (-not $item) {
                    Write-Verbose "Shell fallback: failed to parse item $fileName"
                }

                if ($folder -and $item) {
                    $durationStr = $folder.GetDetailsOf($item, 27) # Duration
                    $artistStr   = $folder.GetDetailsOf($item, 13) # Contributing artists
                    $titleStr    = $folder.GetDetailsOf($item, 21) # Title

                    $durationSec = Try-ParseDurationSeconds $durationStr

                    $titleFallback  = if (-not [string]::IsNullOrWhiteSpace($titleStr)) { $titleStr } else { [System.IO.Path]::GetFileNameWithoutExtension($FullPath) }
                    $artistFallback = $artistStr

                    $result = [pscustomobject]@{
                        Title           = if ($result -and -not [string]::IsNullOrWhiteSpace($result.Title)) { $result.Title } else { $titleFallback }
                        Artist          = if ($result -and -not [string]::IsNullOrWhiteSpace($result.Artist)) { $result.Artist } else { $artistFallback }
                        DurationSeconds = if ($result -and $result.DurationSeconds -ne $null) { $result.DurationSeconds } else { $durationSec }
                    }
                }
            } catch {
                Write-Verbose "Shell fallback error: $($_.Exception.Message)"
            }
        }

        # Treat zero/negative durations as missing so we don't write #EXTINF:0
        if ($result -and $result.DurationSeconds -le 0) {
            $result.DurationSeconds = $null
        }

        return $result
    }

    function Build-ExtInf {
        param(
            [int]$Seconds,
            [string]$Artist,
            [string]$Title
        )
        $display =
            if (-not [string]::IsNullOrWhiteSpace($Artist) -and -not [string]::IsNullOrWhiteSpace($Title)) {
                "$Artist - $Title"
            } elseif (-not [string]::IsNullOrWhiteSpace($Title)) {
                $Title
            } elseif (-not [string]::IsNullOrWhiteSpace($Artist)) {
                $Artist
            } else {
                "Unknown"
            }

        if ($Seconds -lt 0) { $Seconds = 0 }
        return "#EXTINF:$Seconds,$display"
    }

    function Is-ExtInfLine {
        param([string]$Line)
        # Anchor at start after optional whitespace/BOM to avoid misclassifying EXTM3U
        return ($Line -match '^(?i)\s*#EXTINF:')
    }

    function Is-ExtM3uHeader {
        param([string]$Line)
        # Anchor at start after optional whitespace/BOM
        return ($Line -match '^(?i)\s*#EXTM3U')
    }

    $outEncoding = Get-TextEncoding -Name $Encoding
    $readEncoding = if ($InputEncoding -ne 'auto') { Get-TextEncoding -Name $InputEncoding } else { $null }
    Write-Verbose "Using write encoding: name=$Encoding; webName=$($outEncoding.WebName); codePage=$($outEncoding.CodePage); inputEncoding=$InputEncoding"
}

process {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Playlist not found: $Path"
    }

    $hadError = $false
    $hadErrorReason = $null
    $newLines = $null

    try {
        # Use Resolve-Path first to avoid Split-Path parameter-set quirks with -LiteralPath
        $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $playlistFullPath = $resolvedPath.ProviderPath
        $playlistDir  = Split-Path -Path $playlistFullPath -Parent
        $readResult = Read-PlaylistLines -FullPath $playlistFullPath -InputEncodingName $InputEncoding -ExplicitEncoding $readEncoding
        $lines = $readResult.Lines
        Write-Verbose "Detected/used read encoding: webName=$($readResult.EncodingUsed.WebName); codePage=$($readResult.EncodingUsed.CodePage); preambleLen=$($readResult.EncodingUsed.GetPreamble().Length)"

        $newLines = New-Object System.Collections.Generic.List[string]

        # Ensure #EXTM3U header is present as the very first non-empty line
        $hasExtm3u = $false
        foreach ($line in $lines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                if (Is-ExtM3uHeader $line) { $hasExtm3u = $true }
                break
            }
        }
        if (-not $hasExtm3u) { $newLines.Add("#EXTM3U") }

        # We'll track an #EXTINF candidate found immediately before a track line
        $pendingExtInf = $null
        Write-Verbose "Loaded $($lines.Count) lines from playlist."

        function Normalize-LineStart {
            param([string]$Line)
            # Trim BOM (U+FEFF) and leading whitespace so directive detection works
            if ($null -eq $Line) { return $Line }
            return $Line.TrimStart([char]0xFEFF, [char]0x00A0, [char]' ', "`t")
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $norm = Normalize-LineStart $line

            if ([string]::IsNullOrWhiteSpace($norm)) {
                # Preserve blank lines
                $newLines.Add($line)
                continue
            }

            if (Is-ExtInfLine $norm) {
                # Hold onto it for the next track line; do not output yet.
                $pendingExtInf = $line
                Write-Verbose "Detected existing EXTINF, will replace if metadata exists: $line"
                continue
            }

            if ($norm.StartsWith("#")) {
                # Other directives/comments get preserved in order
                $newLines.Add($line)
                continue
            }

            # At this point: it's a track entry (path or URL)
            $trackLine = $line
            $fullPath  = Resolve-TrackPath -PlaylistDir $playlistDir -TrackLine $line
            if ($fullPath) {
                Write-Verbose "Resolved track [$trackLine] -> [$fullPath]"
            } else {
                Write-Verbose "Skipping unresolved or URL track: $trackLine"
            }

            if ($fullPath -and $UpdateAlbumArt.IsPresent) {
                # Attempt to embed album art if present alongside the track
                Ensure-AlbumArt -FullPath $fullPath | Out-Null
            }

            $metadata = $null
            if ($fullPath) {
                $metadata = Get-MediaMetadata -FullPath $fullPath
                if ($metadata) {
                    Write-Verbose "Metadata for [$trackLine]: Duration=$($metadata.DurationSeconds); Artist=$($metadata.Artist); Title=$($metadata.Title)"
                } else {
                    Write-Verbose "No metadata found for [$trackLine]"
                }
            }

            if ($metadata -and $metadata.DurationSeconds -ne $null) {
                # We can build a fresh EXTINF
                $ext = Build-ExtInf -Seconds $metadata.DurationSeconds -Artist $metadata.Artist -Title $metadata.Title
                Write-Verbose "Writing EXTINF (from metadata): $ext"
                $newLines.Add($ext)
                $newLines.Add($trackLine)
            } elseif ($metadata -and $metadata.DurationSeconds -eq $null) {
                # We have artist/title but no duration; EXTINF requires seconds.
                Write-Verbose "Writing prior EXTINF (no duration found) for ${trackLine}: $pendingExtInf"
                if ($pendingExtInf) { $newLines.Add($pendingExtInf) }
                $newLines.Add($trackLine)
            } else {
                # No metadata (URL or unreadable or missing file)
                Write-Verbose "Preserving existing EXTINF (no metadata) for ${trackLine}: $pendingExtInf"
                if ($pendingExtInf) { $newLines.Add($pendingExtInf) }
                $newLines.Add($trackLine)
            }

            # Clear pending EXTINF after we process a track
            $pendingExtInf = $null
        }
    } catch {
        $hadError = $true
        $hadErrorReason = $_.Exception.Message
        Write-Error "Processing failed: $($hadErrorReason)"
    }

    if ($hadError -or -not $newLines) {
        $msg = "Skipping write because processing failed. Original file left untouched."
        if ($hadErrorReason) { $msg += " Reason: $hadErrorReason" }
        Write-Warning $msg
        return
    }

    # Write output atomically to avoid any OneDrive/locking oddities
    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllLines($tempFile, $newLines.ToArray(), $outEncoding)

    if ($InPlace.IsPresent) {
        if ($Backup.IsPresent) {
            $bak = "$playlistFullPath.bak"
            Copy-Item -LiteralPath $playlistFullPath -Destination $bak -Force
        }
        Move-Item -LiteralPath $tempFile -Destination $playlistFullPath -Force
        Write-Host "Updated playlist written in-place: $playlistFullPath"
    } else {
        $targetOutput = $null
        if ($OutputPath) {
            $resolvedOutput = Resolve-Path -LiteralPath $OutputPath -ErrorAction SilentlyContinue
            if ($resolvedOutput) {
                $targetOutput = $resolvedOutput.ProviderPath
            } else {
                $targetOutput = [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location) -ChildPath $OutputPath))
            }
        } else {
            $ext = [System.IO.Path]::GetExtension($playlistFullPath)
            $base = [System.IO.Path]::GetFileNameWithoutExtension($playlistFullPath)
            $dir = [System.IO.Path]::GetDirectoryName($playlistFullPath)
            $targetOutput = Join-Path $dir "$base.updated$ext"
        }

        Move-Item -LiteralPath $tempFile -Destination $targetOutput -Force
        Write-Host "Updated playlist written to: $targetOutput"
    }
}

end {
    # Clean up WMP COM object
    if ($script:WMPlayer) {
        try {
            # WMPlayer.OCX doesn't expose a Close, but releasing COM object helps
            [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:WMPlayer) | Out-Null
        } catch { }
        $script:WMPlayer = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}
