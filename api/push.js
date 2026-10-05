// Sends one in-app notification to the user's phones through Firebase Cloud
// Messaging (lock-screen notification). Called by the database trigger
// trg_push_notification (add-push-notifications.sql) for every new row in
// `notifications`.
//
// POST { notificationId }. No secret needed: the function reads the row
// itself, only ever sends it to that row's own user, and only once
// (pushed_at), so calling it can't send anything to anyone else.
//
// Env: SUPABASE_SERVICE_ROLE_KEY, FIREBASE_SERVICE_ACCOUNT (the service
// account JSON from Firebase > Project settings > Service accounts).

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let cachedToken = null; // { value, expiresAt }

function serviceAccount() {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// OAuth access token for FCM, signed with the service account key (no extra
// libraries). Cached until a minute before it expires.
async function accessToken(sa) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt - 60 > now) return cachedToken.value;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;
  const signature = crypto.createSign('RSA-SHA256').update(unsigned).sign(sa.private_key, 'base64url');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature}`,
    }),
  });
  const body = await res.json();
  if (!res.ok || !body.access_token) throw new Error('token: ' + JSON.stringify(body));
  cachedToken = { value: body.access_token, expiresAt: now + (body.expires_in || 3600) };
  return cachedToken.value;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('push:' + clientIp(req), 300, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests' });
    return;
  }
  const sa = serviceAccount();
  const { SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!sa || !SUPABASE_SERVICE_ROLE_KEY) {
    res.status(500).json({ error: 'Push not configured' });
    return;
  }
  const { notificationId } = req.body || {};
  if (!UUID.test(notificationId || '')) {
    res.status(400).json({ error: 'Bad notificationId' });
    return;
  }
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Claim it: only the first call for a notification sends anything.
  const { data: claimed } = await admin
    .from('notifications')
    .update({ pushed_at: new Date().toISOString() })
    .eq('id', notificationId)
    .is('pushed_at', null)
    .select('id, user_id, type, title, body, data')
    .maybeSingle();
  if (!claimed) {
    res.status(200).json({ ok: true, skipped: true });
    return;
  }

  const { data: tokens } = await admin
    .from('push_tokens')
    .select('token')
    .eq('user_id', claimed.user_id);
  if (!tokens || tokens.length === 0) {
    res.status(200).json({ ok: true, sent: 0 });
    return;
  }

  // Data values must all be strings for FCM.
  const data = { type: String(claimed.type || ''), notification_id: String(claimed.id) };
  for (const [k, v] of Object.entries(claimed.data || {})) {
    if (v !== null && v !== undefined) data[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }

  let sent = 0;
  try {
    const bearer = await accessToken(sa);
    await Promise.all(tokens.map(async ({ token }) => {
      const r = await fetch(
        `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        {
          method: 'POST',
          headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: claimed.title, body: claimed.body || '' },
              data,
              android: {
                priority: 'HIGH',
                notification: {
                  channel_id: 'arc_default',
                  icon: 'ic_stat_arc',
                  color: '#E8622C',
                  sound: 'default',
                },
              },
            },
          }),
        }
      );
      if (r.ok) {
        sent++;
        return;
      }
      const err = await r.text();
      // App uninstalled or token replaced: forget this phone.
      if (r.status === 404 || err.includes('UNREGISTERED') || err.includes('registration token')) {
        await admin.from('push_tokens').delete().eq('token', token);
      } else {
        console.error('push: send failed', r.status, err.slice(0, 300));
      }
    }));
  } catch (e) {
    console.error('push: failed', e);
    res.status(500).json({ error: 'Push failed' });
    return;
  }
  res.status(200).json({ ok: true, sent });
};
