// Starts the automatic multi-quality conversion of an approved lecture:
// asks GitHub to run .github/workflows/convert-lecture.yml for it. Called by
// the app right after the admin approves a lecture; the lecture is already
// live as its MP4, so a failure here only means it stays single-quality.
//
// POST { lectureId } with an admin's Supabase JWT.
// Env: SUPABASE_SERVICE_ROLE_KEY, GITHUB_DISPATCH_TOKEN (fine-grained token,
// repository site-and-structure, permission Actions: read and write).

const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const REPO = 'Yosif-86/site-and-structure';
const WORKFLOW = 'convert-lecture.yml';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('convert-lecture:' + clientIp(req), 20, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests' });
    return;
  }
  const { SUPABASE_SERVICE_ROLE_KEY, GITHUB_DISPATCH_TOKEN } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY || !GITHUB_DISPATCH_TOKEN) {
    res.status(500).json({ error: 'Conversion not configured' });
    return;
  }

  const accessToken = (req.headers.authorization || '').replace('Bearer ', '');
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
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: profile } = await admin
    .from('profiles')
    .select('is_admin')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (!profile?.is_admin) {
    res.status(403).json({ error: 'Admins only' });
    return;
  }

  const { lectureId } = req.body || {};
  if (!UUID.test(lectureId || '')) {
    res.status(400).json({ error: 'Bad lectureId' });
    return;
  }
  // Only lectures that are live as an uploaded MP4 need converting.
  const { data: lecture } = await admin
    .from('lectures')
    .select('r2_path')
    .eq('id', lectureId)
    .maybeSingle();
  if (lecture?.r2_path !== `videos/${lectureId}/source.mp4`) {
    res.status(409).json({ error: 'Nothing to convert' });
    return;
  }

  const gh = await fetch(
    `https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GITHUB_DISPATCH_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'arc-platform',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ref: 'main', inputs: { lecture_id: lectureId } }),
    },
  );
  if (gh.status !== 204) {
    console.error('convert-lecture: GitHub dispatch failed', gh.status, await gh.text());
    res.status(502).json({ error: 'Could not start conversion' });
    return;
  }
  res.status(200).json({ ok: true });
};
