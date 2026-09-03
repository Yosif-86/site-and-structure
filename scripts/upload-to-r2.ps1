# Uploads a local HLS output folder (from transcode-to-hls.ps1) to Cloudflare R2.
# R2 is S3-API-compatible, so this uses the AWS CLI pointed at R2's endpoint.
#
# Usage:
#   $env:R2_ACCOUNT_ID = "xxxx"
#   $env:R2_ACCESS_KEY_ID = "xxxx"
#   $env:R2_SECRET_ACCESS_KEY = "xxxx"
#   $env:R2_BUCKET = "site-structure-videos"
#   .\upload-to-r2.ps1 -LocalDir ".\hls-out\test-lecture-1" -RemotePrefix "videos/test-lecture-1"
#
# Requires: AWS CLI (https://aws.amazon.com/cli/) on PATH.
# Never hardcode your R2 keys in this file — set them as env vars in your own
# shell session first, as shown above.

param(
    [Parameter(Mandatory=$true)][string]$LocalDir,
    [Parameter(Mandatory=$true)][string]$RemotePrefix
)

$ErrorActionPreference = "Stop"

foreach ($name in @("R2_ACCOUNT_ID","R2_ACCESS_KEY_ID","R2_SECRET_ACCESS_KEY","R2_BUCKET")) {
    if (-not (Test-Path "env:$name")) {
        Write-Error "Missing required env var: $name"
        exit 1
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "AWS CLI not found on PATH. Install it first: https://aws.amazon.com/cli/"
    exit 1
}

$Endpoint = "https://$($env:R2_ACCOUNT_ID).r2.cloudflarestorage.com"
$env:AWS_ACCESS_KEY_ID = $env:R2_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY = $env:R2_SECRET_ACCESS_KEY
$env:AWS_DEFAULT_REGION = "auto"

Write-Host "Uploading $LocalDir -> r2://$($env:R2_BUCKET)/$RemotePrefix ..."

aws s3 cp "$LocalDir" "s3://$($env:R2_BUCKET)/$RemotePrefix" `
  --recursive `
  --endpoint-url "$Endpoint" `
  --exclude "*" --include "*.m3u8" `
  --content-type "application/vnd.apple.mpegurl"

# .ts segments and the AES-128 enc.key both get a generic type here — the
# Worker always overrides content-type by extension when serving anyway
# (worker/src/index.js's contentTypeFor), so this only matters for tidiness.
# enc.keyinfo is a local-only ffmpeg input (holds an absolute local path) and
# is deliberately never uploaded.
aws s3 cp "$LocalDir" "s3://$($env:R2_BUCKET)/$RemotePrefix" `
  --recursive `
  --endpoint-url "$Endpoint" `
  --exclude "*.m3u8" --exclude "*.keyinfo" `
  --content-type "video/mp2t"

Write-Host ""
Write-Host "Done. Objects live under: $RemotePrefix/master.m3u8, $RemotePrefix/480p/..., etc."
Write-Host "Then in Supabase SQL editor: update lectures set r2_path = '$RemotePrefix' where id = '<lectureId>';"
