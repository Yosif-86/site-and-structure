#!/usr/bin/env bash
# Uploads a local HLS output folder (from transcode-to-hls.sh) to Cloudflare R2.
# R2 is S3-API-compatible, so this uses the AWS CLI pointed at R2's endpoint.
#
# Usage:
#   R2_ACCOUNT_ID=xxxx R2_ACCESS_KEY_ID=xxxx R2_SECRET_ACCESS_KEY=xxxx \
#   R2_BUCKET=site-structure-videos \
#   ./upload-to-r2.sh ./hls-out/<lecture-id> videos/<lecture-id> [lecture-id]
#
# Requires: AWS CLI (https://aws.amazon.com/cli/) on PATH.
# Never hardcode R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY in this file or in chat —
# pass them as env vars in your own shell, or via a local .env you source yourself.
#
# Optional 3rd arg (lecture-id): skips the manual "open admin.html and paste
# r2_path" step — pass it and the script sets lectures.r2_path + clears
# pending_upload_path itself via the Supabase REST API, then deletes the raw
# upload from the lecture-uploads bucket, same as admin.html's own
# "Save & go live" button does. Needs SUPABASE_SERVICE_ROLE_KEY in your env
# (same key Vercel uses — find it in the Supabase dashboard's API settings,
# never in this file).

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_BUCKET=... $0 <local-hls-dir> <remote-prefix> [lecture-id]" >&2
  exit 1
fi

LOCAL_DIR="$1"
REMOTE_PREFIX="$2"
LECTURE_ID="${3:-}"

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
  --exclude "*" --include "*.m3u8" \
  --content-type "application/vnd.apple.mpegurl"

# .ts segments and the AES-128 enc.key both get a generic type here — the
# Worker always overrides content-type by extension when serving anyway
# (worker/src/index.js's contentTypeFor), so this only matters for tidiness.
# enc.keyinfo is a local-only ffmpeg input (holds an absolute local path) and
# is deliberately never uploaded.
aws s3 cp "$LOCAL_DIR" "s3://${R2_BUCKET}/${REMOTE_PREFIX}" \
  --recursive \
  --endpoint-url "$ENDPOINT" \
  --exclude "*.m3u8" --exclude "*.keyinfo" \
  --content-type "video/mp2t"

echo ""
echo "Done. Objects live under: ${REMOTE_PREFIX}/master.m3u8, ${REMOTE_PREFIX}/480p/..., etc."

if [ -z "$LECTURE_ID" ]; then
  echo "Then in Supabase SQL editor: update lectures set r2_path = '${REMOTE_PREFIX}' where id = '<lectureId>';"
  exit 0
fi

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "Lecture id given but SUPABASE_SERVICE_ROLE_KEY is not set — can't auto-publish. Set it, or omit the lecture id and run: update lectures set r2_path = '${REMOTE_PREFIX}' where id = '${LECTURE_ID}';" >&2
  exit 1
fi

SUPABASE_URL="https://qdarzhzttjpkgfihupgp.supabase.co"

echo "Looking up lecture ${LECTURE_ID} ..."
PENDING_PATH=$(curl -sf \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  "${SUPABASE_URL}/rest/v1/lectures?id=eq.${LECTURE_ID}&select=pending_upload_path" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["pending_upload_path"] or "" if d else "")')

if [ -z "$PENDING_PATH" ] && [ "$PENDING_PATH" != "" ]; then
  echo "No lecture found with id ${LECTURE_ID} — r2 upload succeeded but the DB was not updated. Publish it manually." >&2
  exit 1
fi

echo "Setting lectures.r2_path and clearing pending_upload_path ..."
curl -sf -X PATCH \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  "${SUPABASE_URL}/rest/v1/lectures?id=eq.${LECTURE_ID}" \
  -d "{\"r2_path\": \"${REMOTE_PREFIX}\", \"pending_upload_path\": null}" > /dev/null

if [ -n "$PENDING_PATH" ]; then
  echo "Deleting raw upload from lecture-uploads bucket ..."
  curl -sf -X DELETE \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    "${SUPABASE_URL}/storage/v1/object/lecture-uploads/${PENDING_PATH}" > /dev/null \
    || echo "Warning: could not delete raw upload (lecture is still published fine)." >&2
fi

echo "Lecture ${LECTURE_ID} is live."
