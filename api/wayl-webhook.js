// Confirms a Wayl payment and turns the course on.
//
// Wayl calls this (POST) when a payment changes; the app and paid.html call
// it too (GET ?ref=...) when the student comes back. The message itself is
// never trusted: we take only the reference id from it and ask Wayl's API
// directly (GET /links/{referenceId}) whether that link is paid and for the
// right amount. Only then does wayl_complete_payment enroll the student.
// So a forged webhook can't unlock anything, and Wayl's undocumented
// signature scheme doesn't matter.
//
// Env: SUPABASE_SERVICE_ROLE_KEY, WAYL_API_KEY

const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const WAYL_API = 'https://api.thewayl.com/api/v1';
const REF = /^arc_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PAID = new Set(['Complete', 'Delivered']);
const FAILED = new Set(['Cancelled', 'Rejected', 'Returned']);

function findRef(req) {
  const q = req.query || {};
  const b = req.body || {};
  const cands = [q.ref, q.referenceId, b.referenceId, b.reference_id,
    b.data && b.data.referenceId, b.link && b.link.referenceId];
  return cands.find((c) => typeof c === 'string' && REF.test(c)) || null;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST' && req.method !== 'GET') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('wayl-webhook:' + clientIp(req), 60, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests' });
    return;
  }
  const { SUPABASE_SERVICE_ROLE_KEY, WAYL_API_KEY } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY || !WAYL_API_KEY) {
    res.status(503).json({ error: 'payments_not_configured' });
    return;
  }
  const ref = findRef(req);
  if (!ref) {
    res.status(400).json({ error: 'Bad reference' });
    return;
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: pay } = await admin
    .from('wayl_payments')
    .select('reference_id, amount, status, course_slug')
    .eq('reference_id', ref)
    .maybeSingle();
  if (!pay) {
    res.status(404).json({ error: 'Unknown payment' });
    return;
  }
  if (pay.status === 'complete') {
    res.status(200).json({ status: 'paid', courseSlug: pay.course_slug });
    return;
  }

  let link;
  try {
    const r = await fetch(`${WAYL_API}/links/${encodeURIComponent(ref)}`, {
      headers: { 'X-WAYL-AUTHENTICATION': WAYL_API_KEY },
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j?.data) {
      res.status(502).json({ error: 'payment_provider_error' });
      return;
    }
    link = j.data;
  } catch (_) {
    res.status(502).json({ error: 'payment_provider_error' });
    return;
  }

  const total = Math.round(Number(link.total));
  if (PAID.has(link.status) && link.referenceId === ref && total === pay.amount) {
    const { data: result, error } = await admin.rpc('wayl_complete_payment', {
      p_reference: ref,
      p_method: link.paymentMethod || null,
    });
    if (error) {
      console.error('wayl-webhook: complete failed', error);
      res.status(500).json({ error: 'Could not record payment' });
      return;
    }
    res.status(200).json({ status: 'paid', result, courseSlug: pay.course_slug });
    return;
  }
  if (PAID.has(link.status)) {
    // Paid, but not the amount we asked for: never unlock, log for a human.
    console.error('wayl-webhook: amount mismatch', ref, link.total, pay.amount);
    res.status(409).json({ error: 'amount_mismatch' });
    return;
  }
  if (FAILED.has(link.status)) {
    await admin.from('wayl_payments').update({ status: 'failed' })
      .eq('reference_id', ref).eq('status', 'created');
    res.status(200).json({ status: 'failed' });
    return;
  }
  res.status(200).json({ status: 'pending' });
};
