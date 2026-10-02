// Two independent gates, both configured from Vercel env vars (Project
// Settings -> Environment Variables; a change needs a redeploy to apply).
// /api/* is never gated: the mobile app calls it directly.
//
// 1) STAFF GATE (admin.html, teacher.html, /login): only the owner's IPs, or
//    anyone who knows the separate gate password. Teachers use the app, so
//    nobody else needs these pages. This is in front of the normal Supabase
//    sign-in + role check, not a replacement for it.
//      STAFF_ALLOWED_IPS  comma list, exact IPs or IPv4 CIDR ranges,
//                         e.g. "93.191.113.10, 83.171.206.0/24"
//      STAFF_GATE_USER / STAFF_GATE_PASS
//                         Basic Auth fallback for when the ISP hands out a
//                         new IP (Iraqi ISPs rotate them).
//    Fails CLOSED: with nothing configured, staff pages are not served.
//
// 2) SITE GATE (everything else): optional whole-site Basic Auth via
//    SITE_BASIC_AUTH_USER / SITE_BASIC_AUTH_PASS. Fails OPEN when unset, so
//    the public landing and legal pages stay reachable.
export const config = {
  matcher: ['/((?!api/).*)'],
};

const STAFF_PATHS = new Set([
  '/login', '/login.html', '/staff-login.js',
  '/admin', '/admin.html',
  '/teacher', '/teacher.html',
]);

function clientIp(request) {
  // Set by Vercel's edge from the actual connection; a client can't spoof it.
  const real = request.headers.get('x-real-ip');
  if (real) return real.trim();
  const fwd = request.headers.get('x-forwarded-for');
  return fwd ? fwd.split(',')[0].trim() : '';
}

function ipv4ToInt(ip) {
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p) || Number(p) > 255) return null;
    n = n * 256 + Number(p);
  }
  return n;
}

function ipAllowed(ip, list) {
  if (!ip) return false;
  for (const raw of list.split(',')) {
    const entry = raw.trim();
    if (!entry) continue;
    if (!entry.includes('/')) {
      if (entry.toLowerCase() === ip.toLowerCase()) return true;
      continue;
    }
    const [base, bitsStr] = entry.split('/');
    const bits = Number(bitsStr);
    const a = ipv4ToInt(ip);
    const b = ipv4ToInt(base);
    if (a === null || b === null || !(bits >= 0 && bits <= 32)) continue;
    const mask = bits === 0 ? 0 : (0xFFFFFFFF << (32 - bits)) >>> 0;
    if (((a & mask) >>> 0) === ((b & mask) >>> 0)) return true;
  }
  return false;
}

function basicAuthOk(request, user, pass) {
  if (!user || !pass) return false;
  const provided = request.headers.get('authorization') || '';
  return provided === 'Basic ' + btoa(`${user}:${pass}`);
}

// Old brand address -> new one, for pages only. /api/* never reaches this
// middleware (see matcher), so installed apps that still call the old host
// keep working. Browsers carry the #fragment across a redirect, so
// password-reset links (#access_token=...) still land correctly.
const OLD_HOSTS = new Set(['site-and-structure.vercel.app']);
const NEW_HOST = 'arcplatformiq.vercel.app';

export default function middleware(request) {
  const url = new URL(request.url);
  if (OLD_HOSTS.has(url.host)) {
    url.host = NEW_HOST;
    url.protocol = 'https:';
    url.port = '';
    return Response.redirect(url.toString(), 308);
  }

  // Normalize so /ADMIN.html, /admin.html/ or %61dmin.html can't slip past.
  let path = new URL(request.url).pathname;
  try { path = decodeURIComponent(path); } catch (e) { /* keep raw */ }
  path = path.toLowerCase().replace(/\/+$/, '') || '/';

  if (STAFF_PATHS.has(path)) {
    const ips = process.env.STAFF_ALLOWED_IPS || '';
    const gateUser = process.env.STAFF_GATE_USER;
    const gatePass = process.env.STAFF_GATE_PASS;

    if (ipAllowed(clientIp(request), ips)) return;
    if (basicAuthOk(request, gateUser, gatePass)) return;

    if (gateUser && gatePass) {
      return new Response('Authentication required.', {
        status: 401,
        headers: { 'WWW-Authenticate': 'Basic realm="Staff", charset="UTF-8"' },
      });
    }
    // No fallback configured: don't even confirm the page exists.
    return new Response('Not found.', { status: 404 });
  }

  const user = process.env.SITE_BASIC_AUTH_USER;
  const pass = process.env.SITE_BASIC_AUTH_PASS;
  if (!user || !pass) return;
  if (basicAuthOk(request, user, pass)) return;
  return new Response('Authentication required.', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="Arc Platform"' },
  });
}
