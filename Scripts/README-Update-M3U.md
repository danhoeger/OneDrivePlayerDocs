# Update-M3U.ps1 - Playlist Metadata Updater

## Overview

`Update-M3U.ps1` is a PowerShell script that automatically updates M3U playlist files by populating `#EXTINF` metadata lines with accurate track information (duration, artist, and title) extracted from audio file metadata.

The script reads your playlist, inspects each audio file's metadata using Windows Media Player components, and rewrites the `#EXTINF` lines with proper formatting:
```
#EXTINF:<duration_in_seconds>,<artist> - <title>
```

It preserves all other playlist content, relative paths, and non-audio entries (such as URLs).

## Features

- **Automatic Metadata Extraction**: Reads duration, artist, and title from audio files using Windows Media Player COM
- **Smart Fallback**: If metadata cannot be read from WMP, attempts to retrieve it from the Windows Shell property store
- **Encoding Support**: Handles UTF-8, UTF-16, ANSI, and auto-detection of file encodings
- **Non-Destructive Options**: Write to a new file or update in-place with optional backups
- **URL Preservation**: Leaves remote URLs and streaming entries untouched
- **Persistent Metadata**: If a track file cannot be read, preserves the original `#EXTINF` line
- **Album Art Embedding** (optional): Can embed album art into audio files when available

## Requirements

- **Windows Operating System** (Windows 7 or later)
- **PowerShell 5.0 or later**
- **Windows Media Player** or media metadata components (typically pre-installed on Windows)
- **Audio Files**: Common formats supported by Windows Media Player (MP3, FLAC, WAV, M4A, etc.)

## Installation

1. Download or clone this repository
2. Locate the `Update-M3U.ps1` script in the `Scripts/` folder
3. (Optional) For album art embedding, ensure `Fix-Album-Art.ps1` is in the same `Scripts/` directory

## Usage

### Basic Syntax

```powershell
.\Update-M3U.ps1 -Path <playlist_file> [options]
```

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Path` | string | Yes | N/A | Path to the M3U playlist file |
| `-InPlace` | switch | No | `$false` | Overwrite the source playlist instead of creating a new file |
| `-Backup` | switch | No | `$false` | Create a `.bak` backup of the original when using `-InPlace` |
| `-OutputPath` | string | No | Auto-generated | Specify a custom output file path (ignored if `-InPlace` is used) |
| `-InputEncoding` | string | No | `auto` | Input file encoding: `auto`, `utf8`, `utf8BOM`, `unicode`, `ascii`, `ansi` |
| `-Encoding` | string | No | `utf8` | Output file encoding: `utf8`, `utf8BOM`, `unicode`, `ascii`, `ansi` |
| `-UpdateAlbumArt` | switch | No | `$false` | Attempt to embed album art from `albumart*.jpg` files (requires `Fix-Album-Art.ps1`) |

### Examples

#### Example 1: Create an Updated Playlist (Non-Destructive)

```powershell
.\Update-M3U.ps1 -Path "C:\Music\MyPlaylist.m3u"
```

**Output:** Creates `C:\Music\MyPlaylist.updated.m3u` with updated metadata

#### Example 2: Update Playlist In-Place with Backup

```powershell
.\Update-M3U.ps1 -Path "C:\Music\MyPlaylist.m3u" -InPlace -Backup
```

**Result:** 
- Replaces the original playlist with updated metadata
- Saves backup as `C:\Music\MyPlaylist.m3u.bak`

#### Example 3: Specify Custom Output Location

```powershell
.\Update-M3U.ps1 -Path ".\playlist.m3u" -OutputPath ".\playlist.updated.m3u"
```

**Output:** Writes updated playlist to `.\playlist.updated.m3u`

#### Example 4: Update Playlist With Album Art Embedding

```powershell
.\Update-M3U.ps1 -Path "C:\Music\MyPlaylist.m3u" -InPlace -UpdateAlbumArt
```

**Result:** 
- Updates playlist metadata
- For each track, searches the same directory for `albumart*.jpg` files
- Embeds the largest album art image into the audio file (creates a copy with `.withart` suffix, then replaces the original)

#### Example 5: Control Input/Output Encoding

```powershell
.\Update-M3U.ps1 -Path "playlist.m3u" -InputEncoding utf8 -Encoding utf8BOM -InPlace
```

**Result:** Reads playlist as UTF-8, writes it back as UTF-8 with BOM (Byte Order Mark)

#### Example 6: Enable Verbose Output for Debugging

```powershell
.\Update-M3U.ps1 -Path "playlist.m3u" -InPlace -Verbose
```

**Output:** Displays detailed messages about metadata extraction, encoding detection, and file processing

## How It Works

1. **Reads the Playlist**: Loads the M3U file with automatic encoding detection
2. **Ensures Header**: Adds `#EXTM3U` header if not present
3. **Processes Each Track**:
   - Resolves relative paths to absolute file paths
   - Skips remote URLs (HTTP, FTP, RTSP)
   - Extracts metadata using:
     - Windows Media Player COM object (primary method)
     - Windows Shell property store (fallback)
