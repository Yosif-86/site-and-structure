// Course files, kept in their original format -- one endpoint, two callers:
//
//  1. The teacher app, right after uploading an original to
//     course-files/raw/<courseId>/<fileId>.<ext> and inserting the
//     course_files row:   POST { action: 'start', fileId }  (teacher JWT)
//     -> PDF / photo: asks GitHub to run process-course-file.yml (stamps
//        the Arc logo, same format). Word/Excel/PowerPoint/CAD: published
//        right here, untouched.
//
//  2. That workflow (header x-convert-key, the same CONVERT_KEY secret the
//     lecture conversion uses; the database keeps only its sha256):
//       POST { action: 'job', fileId }            -> links to read the
//            original and write the processed copy (never put in workflow
//            inputs: the repository is public)
//       POST { action: 'finish', fileId, ok }     -> marks the file ready
//            (or failed) and deletes the original.
//
// Env: SUPABASE_SERVICE_ROLE_KEY, GITHUB_DISPATCH_TOKEN.

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const { allow, clientIp } = require('./_rate-limit');

const SUPABASE_URL = 'https://qdarzhzttjpkgfihupgp.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q';
const REPO = 'Yosif-86/site-and-structure';
const WORKFLOW = 'process-course-file.yml';
const BUCKET = 'course-files';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }
  if (!allow('course-file:' + clientIp(req), 60, 60 * 1000)) {
    res.status(429).json({ error: 'Too many requests, try again shortly.' });
    return;
  }
  const { SUPABASE_SERVICE_ROLE_KEY, GITHUB_DISPATCH_TOKEN } = process.env;
  if (!SUPABASE_SERVICE_ROLE_KEY) {
    res.status(500).json({ error: 'Not configured' });
    return;
  }
  const { action, fileId, ok } = req.body || {};
  if (!UUID.test(fileId || '')) {
    res.status(400).json({ error: 'Bad fileId' });
    return;
  }
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: file } = await admin
    .from('course_files')
    .select('id, course_id, kind, raw_path, view_path, status, courses(teacher_id)')
    .eq('id', fileId)
    .maybeSingle();
  if (!file) {
    res.status(404).json({ error: 'File not found' });
    return;
  }
  // Same name and format as uploaded, only moved to the view folder.
  const ext = ((file.raw_path || file.view_path || '').split('.').pop() || '')
    .toLowerCase();
  const viewType =
    file.kind === 'image' ? 'image' : file.kind === 'pdf' ? 'pdf' : 'file';
  const viewPath = `view/${file.course_id}/${file.id}.${ext}`;

  // ---------- teacher: start processing ----------
  if (action === 'start') {
    const accessToken = (req.headers.authorization || '').replace('Bearer ', '');
    const verifier = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
    const { data: userData, error: userErr } = await verifier.auth.getUser(accessToken);
    if (userErr || !userData?.user) {
      res.status(401).json({ error: 'Invalid session' });
      return;
    }
    const uid = userData.user.id;
    let allowed = file.courses?.teacher_id === uid;
    if (!allowed) {
      const { data: prof } = await admin
        .from('profiles').select('is_admin').eq('id', uid).maybeSingle();
      allowed = prof?.is_admin === true;
    }
    if (!allowed) {
      res.status(403).json({ error: 'Not your course' });
      return;
    }
    if (file.status !== 'processing' || !file.raw_path) {
      res.status(409).json({ error: 'Nothing to process' });
      return;
    }
    // Word/Excel/PowerPoint/CAD: nothing to stamp, publish the original.
    if (file.kind === 'office' || file.kind === 'cad') {
      const { error: moveErr } = await admin.storage
        .from(BUCKET).move(file.raw_path, viewPath);
      const { error: finErr } = moveErr ? { error: null } : await admin.rpc(
        'finish_course_file', {
          p_file_id: file.id, p_view_path: viewPath,
          p_view_type: viewType, p_ok: true,
        });
      if (moveErr || finErr) {
        console.error('course-file: publish failed', moveErr, finErr);
        res.status(500).json({ error: 'Could not publish file' });
        return;
      }
      res.status(200).json({ ok: true, published: true });
      return;
    }
    if (!GITHUB_DISPATCH_TOKEN) {
      res.status(500).json({ error: 'Processing not configured' });
      return;
    }
    const gh = await fetch(
      `https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${GITHUB_DISPATCH_TOKEN}`,
          Accept: 'application/vnd.github+json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ref: 'main', inputs: { file_id: fileId } }),
      }
    );
    if (!gh.ok) {
      console.error('course-file: dispatch failed', gh.status, await gh.text());
      res.status(502).json({ error: 'Could not start processing' });
      return;
    }
    res.status(200).json({ ok: true });
    return;
  }

  // ---------- workflow: key check ----------
  const key = req.headers['x-convert-key'] || '';
  const hash = crypto.createHash('sha256').update(String(key)).digest('hex');
  const { data: secret } = await admin
    .from('app_secrets').select('value_sha256').eq('name', 'convert_key').maybeSingle();
  if (!key || !secret || secret.value_sha256 !== hash) {
    res.status(401).json({ error: 'Not authorized' });
    return;
  }


  if (action === 'job') {
    if (!file.raw_path) {
      res.status(409).json({ error: 'No original' });
      return;
    }
    const { data: src, error: srcErr } = await admin.storage
      .from(BUCKET).createSignedUrl(file.raw_path, 2 * 60 * 60);
    const { data: dst, error: dstErr } = await admin.storage
      .from(BUCKET).createSignedUploadUrl(viewPath, { upsert: true });
    if (srcErr || dstErr || !src || !dst) {
      console.error('course-file: signing failed', srcErr, dstErr);
      res.status(500).json({ error: 'Could not sign' });
      return;
    }
    res.status(200).json({
      kind: file.kind,
      ext,
      srcUrl: src.signedUrl,
      uploadUrl: dst.signedUrl,
      viewType,
    });
    return;
  }

  if (action === 'finish') {
    const success = ok === true;
    const { error } = await admin.rpc('finish_course_file', {
      p_file_id: file.id,
      p_view_path: viewPath,
      p_view_type: viewType,
      p_ok: success,
    });
    if (error) {
      console.error('course-file: finish failed', error);
      res.status(500).json({ error: 'Could not finish' });
      return;
    }
    if (success && file.raw_path) {
      await admin.storage.from(BUCKET).remove([file.raw_path]);
    }
    res.status(200).json({ ok: true });
    return;
  }

  res.status(400).json({ error: 'Unknown action' });
};
