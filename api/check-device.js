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

  const { data: existing } = await admin
    .from('trusted_devices')
    .select('id')
    .eq('user_id', userId)
    .eq('device_id', deviceId)
    .maybeSingle();

  let allowed;
  if (existing) {
    await admin.from('trusted_devices').update({ last_seen: new Date().toISOString() }).eq('id', existing.id);
    allowed = true;
  } else {
    const { count } = await admin
      .from('trusted_devices')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId);

    if (count >= MAX_DEVICES) {
      allowed = false;
    } else {
      await admin.from('trusted_devices').insert({
        user_id: userId,
        device_id: deviceId,
        device_label: deviceLabel || null
      });
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
