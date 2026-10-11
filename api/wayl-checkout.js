// Starts a Wayl payment for one course. The signed-in student asks for a
// course (and optionally a discount code); the price is worked out by the
// database (wayl_prepare_payment), never taken from the phone. Wayl returns
// a hosted payment page (Zain Cash, Qi Card, FIB...) that the app or website
// opens in the browser.
//
// POST { courseSlug, code? } with the caller's Supabase JWT
//   -> { url, referenceId, amount }
//
// Env: SUPABASE_SERVICE_ROLE_KEY, WAYL_API_KEY,
//      WAYL_ENV ('live' turns on real payments; anything else is test mode),
//      WAYL_WEBHOOK_SECRET (optional; Wayl requires one, we never rely on it
//      because wayl-webhook.js confirms every payment with Wayl directly).

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const WAYL_API = 'https://api.thewayl.com/api/v1';
const API_BASE = 'https://site-and-structure.vercel.app';
const SITE = 'https://arcplatformiq.com';
const SLUG = /^[a-z0-9][a-z0-9-]{0,120}$/i;

const KNOWN_ERRORS = new Set([
  'course_unavailable', 'course_free', 'already_enrolled', 'code_invalid',
]);

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('wayl-checkout:' + clientIp(req), 20, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests' });
    return;
  }
  const { SUPABASE_SERVICE_ROLE_KEY, WAYL_API_KEY } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY || !WAYL_API_KEY) {
    res.status(503).json({ error: 'payments_not_configured' });
    return;
  }
  const env = process.env.WAYL_ENV === 'live' ? 'live' : 'test';

  const accessToken = (req.headers.authorization || '').replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }
  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const uid = userData.user.id;

  const { courseSlug, code } = req.body || {};
  if (typeof courseSlug !== 'string' || !SLUG.test(courseSlug)) {
    res.status(400).json({ error: 'Bad courseSlug' });
    return;
  }
  const cleanCode = typeof code === 'string' ? code.trim().slice(0, 40) : '';

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: priced, error: priceErr } = await admin.rpc('wayl_prepare_payment', {
    p_user: uid,
    p_course_slug: courseSlug,
    p_code: cleanCode || null,
  });
  if (priceErr) {
    const known = [...KNOWN_ERRORS].find((k) => (priceErr.message || '').includes(k));
    if (known) {
      res.status(409).json({ error: known });
      return;
    }
    console.error('wayl-checkout: prepare failed', priceErr);
    res.status(500).json({ error: 'Could not start payment' });
    return;
  }
  const p = Array.isArray(priced) ? priced[0] : priced;
  if (!p || !(p.amount >= 1000)) {
    // Wayl's minimum is 1,000 IQD.
    res.status(409).json({ error: 'amount_too_low' });
    return;
  }

  const referenceId = 'arc_' + crypto.randomUUID();
  const lineItem = [{ label: String(p.course_title || 'Course').slice(0, 255).padEnd(3, ' '), amount: p.list_price, type: 'increase' }];
  if (p.discount_amount > 0) {
    lineItem.push({ label: 'Discount', amount: p.discount_amount, type: 'decrease' });
  }
  const body = {
    env,
    referenceId,
    total: p.amount,
    currency: 'IQD',
    customParameter: courseSlug,
    lineItem,
    webhookUrl: `${API_BASE}/api/wayl-webhook`,
    webhookSecret: process.env.WAYL_WEBHOOK_SECRET ||
      crypto.createHash('sha256').update('arc-wayl:' + WAYL_API_KEY).digest('hex').slice(0, 40),
    redirectionUrl: `${SITE}/paid.html`,
    linkExpiresIn: '1h',
  };

  let link;
  try {
    const r = await fetch(`${WAYL_API}/links`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-WAYL-AUTHENTICATION': WAYL_API_KEY },
      body: JSON.stringify(body),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j?.data?.url) {
      console.error('wayl-checkout: Wayl refused', r.status, j?.message || '');
      res.status(502).json({ error: 'payment_provider_error' });
      return;
    }
    link = j.data;
  } catch (e) {
    console.error('wayl-checkout: Wayl unreachable', e?.message);
    res.status(502).json({ error: 'payment_provider_error' });
    return;
  }

  const { error: insErr } = await admin.from('wayl_payments').insert({
    reference_id: referenceId,
    user_id: uid,
    course_slug: courseSlug,
    list_price: p.list_price,
    discount_amount: p.discount_amount,
    amount: p.amount,
    discount_code_id: p.discount_code_id || null,
    env,
    wayl_link_id: link.id || null,
    wayl_url: link.url,
  });
  if (insErr) {
    console.error('wayl-checkout: could not record payment', insErr);
    res.status(500).json({ error: 'Could not start payment' });
    return;
  }

  res.status(200).json({ url: link.url, referenceId, amount: p.amount, env });
};
