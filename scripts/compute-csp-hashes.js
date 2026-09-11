#!/usr/bin/env node
/**
 * compute-csp-hashes.js — single source of truth for the site's
 * Content-Security-Policy header in vercel.json.
 *
 * ===========================================================================
 *  IF YOU EDIT ANY <script> BLOCK INSIDE AN .html FILE, YOU MUST RUN:
 *
 *      node scripts/compute-csp-hashes.js --write
 *
 *  ...and commit the resulting vercel.json change together with the .html
 *  change. Otherwise the browser will refuse to run that script block and the
 *  page will look broken (buttons do nothing, tables stay empty) with only a
 *  "Refused to execute inline script" message in the browser console.
 * ===========================================================================
 *
 * Why hashes and not a nonce: the site is plain static HTML with no build step
 * and no server rendering, so there is nothing to generate a fresh per-request
 * nonce. CSP's other option for allowing a *specific* inline script is a
 * SHA-256 hash of that script's exact contents, which is what this produces.
 * The point of all this is that script-src contains NO 'unsafe-inline': if an
 * XSS bug ever lets attacker markup reach innerHTML again, the injected script
 * has no matching hash and the browser will not run it.
 *
 * Usage:
 *   node scripts/compute-csp-hashes.js            print the policy + status
 *   node scripts/compute-csp-hashes.js --write    rewrite vercel.json
 *   node scripts/compute-csp-hashes.js --check    exit 1 if vercel.json stale
 *                                                 (handy in CI)
 *
 * LINE ENDINGS — the subtle one. The checked-out working tree on Windows has
 * CRLF line endings, but git stores these files with LF and Vercel builds from
 * a Linux checkout, so the bytes the browser actually hashes use LF. This
 * script therefore normalises CRLF to LF before hashing. Hashing the raw
 * Windows bytes would produce hashes that work nowhere.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');
const PAGES = ['index.html', 'course.html', 'admin.html', 'my-courses.html', 'reset-password.html'];
const VERCEL_JSON = path.join(ROOT, 'vercel.json');

// --- Origins the pages legitimately talk to ------------------------------
// Grepped out of the HTML/api sources, not guessed. Keep this list tight:
// every entry is something an XSS payload would also be allowed to reach.

// The Supabase JS SDK, loaded as a normal <script src>.
const CDN_ORIGIN = 'https://cdn.jsdelivr.net';
// Supabase project: auth, postgrest queries, storage uploads/signed URLs.
const SUPABASE_ORIGIN = 'https://qdarzhzttjpkgfihupgp.supabase.co';
// Coarse geolocation lookup used by the suspicious-login check.
const GEO_ORIGIN = 'https://ipapi.co';
// Bunny Stream player, loaded into the #videoFrame iframe on course.html.
const BUNNY_EMBED_ORIGIN = 'https://iframe.mediadelivery.net';
// Google Fonts: the stylesheet comes from googleapis, the font files gstatic.
const FONT_CSS_ORIGIN = 'https://fonts.googleapis.com';
const FONT_FILE_ORIGIN = 'https://fonts.gstatic.com';

// The Cloudflare Worker that serves the newer R2/HLS lectures. Confirmed
// live via `npx wrangler whoami` (account) + the Cloudflare API's
// /accounts/:id/workers/subdomain endpoint (subdomain) + wrangler.toml
// (worker name "site-structure-videos") + a direct curl (403 "Missing
// token", i.e. the worker itself responded) — not guessed.
const R2_WORKER_ORIGIN = 'https://site-structure-videos.siteandstructure.workers.dev';

/**
 * Extract every inline <script>...</script> body (i.e. those with no src=)
 * from an HTML source string.
 */
function inlineScripts(html) {
  const bodies = [];
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const attrs = m[1];
    if (/\bsrc\s*=/i.test(attrs)) continue; // external script, covered by host allowlist
    bodies.push(m[2]);
  }
  return bodies;
}

function sha256(body) {
  return "'sha256-" + crypto.createHash('sha256').update(body, 'utf8').digest('base64') + "'";
}

function collectHashes() {
  const hashes = [];        // unique, in first-seen order
  const seen = new Set();
  const perFile = {};
  for (const page of PAGES) {
    const raw = fs.readFileSync(path.join(ROOT, page), 'utf8');
    // Match what Vercel serves (LF), not the local CRLF checkout.
    const html = raw.replace(/\r\n/g, '\n');
    const bodies = inlineScripts(html);
    perFile[page] = bodies.map((b) => {
      const h = sha256(b);
      if (!seen.has(h)) { seen.add(h); hashes.push(h); }
      return h;
    });
  }
  return { hashes, perFile };
}

