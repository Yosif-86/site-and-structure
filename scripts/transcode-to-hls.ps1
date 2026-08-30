# Transcodes a source video into multi-bitrate HLS (480p/720p/1080p) with a
# master playlist, ready to upload to R2 via upload-to-r2.ps1.
#
# Usage:
#   .\transcode-to-hls.ps1 -VideoPath "D:\path\to\video.mp4" -LectureId test-lecture-1
#
# Produces .\hls-out\<lecture-id>\{master.m3u8, 480p\, 720p\, 1080p\}
# Requires ffmpeg on PATH.

param(
    [Parameter(Mandatory=$true)][string]$VideoPath,
    [Parameter(Mandatory=$true)][string]$LectureId
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Error "ffmpeg not found on PATH. Install it first: https://www.gyan.dev/ffmpeg/builds/"
    exit 1
}

if (-not (Test-Path $VideoPath)) {
    Write-Error "Input file not found: $VideoPath"
    exit 1
}

# Forward slashes throughout, deliberately — ffmpeg writes these path
# templates verbatim into the playlist files as relative URLs. Windows file
# I/O accepts forward slashes just fine, but HLS players resolve those
# references as strict URIs and silently mis-resolve a literal backslash,
# which is what caused segment fetches to 404 despite the playlists loading.
$OutRoot = "./hls-out/$LectureId"
New-Item -ItemType Directory -Force -Path "$OutRoot/480p" | Out-Null
New-Item -ItemType Directory -Force -Path "$OutRoot/720p" | Out-Null
New-Item -ItemType Directory -Force -Path "$OutRoot/1080p" | Out-Null

Write-Host "Transcoding $VideoPath -> $OutRoot (480p/720p/1080p)..."

ffmpeg -y -i "$VideoPath" `
  -filter_complex "[0:v]split=3[v1][v2][v3]; [v1]scale=w=854:h=480[v1out]; [v2]scale=w=1280:h=720[v2out]; [v3]scale=w=1920:h=1080[v3out]" `
  -map "[v1out]" -c:v:0 h264 -b:v:0 900k  -maxrate:v:0 963k  -bufsize:v:0 1350k `
  -map "[v2out]" -c:v:1 h264 -b:v:1 2500k -maxrate:v:1 2675k -bufsize:v:1 3750k `
  -map "[v3out]" -c:v:2 h264 -b:v:2 5000k -maxrate:v:2 5350k -bufsize:v:2 7500k `
  -map a:0 -c:a:0 aac -b:a:0 128k `
  -map a:0 -c:a:1 aac -b:a:1 128k `
  -map a:0 -c:a:2 aac -b:a:2 128k `
  -f hls -hls_time 6 -hls_playlist_type vod `
  -hls_flags independent_segments `
  -hls_segment_type mpegts `
  -master_pl_name master.m3u8 `
  -var_stream_map "v:0,a:0,name:480p v:1,a:1,name:720p v:2,a:2,name:1080p" `
  -hls_segment_filename "$OutRoot/%v/seg_%03d.ts" `
  "$OutRoot/%v/index.m3u8"

Write-Host ""
Write-Host "Done. HLS output at: $OutRoot"
Write-Host "Next: .\upload-to-r2.ps1 -LocalDir `"$OutRoot`" -RemotePrefix `"videos/$LectureId`""
