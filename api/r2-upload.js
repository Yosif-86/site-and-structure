// Authorizes a lecture-video upload straight to Cloudflare R2. This function
// never touches the video itself: it checks who is asking, then signs a
// short-lived token the Cloudflare Worker (worker/src/index.js) accepts for
// uploading to exactly one object -- videos/<lectureId>/source.mp4 -- through
// its own R2 binding. So no R2 API keys exist anywhere but Cloudflare.
//
// POST { action, courseId, lectureId } with the caller's Supabase JWT.
//   upload -> { url, token, expires, uid }   teacher (own course) or admin
//   delete -> { url, token, expires, uid }   admin only (rejecting a lecture)
//
// Token = sha256(SECURITY_KEY + '<action>:' + key + uid + expires), the same
// shared secret get-video-url.js signs playback with (R2_SECURITY_KEY).
//
// Env: SUPABASE_SERVICE_ROLE_KEY, R2_SECURITY_KEY, R2_WORKER_BASE_URL

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('r2-upload:' + clientIp(req), 30, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests' });
    return;
  }
  const { SUPABASE_SERVICE_ROLE_KEY, R2_SECURITY_KEY, R2_WORKER_BASE_URL } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY || !R2_SECURITY_KEY || !R2_WORKER_BASE_URL) {
    res.status(500).json({ error: 'Upload not configured' });
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
  const uid = userData.user.id;

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: profile } = await admin
    .from('profiles')
    .select('is_teacher, is_admin')
    .eq('id', uid)
    .maybeSingle();

  const { action, courseId, lectureId } = req.body || {};
  if (!UUID.test(lectureId || '')) {
    res.status(400).json({ error: 'Bad lectureId' });
    return;
  }
  const key = `videos/${lectureId}/source.mp4`;

  if (action === 'delete') {
    if (!profile?.is_admin) {
      res.status(403).json({ error: 'Admins only' });
      return;
    }
  } else if (action === 'upload') {
    if (!profile?.is_teacher && !profile?.is_admin) {
      res.status(403).json({ error: 'Teachers only' });
      return;
    }
    if (!UUID.test(courseId || '')) {
      res.status(400).json({ error: 'Bad courseId' });
      return;
    }
    const { data: course } = await admin
      .from('courses')
      .select('teacher_id')
      .eq('id', courseId)
      .maybeSingle();
    if (!course || (course.teacher_id !== uid && !profile?.is_admin)) {
      res.status(403).json({ error: 'Not your course' });
      return;
    }
    // An existing lecture must be in this course and not live yet: an
    // upload can never overwrite a published video.
    const { data: existing } = await admin
      .from('lectures')
      .select('course_id, r2_path')
      .eq('id', lectureId)
      .maybeSingle();
    if (existing && (existing.course_id !== courseId || existing.r2_path)) {
      res.status(403).json({ error: 'Lecture locked' });
      return;
    }
  } else {
    res.status(400).json({ error: 'Unknown action' });
    return;
  }

  const expires = Math.floor(Date.now() / 1000) + 6 * 3600;
  const token = crypto
    .createHash('sha256')
    .update(R2_SECURITY_KEY + action + ':' + key + uid + expires)
    .digest('hex');
  res.status(200).json({
    url: `${R2_WORKER_BASE_URL.replace(/\/+$/, '')}/${action}/${key}`,
    token,
    expires,
    uid,
  });
};
