<#
.SYNOPSIS
  Add album art to an MP3 by wrapping ffmpeg.

.DESCRIPTION
  Takes an input MP3 and image file and writes a new MP3 alongside it with
  album art embedded. The output file name defaults to `<input>.withart.mp3`.

.PARAMETER AudioPath
  Path to the source MP3 file.

.PARAMETER ImagePath
  Path to the cover image (jpg/png recommended).

.PARAMETER OutputPath
  Optional explicit output path. If omitted, `<input>.withart.mp3` is used
  in the same directory as the input.

.EXAMPLE
  .\Fix-Album-Art.ps1 -AudioPath "C:\Music\Track.mp3" -ImagePath "C:\Music\cover.jpg"

.EXAMPLE
  .\Fix-Album-Art.ps1 -AudioPath "Track.mp3" -ImagePath "cover.png" -OutputPath "out.mp3"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AudioPath,

    [Parameter(Mandatory=$true)]
    [string]$ImagePath,

    [string]$OutputPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw "ffmpeg not found on PATH. Please install ffmpeg and try again."
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
  throw "ffprobe not found on PATH. Please install ffmpeg/ffprobe and try again."
}

if (-not (Test-Path -LiteralPath $AudioPath)) {
    throw "Audio file not found: $AudioPath"
}
if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Image file not found: $ImagePath"
}

$audioFull = (Resolve-Path -LiteralPath $AudioPath).ProviderPath
$imageFull = (Resolve-Path -LiteralPath $ImagePath).ProviderPath

$NoOutputPath = $false
if (-not $OutputPath) {
  $NoOutputPath = $true
  $dir = Split-Path -Path $audioFull -Parent
  $base = [System.IO.Path]::GetFileNameWithoutExtension($audioFull)
  $srcExt = [System.IO.Path]::GetExtension($audioFull)
  $OutputPath = Join-Path $dir "$base.withart$srcExt"
}

$outputFull = [System.IO.Path]::GetFullPath($OutputPath)
$lowerOut = $outputFull.ToLower()
$isMp4Container = $lowerOut.EndsWith('.m4a') -or $lowerOut.EndsWith('.mp4')
$container = if ($isMp4Container) { 'mp4' } else { 'mp3' }

# Decide audio codec: keep copy for mp3/m4a, transcode to mp3 for others (e.g., wma)
$audioCodec = 'copy'
if (-not ($lowerOut.EndsWith('.mp3') -or $lowerOut.EndsWith('.m4a') -or $lowerOut.EndsWith('.mp4'))) {
  $audioCodec = 'libmp3lame'
}

# Detect existing album art (attached picture stream) unless forcing
function Test-HasAlbumArt {
  param([string]$FilePath)
  $args = @(
    '-v','error'
    '-select_streams','v'
    '-show_entries','stream=index'
    '-of','csv=p=0'
    $FilePath
  )
  $output = & ffprobe @args 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  return -not [string]::IsNullOrWhiteSpace($output)
}

$hasArt = Test-HasAlbumArt -FilePath $audioFull
if ($hasArt -and -not $Force) {
  Write-Host "Album art already present; skipping. Use -Force to overwrite." -ForegroundColor Yellow
  if ($NoOutputPath) { Write-Host "Existing file left unchanged: $audioFull" }
  return
}

Write-Host "Embedding art..." -ForegroundColor Cyan
Write-Host " Audio : $audioFull"
Write-Host " Image : $imageFull"
Write-Host " Output: $outputFull"

# Build and run ffmpeg command
$ffArgs = @(
  '-y'
  '-i', $audioFull
  '-i', $imageFull
  '-map', '0:a'
  '-map', '1:v'
  '-c:a', $audioCodec
  '-c:v', 'mjpeg'
  '-disposition:v:0', 'attached_pic'
  '-id3v2_version', '3'
  '-write_id3v2', '1'
  '-metadata:s:v', 'title=Album cover'
  '-metadata:s:v', 'comment=Cover'
  '-f', $container
  $outputFull
)

& ffmpeg @ffArgs

Write-Host "Done." -ForegroundColor Green
if ($NoOutputPath) {
    Write-Host "Output file: $outputFull"
}