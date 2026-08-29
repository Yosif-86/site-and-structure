# Video Worker — deploy steps (Yosif runs these)

Prereqs: Node.js installed, a Cloudflare account with R2 enabled.

1. `cd worker`
2. `npm install`
3. Create the R2 bucket (skip if you already made it in the dashboard):
   `npx wrangler r2 bucket create site-structure-videos`
4. Set the signing secret — pick any long random string, this is the new
   equivalent of `BUNNY_STREAM_SECURITY_KEY`:
   `npx wrangler secret put SECURITY_KEY`
   (paste the secret when prompted — don't put it in any file)
5. Deploy: `npx wrangler deploy`
6. Wrangler prints the Worker's public URL, e.g.
   `https://site-structure-videos.<your-subdomain>.workers.dev`
   — this is the `WORKER_BASE_URL` needed by `api/get-video-url.js`.
7. In Vercel (Project Settings → Environment Variables), add:
   - `R2_SECURITY_KEY` = the same secret from step 4
   - `R2_WORKER_BASE_URL` = the URL from step 6

For uploading a new video after this is deployed, see `../scripts/transcode-to-hls.sh`
and `../scripts/upload-to-r2.sh`.
