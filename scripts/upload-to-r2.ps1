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
#
# Optional -LectureId: skips the manual "open admin.html and paste r2_path"
# step — set it and the script sets lectures.r2_path + clears
# pending_upload_path itself via the Supabase REST API, then deletes the raw
# upload from the lecture-uploads bucket, same as admin.html's own
# "Save & go live" button does. Needs SUPABASE_SERVICE_ROLE_KEY in your env
# (same key Vercel uses — find it in the Supabase dashboard's API settings,
# never in this file).
param(
    [Parameter(Mandatory=$true)][string]$LocalDir,
    [Parameter(Mandatory=$true)][string]$RemotePrefix,
    [string]$LectureId
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

if (-not $LectureId) {
    Write-Host "Then in Supabase SQL editor: update lectures set r2_path = '$RemotePrefix' where id = '<lectureId>';"
    exit 0
}

if (-not (Test-Path "env:SUPABASE_SERVICE_ROLE_KEY")) {
    Write-Error "LectureId given but SUPABASE_SERVICE_ROLE_KEY is not set — can't auto-publish. Set it, or omit -LectureId and run: update lectures set r2_path = '$RemotePrefix' where id = '$LectureId';"
    exit 1
}

$SupabaseUrl = "https://qdarzhzttjpkgfihupgp.supabase.co"
$Headers = @{
    "apikey"        = $env:SUPABASE_SERVICE_ROLE_KEY
    "Authorization" = "Bearer $($env:SUPABASE_SERVICE_ROLE_KEY)"
    "Content-Type"  = "application/json"
}

Write-Host "Looking up lecture $LectureId ..."
$lecture = Invoke-RestMethod -Method Get `
    -Uri "$SupabaseUrl/rest/v1/lectures?id=eq.$LectureId&select=pending_upload_path" `
    -Headers $Headers
if (-not $lecture -or $lecture.Count -eq 0) {
    Write-Error "No lecture found with id $LectureId — r2 upload succeeded but the DB was not updated. Publish it manually."
    exit 1
}
$pendingPath = $lecture[0].pending_upload_path

Write-Host "Setting lectures.r2_path and clearing pending_upload_path ..."
Invoke-RestMethod -Method Patch `
    -Uri "$SupabaseUrl/rest/v1/lectures?id=eq.$LectureId" `
    -Headers $Headers `
    -Body (@{ r2_path = $RemotePrefix; pending_upload_path = $null } | ConvertTo-Json) | Out-Null

if ($pendingPath) {
    Write-Host "Deleting raw upload from lecture-uploads bucket ..."
    try {
        Invoke-RestMethod -Method Delete `
            -Uri "$SupabaseUrl/storage/v1/object/lecture-uploads/$pendingPath" `
            -Headers $Headers | Out-Null
    } catch {
        Write-Warning "Could not delete raw upload (lecture is still published fine): $_"
    }
}

Write-Host "Lecture $LectureId is live."
