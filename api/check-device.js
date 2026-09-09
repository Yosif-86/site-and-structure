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

  // Fresh privileged client, never given the caller's token, used only for the DB writes below.
  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const { data: existing, error: selectErr } = await admin
    .from('trusted_devices')
    .select('id')
    .eq('user_id', userId)
    .eq('device_id', deviceId)
    .maybeSingle();

  // DB error detail is logged server-side only — the client gets a generic
  // message so a probing client can't learn table/column names or Postgres
  // internals from error text (checklist: no verbose errors / no info leak).
  if (selectErr) {
    console.error('check-device: select failed', selectErr);
    res.status(500).json({ error: 'Could not check device.' });
    return;
  }

  let allowed;
  if (existing) {
    const { error: updateErr } = await admin.from('trusted_devices').update({ last_seen: new Date().toISOString() }).eq('id', existing.id);
    if (updateErr) { console.error('check-device: update failed', updateErr); res.status(500).json({ error: 'Could not check device.' }); return; }
    allowed = true;
  } else {
    const { count, error: countErr } = await admin
      .from('trusted_devices')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId);

    if (countErr) { console.error('check-device: count failed', countErr); res.status(500).json({ error: 'Could not check device.' }); return; }

    if (count >= MAX_DEVICES) {
      allowed = false;
    } else {
      const { error: insertErr } = await admin.from('trusted_devices').insert({
        user_id: userId,
        device_id: deviceId,
        device_label: safeDeviceLabel || null
      });
      if (insertErr) { console.error('check-device: insert failed', insertErr); res.status(500).json({ error: 'Could not check device.' }); return; }
      allowed = true;
    }
  }

  if (!allowed) {
    res.status(200).json({ allowed: false });
    return;
  }

  const sessionToken = require('crypto').randomUUID();
  await admin.from('profiles').upsert({ id: userId, active_session_token: sessionToken });

  res.status(200).json({ allowed: true, sessionToken });
};