function buildCsp(hashes) {
  return [
    // Nothing loads from anywhere unless a directive below says otherwise.
    "default-src 'self'",
    // No 'unsafe-inline' here — that is the entire point. Only the exact
    // inline blocks hashed below, plus the Supabase SDK from the CDN, run.
    `script-src 'self' ${CDN_ORIGIN} ${hashes.join(' ')}`,
    // 'unsafe-inline' IS allowed for styles. Every page has a large inline
    // <style> block plus many style="" attributes in template strings, and
    // CSP cannot hash a per-element style attribute. The exposure is CSS
    // injection (restyling, at worst some data inference), not code
    // execution, which is a far smaller risk than relaxing script-src.
    `style-src 'self' 'unsafe-inline' ${FONT_CSS_ORIGIN}`,
    `font-src 'self' ${FONT_FILE_ORIGIN}`,
    // The pages use no <img> tags today; 'self' covers the favicon request.
    "img-src 'self' data:",
    // fetch/XHR targets: /api/* on the same origin, Supabase, ipapi.co, and
    // the video Worker.
    `connect-src 'self' ${SUPABASE_ORIGIN} ${GEO_ORIGIN} ${R2_WORKER_ORIGIN}`,
    // course.html's #videoFrame iframe: Bunny for older lectures, the
    // Cloudflare Worker for R2/HLS ones.
    `frame-src ${BUNNY_EMBED_ORIGIN} ${R2_WORKER_ORIGIN}`,
    // No plugins, ever.
    "object-src 'none'",
    // An injected <base> cannot re-point every relative URL on the page.
    "base-uri 'self'",
    // There are no <form> elements at all right now; this keeps it that way
    // for anything cross-origin.
    "form-action 'self'",
    // Nothing embeds these pages. Mirrors the X-Frame-Options: DENY already
    // in vercel.json, for browsers that prefer CSP.
    "frame-ancestors 'none'"
  ].join('; ');
}

function readVercelJson() {
  return JSON.parse(fs.readFileSync(VERCEL_JSON, 'utf8'));
}

function currentCspInVercelJson(cfg) {
  for (const block of cfg.headers || []) {
    for (const h of block.headers || []) {
      if (h.key.toLowerCase() === 'content-security-policy') return h.value;
    }
  }
  return null;
}

function writeVercelJson(csp) {
  const cfg = readVercelJson();
  const block = (cfg.headers || []).find((b) => b.source === '/(.*)');
  if (!block) {
    console.error('vercel.json has no headers block with source "/(.*)" — aborting.');
    process.exit(1);
  }
  const existing = block.headers.find((h) => h.key.toLowerCase() === 'content-security-policy');
  if (existing) existing.value = csp;
  else block.headers.push({ key: 'Content-Security-Policy', value: csp });
  fs.writeFileSync(VERCEL_JSON, JSON.stringify(cfg, null, 2) + '\n');
}

// --- main ----------------------------------------------------------------
const mode = process.argv[2] || '--print';
const { hashes, perFile } = collectHashes();
const csp = buildCsp(hashes);

if (mode === '--print') {
  for (const page of PAGES) {
    console.log(`${page}: ${perFile[page].length} inline script block(s)`);
    perFile[page].forEach((h, i) => console.log(`  [${i}] ${h}`));
  }
  console.log(`\n${hashes.length} unique hash(es) (the two small <head> scripts are identical on every page).`);
  console.log('\nContent-Security-Policy:\n' + csp);
}

const inFile = currentCspInVercelJson(readVercelJson());
if (mode === '--write') {
  writeVercelJson(csp);
  console.log(inFile === csp ? 'vercel.json already up to date.' : 'vercel.json updated.');
} else if (mode === '--check') {
  if (inFile === csp) {
    console.log('OK — vercel.json CSP matches the current inline scripts.');
  } else {
    console.error('STALE — vercel.json CSP does not match the inline scripts.');
    console.error('Run: node scripts/compute-csp-hashes.js --write');
    process.exit(1);
  }
} else if (mode === '--print') {
  console.log('\nvercel.json status: ' + (inFile === csp ? 'up to date' : 'STALE — run with --write'));
}
