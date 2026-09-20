const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  // Deletion is irreversible, so the rate limit here exists only to blunt a
  // scripted flood of this endpoint, not because a real user needs many
  // attempts.
  if (!allow('delete-account:' + clientIp(req), 5, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    console.error('delete-account: SUPABASE_SERVICE_ROLE_KEY not configured');
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  // Separate client, never touched again, purely to verify the caller's identity.
  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  if (!allow('delete-account:user:' + userId, 3, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  // Fresh privileged client, never given the caller's token — deleting the
  // auth user cascades to every row that references auth.users(id) with
  // "on delete cascade" (profiles, enrollments, lesson_progress, phone OTP
  // state, trusted devices, …).
  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const { error: deleteErr } = await admin.auth.admin.deleteUser(userId);
  if (deleteErr) {
    console.error('delete-account: deleteUser failed', deleteErr);
    res.status(500).json({ error: 'Could not delete account.' });
    return;
  }

  res.status(200).json({ ok: true });
};
