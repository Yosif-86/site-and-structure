const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const MAX_DEVICES = 2;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  // Best-effort abuse brake: this endpoint mints/claims a device slot, so an
  // unthrottled script could burn through an account's device cap or hammer
  // the DB. See _rate-limit.js for what this does and does not guarantee.
  if (!allow('check-device:' + clientIp(req), 20, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    console.error('check-device: SUPABASE_SERVICE_ROLE_KEY not configured');
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  const { deviceId, deviceLabel } = req.body || {};
  if (!deviceId || typeof deviceId !== 'string' || deviceId.length > 200) {
    res.status(400).json({ error: 'Missing deviceId' });
    return;
  }
  // deviceLabel is free text from the client (navigator.userAgent) — cap its
  // length so it can't be used to stuff an oversized row; it's rendered
  // HTML-escaped in admin.html regardless.
  const safeDeviceLabel = typeof deviceLabel === 'string' ? deviceLabel.slice(0, 300) : null;

  // Separate client, never touched again, purely to verify the caller's identity.
  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  // Second, stricter gate now that we know who's calling — scoped per-user
  // so one account's traffic can never throttle another account sharing the
  // same IP (e.g. two students behind the same school/office network). The
  // IP-based check above stays as the cheap first gate that protects the
  // auth.getUser() call itself from an unauthenticated flood.
  if (!allow('check-device:user:' + userId, 20, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  // Fresh privileged client, never given the caller's token, used only for the DB writes below.
  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  // claim_device_slot (security-hardening-atomic-device-claim.sql) does the
  // existing-device lookup, the device-count check, and the insert/update
  // inside one plpgsql function serialized by a per-user advisory lock —
  // replaces a check-then-insert that raced under concurrent requests from
  // the same account (both could pass the count check before either insert
  // landed, letting the account exceed MAX_DEVICES).
  const { data: allowed, error: claimErr } = await admin.rpc('claim_device_slot', {
    p_user_id: userId,
    p_device_id: deviceId,
    p_device_label: safeDeviceLabel || null,
    p_max_devices: MAX_DEVICES
  });

  // DB error detail is logged server-side only — the client gets a generic
  // message so a probing client can't learn table/column names or Postgres
  // internals from error text (checklist: no verbose errors / no info leak).
  if (claimErr) {
    console.error('check-device: claim_device_slot failed', claimErr);
    res.status(500).json({ error: 'Could not check device.' });
    return;
  }

  if (!allowed) {
    res.status(200).json({ allowed: false });
    return;
  }

  const sessionToken = require('crypto').randomUUID();
  await admin.from('profiles').upsert({ id: userId, active_session_token: sessionToken });

  res.status(200).json({ allowed: true, sessionToken });
};
