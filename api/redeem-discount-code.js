const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_ATTEMPTS_PER_DAY = 5;

// redeem_discount_code(text, uuid) (add-teacher-role-schema.sql) has no
// built-in throttle of its own -- codes are short, guessable strings, and
// the RPC was reachable directly from the client with unlimited attempts.
// This endpoint is now the only supported path: it caps guesses per user
// before ever calling the RPC.
module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  if (!allow('redeem-code:' + clientIp(req), 20, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  const { code, courseId } = req.body || {};
  if (!code || typeof code !== 'string' || code.length > 64 ||
      !courseId || typeof courseId !== 'string') {
    res.status(400).json({ error: 'Missing code or courseId' });
    return;
  }

  // Scoped to the caller's own session, not service-role -- the RPC reads
  // auth.uid() internally to record who redeemed what, so it must run as
  // the user for that to resolve correctly.
  const asUser = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { autoRefreshToken: false, persistSession: false }
  });
  const { data: userData, error: userErr } = await asUser.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  // The actual security control asked for: 5 discount-code attempts per
  // user per day, so a script can't brute-force a code by hammering guesses.
  if (!allow('redeem-code:user:' + userId, MAX_ATTEMPTS_PER_DAY, DAY_MS)) {
    res.status(429).json({ error: 'Too many attempts today. Try again tomorrow.' });
    return;
  }

  const { data, error } = await asUser.rpc('redeem_discount_code', {
    p_code: code.trim().toUpperCase(),
    p_course_id: courseId
  });
  if (error) {
    // The DB-level cap (add-discount-code-rate-limit.sql) raises this exact
    // message via errcode P0001 when the RPC is called directly, bypassing
    // this endpoint's own (weaker, in-memory) limiter above -- surface it
    // as-is instead of the generic failure.
    if (error.code === 'P0001') {
      res.status(429).json({ error: error.message });
      return;
    }
    console.error('redeem-discount-code: rpc failed', error);
    res.status(500).json({ error: 'Could not apply code.' });
    return;
  }
  if (!Array.isArray(data) || data.length === 0) {
    res.status(200).json({ ok: false });
    return;
  }
  res.status(200).json({
    ok: true,
    discountType: data[0].discount_type,
    discountValue: data[0].discount_value
  });
};
