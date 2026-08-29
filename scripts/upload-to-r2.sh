#!/usr/bin/env bash
# Uploads a local HLS output folder (from transcode-to-hls.sh) to Cloudflare R2.
# R2 is S3-API-compatible, so this uses the AWS CLI pointed at R2's endpoint.
#
# Usage:
#   R2_ACCOUNT_ID=xxxx R2_ACCESS_KEY_ID=xxxx R2_SECRET_ACCESS_KEY=xxxx \
#   R2_BUCKET=site-structure-videos \
#   ./upload-to-r2.sh ./hls-out/<lecture-id> videos/<lecture-id>
#
# Requires: AWS CLI (https://aws.amazon.com/cli/) on PATH.
# Never hardcode R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY in this file or in chat —
# pass them as env vars in your own shell, or via a local .env you source yourself.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_BUCKET=... $0 <local-hls-dir> <remote-prefix>" >&2
  exit 1
fi

LOCAL_DIR="$1"
REMOTE_PREFIX="$2"

: "${R2_ACCOUNT_ID:?Set R2_ACCOUNT_ID}"
: "${R2_ACCESS_KEY_ID:?Set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?Set R2_SECRET_ACCESS_KEY}"
: "${R2_BUCKET:?Set R2_BUCKET}"

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI not found. Install it first: https://aws.amazon.com/cli/" >&2
  exit 1
fi

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"

echo "Uploading $LOCAL_DIR -> r2://$R2_BUCKET/$REMOTE_PREFIX ..."

# .m3u8 playlists need the right content-type for players to accept them;
# .ts segments get the standard mpeg-ts type. Two passes keep metadata correct.
aws s3 cp "$LOCAL_DIR" "s3://${R2_BUCKET}/${REMOTE_PREFIX}" \
  --recursive \
  --endpoint-url "$ENDPOINT" \
  --exclude "*.ts" \
  --content-type "application/vnd.apple.mpegurl"

aws s3 cp "$LOCAL_DIR" "s3://${R2_BUCKET}/${REMOTE_PREFIX}" \
  --recursive \
  --endpoint-url "$ENDPOINT" \
  --exclude "*.m3u8" \
  --content-type "video/mp2t"

echo ""
echo "Done. Objects live under: ${REMOTE_PREFIX}/master.m3u8, ${REMOTE_PREFIX}/480p/..., etc."
echo "Set lectures.bunny_video_id (or a new r2_path column) to: ${REMOTE_PREFIX}"
