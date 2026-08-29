/**
 * Cloudflare Worker: token-gated proxy in front of the R2 video bucket.
 * Mirrors Bunny Stream's own token-auth scheme so api/get-video-url.js
 * only had to change how it builds the URL, not its enrollment logic.
 *
 * URL shape: https://<worker-domain>/<path-in-bucket>?token=<hex>&expires=<unix>
 * Token = sha256(SECURITY_KEY + path + expires), hex-encoded.
 * `path` is the request pathname (leading slash included), matching exactly
 * what get-video-url.js signs — e.g. "/videos/<lectureId>/master.m3u8".
 *
 * Bind the R2 bucket in wrangler.toml as `VIDEOS_BUCKET`, and set the
 * `SECURITY_KEY` secret via `wrangler secret put SECURITY_KEY` (never commit it).
 */

async function sha256Hex(input) {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function contentTypeFor(path) {
  if (path.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
  if (path.endsWith('.ts')) return 'video/mp2t';
  return 'application/octet-stream';
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname; // e.g. /videos/<lectureId>/master.m3u8
    const token = url.searchParams.get('token');
    const expires = url.searchParams.get('expires');

    if (!token || !expires) {
      return new Response('Missing token', { status: 403 });
    }

    const expiresNum = Number(expires);
    if (!Number.isFinite(expiresNum) || Math.floor(Date.now() / 1000) > expiresNum) {
      return new Response('Token expired', { status: 403 });
    }

    const expected = await sha256Hex(env.SECURITY_KEY + path + expires);
    if (expected !== token) {
      return new Response('Invalid token', { status: 403 });
    }

    // R2 object keys don't have a leading slash.
    const objectKey = path.replace(/^\/+/, '');
    const object = await env.VIDEOS_BUCKET.get(objectKey);
    if (!object) {
      return new Response('Not found', { status: 404 });
    }

    const headers = new Headers();
    headers.set('content-type', contentTypeFor(path));
    headers.set('cache-control', 'private, max-age=60');
    // HLS players (esp. iOS) need range support for segment fetching.
    headers.set('accept-ranges', 'bytes');

    return new Response(object.body, { headers });
  },
};
