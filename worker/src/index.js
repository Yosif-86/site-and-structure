/**
 * Cloudflare Worker: token-gated proxy in front of the R2 video bucket.
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
 * URL shape: https://<worker-domain>/videos/<lectureId>/<...file>?token=<hex>&expires=<unix>&uid=<userId>
 * Token = sha256(SECURITY_KEY + folderPrefix + uid + expires), hex-encoded,
 * where folderPrefix is "/videos/<lectureId>" — the same value for every
 * file under that lecture, which is what get-video-url.js signs. Binding the
 * hash to uid ties each minted URL to the specific account it was issued to
 * (for logging/traceability); it does not by itself stop the URL from being
 * replayed by someone else before it expires — that's bounded by expiry and
 * gated at mint time by get-video-url.js's device/session check.
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
  if (path.endsWith('.mp4')) return 'video/mp4';
  return 'application/octet-stream';
}

// "/videos/<lectureId>/480p/index.m3u8" -> "/videos/<lectureId>"
function folderPrefixOf(path) {
  const parts = path.split('/'); // ['', 'videos', '<lectureId>', ...]
  return '/' + parts.slice(1, 3).join('/');
}

function withAuth(uri, token, expires, uid) {
  const sep = uri.includes('?') ? '&' : '?';
  return `${uri}${sep}token=${token}&expires=${expires}&uid=${encodeURIComponent(uid)}`;
}

// Appends the given token/expires/uid to every URI line in an m3u8 playlist
// so nested fetches (variant playlists, segments) stay authorized. Also
// rewrites the URI inside an #EXT-X-KEY tag (the AES-128 key request) —
// unlike other #EXT... metadata lines, this one names an actual resource the
// player will fetch, and without a token that fetch would 403 (or, if the
// Worker didn't require one, would let anyone with just the playlist pull
// the decryption key with no auth at all). Every other #EXT... line and
// blank lines are left untouched.
function signPlaylist(text, token, expires, uid) {
  return text
    .split('\n')
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('#EXT-X-KEY')) {
        return line.replace(/URI="([^"]+)"/, (_match, uri) => `URI="${withAuth(uri, token, expires, uid)}"`);
      }
      if (trimmed.startsWith('#')) return line;
      return withAuth(trimmed, token, expires, uid);
    })
    .join('\n');
}

// The player (hls.js in course.html, video_player_screen.dart in the mobile
// app) fetches the manifest and every segment via XHR/fetch from a different
// origin than this Worker, so every response — including error ones, which
// the player's error handler also reads — needs CORS headers or the browser
// blocks the read entirely regardless of the underlying HTTP status.
function corsHeaders() {
  const headers = new Headers();
  headers.set('access-control-allow-origin', '*');
  headers.set('access-control-allow-methods', 'GET, HEAD, PUT, POST, DELETE, OPTIONS');
  headers.set('access-control-allow-headers', 'range, content-type');
  headers.set('access-control-expose-headers', 'content-range, content-length, accept-ranges');
  return headers;
}

function errorResponse(message, status) {
  return new Response(message, { status, headers: corsHeaders() });
}

function json(body, status = 200) {
  const headers = corsHeaders();
  headers.set('content-type', 'application/json');
  return new Response(JSON.stringify(body), { status, headers });
}

const UPLOAD_KEY = /^videos\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/source\.mp4$/i;

/**
 * Lecture uploads from the teacher app, written through this Worker's own
 * R2 binding so no R2 API keys are needed anywhere else.
 *
 *   /upload/<key>?op=create            POST  -> { uploadId }
 *   /upload/<key>?op=part&uploadId&partNumber   PUT body=bytes -> { partNumber, etag }
 *   /upload/<key>?op=complete&uploadId POST  body=[{partNumber, etag}] -> { size }
 *   /upload/<key>?op=abort&uploadId    POST  -> { ok }
 *   /delete/<key>                      POST  -> { ok }   (admin rejecting a lecture)
 *
 * Every call carries token/expires/uid minted by api/r2-upload.js:
 * token = sha256(SECURITY_KEY + action + ':' + key + uid + expires), so a
 * token only ever works for one action on one object.
 */
