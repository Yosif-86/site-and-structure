const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const MAX_ATTEMPTS = 5;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  if (!allow('verify-phone-otp:' + clientIp(req), 15, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    console.error('verify-phone-otp: SUPABASE_SERVICE_ROLE_KEY not configured');
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  const code = typeof req.body?.code === 'string' ? req.body.code.trim() : '';
  if (!/^[0-9]{4,8}$/.test(code)) {
    res.status(400).json({ error: 'err_invalid_code' });
    return;
  }

  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  if (!allow('verify-phone-otp:user:' + userId, 10, 10 * 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const { data: row } = await admin
    .from('phone_otp_codes')
    .select('code_hash, attempts, expires_at')
    .eq('user_id', userId)
    .maybeSingle();

  if (!row) {
    res.status(400).json({ error: 'err_otp_not_requested' });
    return;
  }
  if (new Date(row.expires_at).getTime() < Date.now()) {
    res.status(400).json({ error: 'err_otp_expired' });
    return;
  }
  if (row.attempts >= MAX_ATTEMPTS) {
    res.status(429).json({ error: 'err_otp_too_many_attempts' });
    return;
  }

  const codeHash = crypto.createHash('sha256').update(code).digest('hex');
  // Constant-time compare -- both sides are fixed-length hex hashes, so this
  // never leaks timing info about which prefix bytes matched.
  const match =
    codeHash.length === row.code_hash.length &&
    crypto.timingSafeEqual(Buffer.from(codeHash), Buffer.from(row.code_hash));

  if (!match) {
    await admin.from('phone_otp_codes').update({ attempts: row.attempts + 1 }).eq('user_id', userId);
    res.status(400).json({ error: 'err_otp_incorrect' });
    return;
  }

  await admin.from('profiles').update({ phone_verified: true }).eq('id', userId);
  await admin.from('phone_otp_codes').delete().eq('user_id', userId);

  res.status(200).json({ ok: true });
};
