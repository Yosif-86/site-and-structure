// Best-effort, in-memory rate limiter for Vercel serverless functions.
//
// Caveat (read before relying on this): each serverless instance has its own
// memory, and Vercel can spin up multiple instances for the same function
// under load or across regions, so this does NOT give a hard global cap —
// a determined attacker spread across enough concurrent requests can exceed
// the stated limit. It DOES stop the common case (a single script hammering
// one endpoint from one place) and costs nothing to run. For a real
// guarantee, move this to Upstash Redis (Vercel's marketplace add-on) or a
// Cloudflare Rate Limiting Rule in front of the Worker — both are dashboard
// setup, not a code change, which is why this repo ships the in-memory
// version first.
const buckets = new Map();

// Periodically forget old buckets so this doesn't leak memory on a
// long-lived warm instance.
function sweep(now) {
  for (const [key, entry] of buckets) {
    if (now - entry.windowStart > 5 * 60 * 1000) buckets.delete(key);
  }
}

/**
 * @param {string} key - usually the caller's IP plus a route tag.
 * @param {number} limit - max requests allowed per window.
 * @param {number} windowMs - window size in milliseconds.
 * @returns {boolean} true if the request is allowed, false if it should be rejected.
 */
function allow(key, limit, windowMs) {
  const now = Date.now();
  if (buckets.size > 5000) sweep(now);

  let entry = buckets.get(key);
  if (!entry || now - entry.windowStart > windowMs) {
    entry = { windowStart: now, count: 0 };
    buckets.set(key, entry);
  }
  entry.count += 1;
  return entry.count <= limit;
}

function clientIp(req) {
  const fwd = req.headers['x-forwarded-for'];
  if (typeof fwd === 'string' && fwd.length) return fwd.split(',')[0].trim();
  return req.socket?.remoteAddress || 'unknown';
}

module.exports = { allow, clientIp };
