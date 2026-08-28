const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const MAX_DEVICES = 2;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  if (req.query.debug === '1') {
    res.status(200).json({
      keyLength: serviceRoleKey.length,
      keyPrefix: serviceRoleKey.slice(0, 12),
      keySuffix: serviceRoleKey.slice(-4),
      hasWhitespace: /\s/.test(serviceRoleKey)
    });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  const { deviceId, deviceLabel } = req.body || {};
  if (!deviceId) {
    res.status(400).json({ error: 'Missing deviceId' });
    return;
  }

  const admin = createClient(SUPABASE_URL, serviceRoleKey);

  const { data: userData, error: userErr } = await admin.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  const { data: existing, error: selectErr } = await admin
    .from('trusted_devices')
    .select('id')
    .eq('user_id', userId)
    .eq('device_id', deviceId)
    .maybeSingle();

  if (selectErr) {
    res.status(500).json({ error: 'select failed: ' + selectErr.message });
    return;
  }

  let allowed;
  if (existing) {
    const { error: updateErr } = await admin.from('trusted_devices').update({ last_seen: new Date().toISOString() }).eq('id', existing.id);
    if (updateErr) { res.status(500).json({ error: 'update failed: ' + updateErr.message }); return; }
    allowed = true;
  } else {
    const { count, error: countErr } = await admin
      .from('trusted_devices')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId);

    if (countErr) { res.status(500).json({ error: 'count failed: ' + countErr.message }); return; }

    if (count >= MAX_DEVICES) {
      allowed = false;
    } else {
      const { error: insertErr } = await admin.from('trusted_devices').insert({
        user_id: userId,
        device_id: deviceId,
        device_label: deviceLabel || null
      });
      if (insertErr) { res.status(500).json({ error: 'insert failed: ' + insertErr.message }); return; }
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