async function handleWrite(request, env, url) {
  const [, action, ...rest] = url.pathname.split('/');
  const key = rest.join('/');
  if (!UPLOAD_KEY.test(key)) return json({ error: 'Bad key' }, 400);

  const token = url.searchParams.get('token');
  const expires = url.searchParams.get('expires');
  const uid = url.searchParams.get('uid');
  if (!token || !expires || !uid) return json({ error: 'Missing token' }, 403);
  if (!(Number(expires) > Math.floor(Date.now() / 1000))) {
    return json({ error: 'Token expired' }, 403);
  }
  const expected = await sha256Hex(env.SECURITY_KEY + action + ':' + key + uid + expires);
  if (expected !== token) return json({ error: 'Invalid token' }, 403);

  const bucket = env.VIDEOS_BUCKET;
  if (action === 'delete') {
    await bucket.delete(key);
    return json({ ok: true });
  }

  const op = url.searchParams.get('op');
  const uploadId = url.searchParams.get('uploadId');
  try {
    if (op === 'create') {
      const mpu = await bucket.createMultipartUpload(key, {
        httpMetadata: { contentType: 'video/mp4' },
      });
      return json({ uploadId: mpu.uploadId });
    }
    if (!uploadId) return json({ error: 'Missing uploadId' }, 400);
    const mpu = bucket.resumeMultipartUpload(key, uploadId);
    if (op === 'part') {
      const partNumber = Number(url.searchParams.get('partNumber'));
      if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000) {
        return json({ error: 'Bad partNumber' }, 400);
      }
      const part = await mpu.uploadPart(partNumber, await request.arrayBuffer());
      return json({ partNumber: part.partNumber, etag: part.etag });
    }
    if (op === 'complete') {
      const parts = await request.json();
      const object = await mpu.complete(
        parts.map((p) => ({ partNumber: Number(p.partNumber), etag: String(p.etag) })),
      );
      return json({ size: object.size });
    }
    if (op === 'abort') {
      await mpu.abort();
      return json({ ok: true });
    }
    return json({ error: 'Unknown op' }, 400);
  } catch (e) {
    return json({ error: 'R2 error', detail: String((e && e.message) || e) }, 500);
  }
}

// Files the automatic conversion job (GitHub Actions) may touch: the
// uploaded source and the HLS output scripts/transcode-to-hls.sh produces.
const CONVERT_PATH = /^videos\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/(source\.mp4|master\.m3u8|enc\.key|(480p|720p|1080p)\/(index\.m3u8|seg_\d{3,5}\.ts))$/i;

