const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const OTPIQ_URL = 'https://api.otpiq.com/api/sms';
const CODE_TTL_MS = 5 * 60 * 1000;

// Iraqi numbers arrive as 07XXXXXXXXX (local) or already-prefixed 9647...;
// OTPIQ wants digits only, no leading +, country code included.
function normalizePhone(raw) {
  let digits = String(raw || '').replace(/[^0-9]/g, '');
  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('0')) digits = '964' + digits.slice(1);
  if (!digits.startsWith('964')) digits = '964' + digits;
  return digits;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  // OTPIQ itself caps at 10 requests / 10 min per phone number, but that's
  // their limit to enforce after we've already spent a request forming the
  // call -- this is the cheap gate that stops a script from getting that far.
  if (!allow('send-phone-otp:' + clientIp(req), 8, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const otpiqApiKey = process.env.OTPIQ_API_KEY;
  if (!serviceRoleKey || !otpiqApiKey) {
    console.error('send-phone-otp: server not configured');
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
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
  const userId = userData.user.id;

  if (!allow('send-phone-otp:user:' + userId, 5, 10 * 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }

  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  // The client may pass a corrected phone (they mistyped at signup); fall
  // back to the one already on file otherwise.
  let phone = typeof req.body?.phone === 'string' ? req.body.phone.trim() : '';
  if (!phone) {
    const { data: profile } = await admin.from('profiles').select('phone').eq('id', userId).maybeSingle();
    phone = profile?.phone || '';
  }
  if (!phone) {
    res.status(400).json({ error: 'Missing phone number' });
    return;
  }
  const normalized = normalizePhone(phone);
  if (!/^[0-9]{10,15}$/.test(normalized)) {
    res.status(400).json({ error: 'err_invalid_phone' });
    return;
  }

  const code = String(Math.floor(100000 + Math.random() * 900000));
  const codeHash = crypto.createHash('sha256').update(code).digest('hex');

  const { error: upsertErr } = await admin.from('phone_otp_codes').upsert({
    user_id: userId,
    phone: normalized,
    code_hash: codeHash,
    attempts: 0,
    expires_at: new Date(Date.now() + CODE_TTL_MS).toISOString()
  });
  if (upsertErr) {
    console.error('send-phone-otp: upsert failed', upsertErr);
    res.status(500).json({ error: 'Could not start verification.' });
    return;
  }

  try {
    const otpiqRes = await fetch(OTPIQ_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${otpiqApiKey}`
      },
      body: JSON.stringify({
        phoneNumber: normalized,
        smsType: 'verification',
        verificationCode: code,
        // WhatsApp first, falling back to plain SMS only if WhatsApp
        // delivery isn't possible for that number.
        provider: 'whatsapp-sms'
      })
    });
    if (!otpiqRes.ok) {
      const detail = await otpiqRes.json().catch(() => ({}));
      console.error('send-phone-otp: OTPIQ error', otpiqRes.status, detail);
      res.status(502).json({ error: 'err_otp_send_failed' });
      return;
    }
  } catch (e) {
    console.error('send-phone-otp: OTPIQ request failed', e);
    res.status(502).json({ error: 'err_otp_send_failed' });
    return;
  }

  res.status(200).json({ ok: true });
};