4. **Updates #EXTINF Lines**: Rewrites metadata lines with:
   - Duration in seconds
   - Artist and title (or filename fallback)
5. **Writes Output**: Saves updated playlist atomically (using temp file to prevent corruption)
6. **Album Art Processing** (if enabled): Embeds album art using `Fix-Album-Art.ps1`

## Common Workflows

### Workflow A: Update a Single Playlist Safely

```powershell
# 1. Test by creating an .updated version
.\Update-M3U.ps1 -Path ".\Gaming.m3u"

# 2. Verify the output file looks good

# 3. If satisfied, run with backup
.\Update-M3U.ps1 -Path ".\Gaming.m3u" -InPlace -Backup -Verbose
```

### Workflow B: Batch Update Multiple Playlists

```powershell
# Update all .m3u files in the current directory
Get-ChildItem -Filter "*.m3u" | ForEach-Object {
    .\Update-M3U.ps1 -Path $_.FullName -InPlace -Backup -Verbose
}
```

### Workflow C: Add Album Art to All Tracks

```powershell
# First, organize album art images as "albumart.jpg" in each track's directory
# Then run:
.\Update-M3U.ps1 -Path ".\Music.m3u" -InPlace -UpdateAlbumArt -Verbose
```
Note: This will create `.withart` copies of each audio file with embedded album art, then replace the originals. Always ensure you have backups before running this operation on important files. Also, be aware that embedding album art modifies the audio files, so use this option only if you want the album art embedded in the files themselves. This also requires you to have ffmpeg installed and in your system PATH for the embedding process to work.

## Troubleshooting

### Issue: "Failed to create WMPlayer.OCX COM object"

**Cause:** Windows Media Player components are not installed

**Solutions:**
- Install Windows Media Feature Pack (for N editions of Windows)
- Ensure Media Feature Pack is enabled in Windows Features
- As a workaround, the script will preserve original `#EXTINF` lines for unreadable files

### Issue: Album Art Not Embedding

**Cause:** `Fix-Album-Art.ps1` not found or not in the same directory

**Solutions:**
- Ensure `Fix-Album-Art.ps1` is in the same `Scripts/` directory
- Use `-Verbose` flag to see detailed error messages
- Check that album art images are named `albumart*.jpg` in the track's directory

### Issue: Playlist Becomes Corrupted

**Solution:** Always use `-Backup` when updating in-place:
```powershell
.\Update-M3U.ps1 -Path "playlist.m3u" -InPlace -Backup
```

The backup `.bak` file lets you easily restore the original if needed.

### Issue: Metadata Not Extracted Correctly

**Solutions:**
1. Check file permissions (ensure the script can read the audio file)
2. Use `-Verbose` to see detailed extraction attempts:
   ```powershell
   .\Update-M3U.ps1 -Path "playlist.m3u" -Verbose
   ```
3. Ensure audio files are not corrupted or in very exotic formats
4. Update Windows Media metadata in File Explorer manually if extraction fails

## Performance Notes

- The script reuses a single Windows Media Player COM instance for efficiency
- First run may be slower as metadata is extracted for all tracks
- Album art embedding adds processing time (one operation per track)
- For large playlists (1000+ tracks), expect 5-15 minutes depending on file sizes

## License

See parent repository for license information.

## See Also

- `Fix-Album-Art.ps1` - Embeds album art into audio files (used with `-UpdateAlbumArt`)
- M3U Format Specification: [External reference](https://en.wikipedia.org/wiki/M3U)
- Installing FFMPEG: [FFmpeg Download](https://ffmpeg.org/download.html) (required for album art embedding)