function sameSecret(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Conversion job access, authorized by the CONVERT_KEY secret (header
 * x-convert-key), shared only with the GitHub Actions workflow:
 *   GET    /convert/videos/<id>/source.mp4   download the uploaded source
 *   PUT    /convert/videos/<id>/<hls file>   write one converted file
 *   DELETE /convert/videos/<id>/source.mp4   remove the source afterwards
 */
async function handleConvert(request, env, url) {
  if (!env.CONVERT_KEY || !sameSecret(request.headers.get('x-convert-key') || '', env.CONVERT_KEY)) {
    return json({ error: 'Forbidden' }, 403);
  }
  const key = url.pathname.slice('/convert/'.length);
  if (!CONVERT_PATH.test(key)) return json({ error: 'Bad path' }, 400);
  const isSource = key.endsWith('/source.mp4');
  const bucket = env.VIDEOS_BUCKET;

  if (request.method === 'GET' && isSource) {
    const object = await bucket.get(key);
    if (!object) return json({ error: 'Not found' }, 404);
    return new Response(object.body, { headers: { 'content-type': 'video/mp4' } });
  }
  if (request.method === 'PUT' && !isSource) {
    await bucket.put(key, request.body, {
      httpMetadata: { contentType: contentTypeFor(key) },
    });
    return json({ ok: true });
  }
  if (request.method === 'DELETE' && isSource) {
    await bucket.delete(key);
    return json({ ok: true });
  }
  return json({ error: 'Not allowed' }, 405);
}

/**
 * Daily storage cleanup (cron in wrangler.toml). Deleting a lecture, course
 * or account removes database rows only, so this removes what they leave:
 *   - R2 folders videos/<lectureId>/ whose lecture no longer exists
 *   - course-files objects no course_files row points to
 * Anything uploaded in the last two days is left alone, so an upload still
 * in progress can't be caught. CLEANUP_MODE = "live" deletes; anything else
 * only logs what it would delete. Needs the SUPABASE_SERVICE_ROLE_KEY secret
 * and add-storage-cleanup.sql.
 */
const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const LECTURE_FOLDER = /^videos\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/$/i;
const MIN_AGE_MS = 2 * 24 * 60 * 60 * 1000;
const MAX_FOLDERS_PER_RUN = 20;

async function supabase(env, path, init = {}) {
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  const res = await fetch(`${SUPABASE_URL}${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

async function cleanupStorage(env) {
  const live = env.CLEANUP_MODE === 'live';
  const report = { live, videoFolders: [], videoObjects: 0, courseFiles: [] };
  if (!env.SUPABASE_SERVICE_ROLE_KEY) {
    console.log('cleanup: SUPABASE_SERVICE_ROLE_KEY not set, skipping');
    return report;
  }
  const bucket = env.VIDEOS_BUCKET;

  // 1. Lecture folders in R2.
  const ids = [];
  let cursor;
  do {
    const page = await bucket.list({ prefix: 'videos/', delimiter: '/', cursor });
    for (const p of page.delimitedPrefixes || []) {
      const m = LECTURE_FOLDER.exec(p);
      if (m) ids.push(m[1]);
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  const missing = [];
  for (let i = 0; i < ids.length; i += 200) {
    const rows = await supabase(env, '/rest/v1/rpc/missing_lecture_ids', {
      method: 'POST',
      body: JSON.stringify({ p_ids: ids.slice(i, i + 200) }),
    });
    for (const r of rows || []) missing.push(typeof r === 'string' ? r : r.missing_lecture_ids);
  }

  for (const id of missing.slice(0, MAX_FOLDERS_PER_RUN)) {
    const keys = [];
    let recent = false;
    let c;
    do {
      const page = await bucket.list({ prefix: `videos/${id}/`, cursor: c });
      for (const o of page.objects) {
        keys.push(o.key);
        if (Date.now() - new Date(o.uploaded).getTime() < MIN_AGE_MS) recent = true;
      }
      c = page.truncated ? page.cursor : undefined;
    } while (c);
    if (recent || keys.length === 0) continue;
    if (live) {
      for (let i = 0; i < keys.length; i += 1000) await bucket.delete(keys.slice(i, i + 1000));
    }
    report.videoFolders.push(id);
    report.videoObjects += keys.length;
  }

  // 2. Course files (Supabase Storage).
  const paths = await supabase(env, '/rest/v1/rpc/orphan_course_file_paths', {
    method: 'POST',
    body: JSON.stringify({ p_limit: 200 }),
  });
  report.courseFiles = (paths || []).map((r) =>
    typeof r === 'string' ? r : r.orphan_course_file_paths);
  if (live && report.courseFiles.length) {
    await supabase(env, '/storage/v1/object/course-files', {
      method: 'DELETE',
      body: JSON.stringify({ prefixes: report.courseFiles }),
    });
  }

  console.log('cleanup:', JSON.stringify({
    live,
    videoFolders: report.videoFolders.length,
    videoObjects: report.videoObjects,
    courseFiles: report.courseFiles.length,
    folders: report.videoFolders,
    files: report.courseFiles,
  }));
  return report;
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(cleanupStorage(env).catch((e) => console.error('cleanup failed', e)));
  },

  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);
    const path = url.pathname; // e.g. /videos/<lectureId>/480p/index.m3u8

    if (path.startsWith('/upload/') || path.startsWith('/delete/')) {
      return handleWrite(request, env, url);
    }
    if (path.startsWith('/convert/')) {
      return handleConvert(request, env, url);
    }
    const token = url.searchParams.get('token');
    const expires = url.searchParams.get('expires');
    const uid = url.searchParams.get('uid');

    if (!token || !expires || !uid) {
      return errorResponse('Missing token', 403);
    }

    const expiresNum = Number(expires);
    if (!Number.isFinite(expiresNum) || Math.floor(Date.now() / 1000) > expiresNum) {
      return errorResponse('Token expired', 403);
    }

    const prefix = folderPrefixOf(path);
    const expected = await sha256Hex(env.SECURITY_KEY + prefix + uid + expires);
    if (expected !== token) {
      return errorResponse('Invalid token', 403);
    }

    const objectKey = path.replace(/^\/+/, ''); // R2 keys have no leading slash

    // A single MP4 (lectures uploaded from the teacher app) is streamed with
    // byte ranges, so the player can seek without downloading from the start.
    if (path.endsWith('.mp4')) {
      const mp4 = await env.VIDEOS_BUCKET.get(objectKey, { range: request.headers });
      if (!mp4) {
        return errorResponse('Not found', 404);
      }
      const h = corsHeaders();
      h.set('cache-control', 'private, max-age=60');
      h.set('accept-ranges', 'bytes');
      h.set('x-content-type-options', 'nosniff');
      h.set('content-type', 'video/mp4');
      const range = mp4.range;
      if (request.headers.has('range') && range) {
        const start = range.offset ?? (mp4.size - range.suffix);
        const length = range.length ?? (mp4.size - start);
        h.set('content-range', `bytes ${start}-${start + length - 1}/${mp4.size}`);
        h.set('content-length', String(length));
        return new Response(mp4.body, { status: 206, headers: h });
      }
      h.set('content-length', String(mp4.size));
      return new Response(mp4.body, { headers: h });
    }

    const object = await env.VIDEOS_BUCKET.get(objectKey);
    if (!object) {
      return errorResponse('Not found', 404);
    }

    const headers = corsHeaders();
    headers.set('cache-control', 'private, max-age=60');
    headers.set('accept-ranges', 'bytes');
    headers.set('x-content-type-options', 'nosniff');

    if (path.endsWith('.m3u8')) {
      const text = await object.text();
      headers.set('content-type', contentTypeFor(path));
      return new Response(signPlaylist(text, token, expires, uid), { headers });
    }

    headers.set('content-type', contentTypeFor(path));
    return new Response(object.body, { headers });
  },
};
