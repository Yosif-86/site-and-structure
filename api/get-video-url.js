const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';

const BUNNY_LIBRARY_ID = '738703';

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const bunnySecurityKey = process.env.BUNNY_STREAM_SECURITY_KEY;
  const r2SecurityKey = process.env.R2_SECURITY_KEY;
  const r2WorkerBaseUrl = process.env.R2_WORKER_BASE_URL;
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

  const { lectureId, deviceId, sessionToken } = req.body || {};
  if (!lectureId) {
    res.status(400).json({ error: 'Missing lectureId' });
    return;
  }
  if (!deviceId || !sessionToken) {
    res.status(400).json({ error: 'Missing device/session info' });
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

  // Anti-sharing gate: this must hold for every lecture, free or paid — a
  // valid Supabase JWT alone is not enough. Reject if this device was never
  // registered via /api/check-device, or if a different device has since
  // become the account's single active session (kicking this one).
  const { data: device } = await admin
    .from('trusted_devices')
    .select('id')
    .eq('user_id', userId)
    .eq('device_id', deviceId)
    .maybeSingle();
  if (!device) {
    res.status(403).json({ error: 'err_untrusted_device' });
    return;
  }

  const { data: profile } = await admin
    .from('profiles')
    .select('active_session_token')
    .eq('id', userId)
    .maybeSingle();
  if (!profile || profile.active_session_token !== sessionToken) {
    res.status(403).json({ error: 'err_session_kicked' });
    return;
  }

  const { data: lecture, error: lectureErr } = await admin
    .from('lectures')
    .select('id, course_id, bunny_video_id, r2_path, is_free')
    .eq('id', lectureId)
    .maybeSingle();

  if (lectureErr || !lecture || (!lecture.bunny_video_id && !lecture.r2_path)) {
    res.status(404).json({ error: 'Video not available' });
    return;
  }

  if (!lecture.is_free) {
    const { data: course } = await admin
      .from('courses')
      .select('slug')
      .eq('id', lecture.course_id)
      .maybeSingle();

    const { data: enrollment } = await admin
      .from('enrollments')
      .select('status')
      .eq('user_id', userId)
      .eq('course_slug', course?.slug)
      .eq('status', 'active')
      .maybeSingle();

    if (!enrollment) {
      res.status(403).json({ error: 'Not enrolled or access not yet approved' });
      return;
    }
  }

  // New lectures: R2 + HLS via the Cloudflare Worker.
  if (lecture.r2_path) {
    if (!r2SecurityKey || !r2WorkerBaseUrl) {
      res.status(500).json({ error: 'R2 video delivery not configured' });
      return;
    }
    // Token is scoped to the whole lecture folder, not just master.m3u8 — the
    // Worker rewrites playlists so every nested request (variant playlists,
    // segments) reuses this same token, since those are separate HTTP
    // requests the client makes on its own with no way for us to re-sign them.
    //
    // Expiry is generous (covers a full lecture in one sitting — some run
    // several hours) rather than the tight few-minutes window you'd want for
    // a short-lived resource, because video_player/ExoPlayer fetch an HLS VOD
    // playlist once and don't transparently re-fetch mid-stream on token
    // expiry. The real anti-sharing gate is the device/session check above,
    // which runs every time a URL is minted — this expiry just bounds how
    // long a copied URL could be replayed after that check passed.
    const folderPrefix = `/${lecture.r2_path.replace(/^\/+/, '')}`;
    const expires = Math.floor(Date.now() / 1000) + 6 * 3600; // 6 hours
    const token = crypto.createHash('sha256').update(r2SecurityKey + folderPrefix + userId + expires).digest('hex');
    const url = `${r2WorkerBaseUrl.replace(/\/+$/, '')}${folderPrefix}/master.m3u8?token=${token}&expires=${expires}&uid=${encodeURIComponent(userId)}`;
    res.status(200).json({ url, type: 'hls' });
    return;
  }

  // Existing lectures: unchanged Bunny Stream path.
  if (!bunnySecurityKey) {
    res.status(500).json({ error: 'Server not configured' });
    return;
  }
  const videoId = lecture.bunny_video_id;
  const expires = Math.floor(Date.now() / 1000) + 3600; // 1 hour
  const token = crypto.createHash('sha256').update(bunnySecurityKey + videoId + expires).digest('hex');
  const url = `https://iframe.mediadelivery.net/embed/${BUNNY_LIBRARY_ID}/${videoId}?token=${token}&expires=${expires}&playsinline=true`;

  res.status(200).json({ url, type: 'bunny' });
};
