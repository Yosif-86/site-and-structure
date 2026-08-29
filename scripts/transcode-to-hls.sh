#!/usr/bin/env bash
# Transcodes a source video into multi-bitrate HLS (480p/720p/1080p) with a
# master playlist, ready to upload to R2 via upload-to-r2.sh.
#
# Usage:
#   ./transcode-to-hls.sh <input-video> <lecture-id>
#
# Produces ./hls-out/<lecture-id>/{master.m3u8, 480p/, 720p/, 1080p/}
#
# Requires ffmpeg (https://ffmpeg.org/download.html) on PATH.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <input-video> <lecture-id>" >&2
  exit 1
fi

INPUT="$1"
LECTURE_ID="$2"
OUT_ROOT="./hls-out/${LECTURE_ID}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Install it first: https://ffmpeg.org/download.html" >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "Input file not found: $INPUT" >&2
  exit 1
fi

mkdir -p "$OUT_ROOT/480p" "$OUT_ROOT/720p" "$OUT_ROOT/1080p"

echo "Transcoding $INPUT -> $OUT_ROOT (480p/720p/1080p)..."

# One ffmpeg run producing all three renditions + segmented HLS output per rendition.
ffmpeg -y -i "$INPUT" \
  -filter_complex "[0:v]split=3[v1][v2][v3]; \
    [v1]scale=w=854:h=480[v1out]; \
    [v2]scale=w=1280:h=720[v2out]; \
    [v3]scale=w=1920:h=1080[v3out]" \
  -map "[v1out]" -c:v:0 h264 -b:v:0 900k  -maxrate:v:0 963k  -bufsize:v:0 1350k \
  -map "[v2out]" -c:v:1 h264 -b:v:1 2500k -maxrate:v:1 2675k -bufsize:v:1 3750k \
  -map "[v3out]" -c:v:2 h264 -b:v:2 5000k -maxrate:v:2 5350k -bufsize:v:2 7500k \
  -map a:0 -c:a:0 aac -b:a:0 128k \
  -map a:0 -c:a:1 aac -b:a:1 128k \
  -map a:0 -c:a:2 aac -b:a:2 128k \
  -f hls -hls_time 6 -hls_playlist_type vod \
  -hls_flags independent_segments \
  -hls_segment_type mpegts \
  -master_pl_name master.m3u8 \
  -var_stream_map "v:0,a:0,name:480p v:1,a:1,name:720p v:2,a:2,name:1080p" \
  -hls_segment_filename "$OUT_ROOT/%v/seg_%03d.ts" \
  "$OUT_ROOT/%v/index.m3u8"

echo ""
echo "Done. HLS output at: $OUT_ROOT"
echo "Next: ./upload-to-r2.sh \"$OUT_ROOT\" \"videos/${LECTURE_ID}\""
