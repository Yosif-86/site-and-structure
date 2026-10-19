// Apple In-App Purchase for courses (iPhone). Not its own function (the
// Vercel plan allows 12 and all are used): api/wayl-checkout.js hands
// POST { provider: 'apple', courseSlug, jws } here.
//
// The app buys one consumable "price level" product for the course
// (PRODUCTS below, same table in mobile_app/lib/services/apple_iap.dart)
// with appAccountToken = the student's user id, then sends StoreKit 2's
// signed transaction (JWS). We check Apple's signature chain against the
// Apple Root CA G3 certificate, then the bundle, product, account and
// that the transaction was not refunded, and only then turn the course on
// (apple_complete_purchase). Sandbox transactions are accepted too:
// TestFlight and Apple's App Review always buy in the sandbox.

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const BUNDLE_ID = 'com.arcplatformiq.app';

// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
// SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
const APPLE_ROOT_G3 = new crypto.X509Certificate(`-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`);

// Price levels in US dollars (Apple's price points), lowest first. A
// course gets the smallest level at or above its IQD price converted at
// IQD_PER_USD plus APPLE_MARKUP (Apple keeps 15%). Product ids never
// change once created in App Store Connect.
const IQD_PER_USD = 1520;
const APPLE_MARKUP = 1.15;
const PRODUCTS = [
  ['com.arcplatformiq.app.course.t01', 4.99],
  ['com.arcplatformiq.app.course.t02', 9.99],
  ['com.arcplatformiq.app.course.t03', 14.99],
  ['com.arcplatformiq.app.course.t04', 19.99],
  ['com.arcplatformiq.app.course.t05', 29.99],
  ['com.arcplatformiq.app.course.t06', 39.99],
  ['com.arcplatformiq.app.course.t07', 49.99],
  ['com.arcplatformiq.app.course.t08', 59.99],
  ['com.arcplatformiq.app.course.t09', 79.99],
];

function productForIqd(iqd) {
  const usd = (iqd / IQD_PER_USD) * APPLE_MARKUP;
  const hit = PRODUCTS.find(([, price]) => price >= usd);
  return hit ? hit[0] : null; // above the top level: not sold through Apple
}

function b64url(s) {
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

// Returns the decoded payload of a StoreKit 2 signed transaction, or
// throws. Checks: ES256, a 3-certificate chain ending at Apple Root CA G3,
// each certificate signed by the next, and the JWS signature itself.
function verifyAppleJws(jws) {
  const parts = String(jws || '').split('.');
  if (parts.length !== 3) throw new Error('bad_jws');
  const header = JSON.parse(b64url(parts[0]).toString('utf8'));
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) {
    throw new Error('bad_jws_header');
  }
  const [leaf, intermediate, root] = header.x5c.map(
    (c) => new crypto.X509Certificate(Buffer.from(c, 'base64')));
  if (!root.raw.equals(APPLE_ROOT_G3.raw)) throw new Error('not_apple_root');
  if (!intermediate.verify(root.publicKey) || !leaf.verify(intermediate.publicKey)) {
    throw new Error('bad_chain');
  }
  if (!intermediate.checkIssued(root) || !leaf.checkIssued(intermediate)) {
    throw new Error('bad_chain');
  }
  const ok = crypto.verify(
    'sha256',
    Buffer.from(parts[0] + '.' + parts[1]),
    { key: leaf.publicKey, dsaEncoding: 'ieee-p1363' },
    b64url(parts[2]));
  if (!ok) throw new Error('bad_signature');
  return JSON.parse(b64url(parts[1]).toString('utf8'));
}

const SLUG = /^[\p{L}\p{N}][\p{L}\p{N}-]{0,120}$/u;
const KNOWN = new Set(['course_unavailable', 'course_free']);

async function handleApplePurchase(req, res, accessToken) {
  const { SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY) {
    res.status(503).json({ error: 'payments_not_configured' });
    return;
  }
  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const uid = userData.user.id;

  const { courseSlug, jws } = req.body || {};
  if (typeof courseSlug !== 'string' || !SLUG.test(courseSlug) ||
      typeof jws !== 'string' || jws.length > 20000) {
    res.status(400).json({ error: 'Bad request' });
    return;
  }

  let tx;
  try {
    tx = verifyAppleJws(jws);
  } catch (e) {
    console.error('apple-iap: rejected transaction', e?.message);
    res.status(400).json({ error: 'invalid_transaction' });
    return;
  }
  if (tx.bundleId !== BUNDLE_ID || tx.type !== 'Consumable' || tx.revocationDate) {
    res.status(400).json({ error: 'invalid_transaction' });
    return;
  }
  // Bought from this account (the app sets appAccountToken = user id).
  if (String(tx.appAccountToken || '').toLowerCase() !== uid.toLowerCase()) {
    res.status(403).json({ error: 'wrong_account' });
    return;
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: prep, error: prepErr } = await admin.rpc('apple_prepare_purchase', {
    p_user: uid, p_course_slug: courseSlug,
  });
  if (prepErr) {
    const known = [...KNOWN].find((k) => (prepErr.message || '').includes(k));
    res.status(known ? 409 : 500).json({ error: known || 'Could not check course' });
    return;
  }
  const course = Array.isArray(prep) ? prep[0] : prep;
  // The product must be this course's price level, so a cheap product
  // can never unlock an expensive course.
  if (tx.productId !== productForIqd(course?.list_price || 0)) {
    console.error('apple-iap: product does not match course price', tx.transactionId, tx.productId, courseSlug);
    res.status(409).json({ error: 'wrong_product' });
    return;
  }

  const { data: result, error: doneErr } = await admin.rpc('apple_complete_purchase', {
    p_user: uid,
    p_course_slug: courseSlug,
    p_transaction_id: String(tx.transactionId),
    p_original_transaction_id: tx.originalTransactionId ? String(tx.originalTransactionId) : null,
    p_product_id: tx.productId,
    p_environment: tx.environment,
    p_storefront: tx.storefront || null,
    p_price_milli: Number.isFinite(tx.price) ? tx.price : null,
    p_currency: tx.currency || null,
    p_purchased_at: tx.purchaseDate ? new Date(tx.purchaseDate).toISOString() : null,
  });
  if (doneErr) {
    console.error('apple-iap: could not record', doneErr);
    res.status(500).json({ error: 'Could not record purchase' });
    return;
  }
  res.status(200).json({ status: result, environment: tx.environment });
}

module.exports = { handleApplePurchase, verifyAppleJws, productForIqd, PRODUCTS };
