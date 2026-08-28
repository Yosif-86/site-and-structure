const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

const BUNNY_LIBRARY_ID = '738703';

// Maps a course slug to its Bunny Stream video GUID. Add more as real course videos go up.
const COURSE_VIDEOS = {
  'grad-project': '265aa2e4-bbf1-4aea-b1ed-7659da9524a9'
};

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const securityKey = process.env.BUNNY_STREAM_SECURITY_KEY;
  if (!serviceRoleKey || !securityKey) {
    res.status(500).json({ error: 'Server not configured' });
    return;
  }

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.replace('Bearer ', '');
  if (!accessToken) {
    res.status(401).json({ error: 'Missing access token' });
    return;
  }

  const { courseSlug } = req.body || {};
  const videoId = COURSE_VIDEOS[courseSlug];
  if (!videoId) {
    res.status(404).json({ error: 'No video for this course yet' });
    return;
  }

  const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
  const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
  if (userErr || !userData?.user) {
    res.status(401).json({ error: 'Invalid session' });
    return;
  }
  const userId = userData.user.id;

  const admin = createClient(SUPABASE_URL, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  const { data: enrollment, error: enrollErr } = await admin
    .from('enrollments')
    .select('status')
    .eq('user_id', userId)
    .eq('course_slug', courseSlug)
    .eq('status', 'active')
    .maybeSingle();

  if (enrollErr || !enrollment) {
    res.status(403).json({ error: 'Not enrolled or access not yet approved' });
    return;
  }

  const expires = Math.floor(Date.now() / 1000) + 3600; // 1 hour
  const token = crypto.createHash('sha256').update(securityKey + videoId + expires).digest('hex');
  const url = `https://iframe.mediadelivery.net/embed/${BUNNY_LIBRARY_ID}/${videoId}?token=${token}&expires=${expires}&playsinline=true`;

  res.status(200).json({ url });
};
