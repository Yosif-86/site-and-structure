/**
 * Cloudflare Worker: token-gated proxy in front of the R2 video bucket.
 * Mirrors Bunny Stream's own token-auth scheme so api/get-video-url.js
 * only had to change how it builds the URL, not its enrollment logic.
 *
 * The token is scoped to a whole lecture folder (not one file) because HLS
 * playback means many requests — the master playlist, one variant playlist
 * per quality level, and every .ts segment — and only the very first request
 * carries the query string a browser/player was originally given. Every
 * nested reference inside a fetched .m3u8 is a *relative* URL, so without
 * rewriting, only the master playlist would ever see the token and every
 * link inside it would come back 403. To fix that, whenever this Worker
 * serves an .m3u8 file it rewrites every line in it to carry the same
 * still-valid token+expires, so each subsequent fetch is already signed.
 *
 * URL shape: https://<worker-domain>/videos/<lectureId>/<...file>?token=<hex>&expires=<unix>
 * Token = sha256(SECURITY_KEY + folderPrefix + expires), hex-encoded, where
 * folderPrefix is "/videos/<lectureId>" — the same value for every file
 * under that lecture, which is what get-video-url.js signs.
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

// "/videos/<lectureId>/480p/index.m3u8" -> "/videos/<lectureId>"
function folderPrefixOf(path) {
  const parts = path.split('/'); // ['', 'videos', '<lectureId>', ...]
  return '/' + parts.slice(1, 3).join('/');
}

// Appends the given token/expires to every URI line in an m3u8 playlist so
// nested fetches (variant playlists, segments) stay authorized. Leaves
// #EXT... metadata lines and blank lines untouched.
function signPlaylist(text, token, expires) {
  return text
    .split('\n')
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      const sep = trimmed.includes('?') ? '&' : '?';
      return `${trimmed}${sep}token=${token}&expires=${expires}`;
    })
    .join('\n');
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname; // e.g. /videos/<lectureId>/480p/index.m3u8
    const token = url.searchParams.get('token');
    const expires = url.searchParams.get('expires');

    if (!token || !expires) {
      return new Response('Missing token', { status: 403 });
    }

    const expiresNum = Number(expires);
    if (!Number.isFinite(expiresNum) || Math.floor(Date.now() / 1000) > expiresNum) {
      return new Response('Token expired', { status: 403 });
    }

    const prefix = folderPrefixOf(path);
    const expected = await sha256Hex(env.SECURITY_KEY + prefix + expires);
    if (expected !== token) {
      return new Response('Invalid token', { status: 403 });
    }

    const objectKey = path.replace(/^\/+/, ''); // R2 keys have no leading slash
    const object = await env.VIDEOS_BUCKET.get(objectKey);
    if (!object) {
      return new Response('Not found', { status: 404 });
    }

    const headers = new Headers();
    headers.set('cache-control', 'private, max-age=60');
    headers.set('accept-ranges', 'bytes');

    if (path.endsWith('.m3u8')) {
      const text = await object.text();
      headers.set('content-type', contentTypeFor(path));
      return new Response(signPlaylist(text, token, expires), { headers });
    }

    headers.set('content-type', contentTypeFor(path));
    return new Response(object.body, { headers });
  },
};
