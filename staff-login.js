// Staff sign-in for admin.html / teacher.html. The landing page replaced the
// old home page that held the only website login, so these dashboards had
// no way in. External file (script-src 'self'), so no CSP hash needed.
//
// Deliberately does NOT claim a device slot via /api/check-device: accounts
// are capped at one device, and admins/teachers also use the app, so
// claiming here would either be refused or kick the phone. The device cap
// protects course videos from account sharing; these pages only manage the
// platform, and non-staff are signed straight back out below.
(function(){
  const sb = supabase.createClient(
    'https://qdarzhzttjpkgfihupgp.supabase.co',
    'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q'
  );

  // Only these destinations, never a URL taken from the query string.
  const PAGES = { admin: 'admin.html', teacher: 'teacher.html' };
  const wanted = new URLSearchParams(location.search).get('next');

  const form = document.getElementById('loginForm');
  const emailEl = document.getElementById('email');
  const passEl = document.getElementById('password');
  const msg = document.getElementById('msg');
  const btn = document.getElementById('submitBtn');

  function show(text, ok){
    msg.textContent = text || '';
    msg.className = 'msg' + (text ? (ok ? ' ok' : ' err') : '');
  }

  function destination(prof){
    if(wanted === 'admin' && prof.is_admin) return PAGES.admin;
    if(wanted === 'teacher' && prof.is_teacher) return PAGES.teacher;
    if(prof.is_admin) return PAGES.admin;
    if(prof.is_teacher) return PAGES.teacher;
    return null;
  }

  async function staffProfile(userId){
    const { data } = await sb.from('profiles')
      .select('is_admin, is_teacher').eq('id', userId).maybeSingle();
    return data || {};
  }

  async function logLoginEvent(userId, email){
    let geo = {};
    try{
      const res = await fetch('https://ipapi.co/json/', { signal: AbortSignal.timeout(5000) });
      geo = await res.json();
    }catch(e){ /* log without location */ }
    try{
      await sb.from('login_events').insert({
        user_id: userId,
        email: email,
        user_agent: ('Staff web: ' + navigator.userAgent).slice(0, 300),
        ip: geo.ip || null,
        city: geo.city || null,
        country: geo.country_name || null,
        lat: geo.latitude != null ? geo.latitude : null,
        lon: geo.longitude != null ? geo.longitude : null
      });
    }catch(e){}
  }

  // Already signed in as staff: go straight through.
  (async () => {
    const { data: { session } } = await sb.auth.getSession();
    if(!session) return;
    // A password-only session (from the buying page) does not skip the code.
    let viaCode = false;
    try{
      const b = session.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      const amr = JSON.parse(atob(b)).amr;
      viaCode = Array.isArray(amr) && amr.some((a) => a && (a.method === 'otp' || a.method === 'magiclink'));
    }catch(e){}
    if(!viaCode){
      // Back from a provider redirect (Apple): same rule as the password,
      // sign out and ask for the emailed code. Only when we started it.
      if(new URLSearchParams(location.search).get('oauth') === '1'){
        const email = session.user.email;
        const dest0 = destination(await staffProfile(session.user.id));
        await sb.auth.signOut();
        history.replaceState(null, '', location.pathname + (wanted ? '?next=' + encodeURIComponent(wanted) : ''));
        if(!dest0){ show('هذا الحساب لا يملك صلاحية الدخول. استخدم التطبيق.'); return; }
        emailEl.value = email || '';
        if(await sendCode(email)) showCodeStep(email);
        return;
      }
      await sb.auth.signOut();
      return;
    }
    const dest = destination(await staffProfile(session.user.id));
    if(dest) location.replace(dest);
  })();

  // Second step: after the password, a 6-digit code is emailed and must be
  // typed in (same rule as the app for teacher/admin accounts).
  const codeEl = document.getElementById('code');
  const codeField = document.getElementById('codeField');
  const passField = document.getElementById('passwordField');
  const resendBtn = document.getElementById('resendBtn');
  let codeEmail = null;
  let cooldownUntil = 0;

  async function sendCode(email){
    const { error } = await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
    if(error){
      show(error.status === 429 ? 'انتظر دقيقة قبل طلب رمز جديد.' : 'تعذر إرسال الرمز، حاول مرة أخرى.');
      return false;
    }
    cooldownUntil = Date.now() + 60000;
    return true;
  }

  function showCodeStep(email){
    codeEmail = email;
    passField.hidden = true;
    codeField.hidden = false;
    resendBtn.hidden = false;
    emailEl.readOnly = true;
    btn.textContent = 'تأكيد الرمز';
    codeEl.value = '';
    codeEl.focus();
    show('أرسلنا رمزًا من 6 أرقام إلى بريدك. لم يصلك؟ تحقق من مجلد Spam.', true);
  }

  async function verifyCode(){
    const token = codeEl.value.replace(/\s/g, '');
    if(!/^\d{6}$/.test(token)){ show('أدخل الرمز المكوّن من 6 أرقام.'); return; }
    const { data, error } = await sb.auth.verifyOtp({ email: codeEmail, token, type: 'email' });
    if(error || !data.session){
      show(/expired/i.test(error?.message || '') ? 'انتهت صلاحية الرمز، اطلب رمزًا جديدًا.' : 'رمز التحقق غير صحيح.');
      return;
    }
    const dest = destination(await staffProfile(data.user.id));
    if(!dest){
      await sb.auth.signOut();
      show('هذا الحساب لا يملك صلاحية الدخول. استخدم التطبيق.');
      return;
    }
    await logLoginEvent(data.user.id, data.user.email);
    location.replace(dest);
  }

  resendBtn.addEventListener('click', async () => {
    if(!codeEmail) return;
    const wait = Math.ceil((cooldownUntil - Date.now()) / 1000);
    if(wait > 0){ show('يمكنك طلب رمز جديد بعد ' + wait + ' ثانية.'); return; }
    if(await sendCode(codeEmail)) show('أرسلنا رمزًا جديدًا.', true);
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    btn.disabled = true;
    show('');
    try{
      if(codeEmail){ await verifyCode(); return; }
      const email = emailEl.value.trim();
      const password = passEl.value;
      if(!email || !password){ show('أدخل بريدك الإلكتروني وكلمة المرور.'); return; }
      const { data, error } = await sb.auth.signInWithPassword({ email, password });
      if(error){ show('البريد الإلكتروني أو كلمة المرور غير صحيحة.'); return; }
      const dest = destination(await staffProfile(data.user.id));
      // Password alone never opens the dashboards: sign out, then email a code.
      await sb.auth.signOut();
      if(!dest){
        show('هذا الحساب لا يملك صلاحية الدخول. استخدم التطبيق.');
        return;
      }
      if(await sendCode(email)) showCodeStep(email);
    }finally{
      btn.disabled = false;
    }
  });

  // ---- Google: the same popup the buying page uses. A teacher or admin still
  // gets the emailed code afterwards, exactly like after the password. ----
  const GOOGLE_WEB_CLIENT = '982425355302-nn9u5ksh0jhmv44cd8vvv049bbc69ad0.apps.googleusercontent.com';
  const hex = (buf) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  async function afterProviderSignIn(user){
    const dest = destination(await staffProfile(user.id));
    const email = user.email;
    // The provider session never opens the dashboard on its own.
    await sb.auth.signOut();
    if(!dest){ show('هذا الحساب لا يملك صلاحية الدخول. استخدم التطبيق.'); return; }
    emailEl.value = email || '';
    if(await sendCode(email)) showCodeStep(email);
  }
  (function setupGoogle(){
    const holder = document.getElementById('gisBtn');
    if(!holder || !window.crypto || !crypto.subtle) return;
    const raw = hex(crypto.getRandomValues(new Uint8Array(16)));
    const s = document.createElement('script');
    s.src = 'https://accounts.google.com/gsi/client';
    s.async = true;
    s.onload = async () => {
      // Google puts sha256(nonce) in the token; Supabase checks it against raw.
      const hash = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw)));
      google.accounts.id.initialize({
        client_id: GOOGLE_WEB_CLIENT, nonce: hash, ux_mode: 'popup', context: 'signin',
        callback: async (resp) => {
          show('جارٍ تسجيل الدخول…');
          const { data, error } = await sb.auth.signInWithIdToken({ provider: 'google', token: resp.credential, nonce: raw });
          if(error || !data.user){ show('تعذّر تسجيل الدخول بجوجل. حاول مرة أخرى.'); return; }
          await afterProviderSignIn(data.user);
        }
      });
      google.accounts.id.renderButton(holder, {
        type: 'standard', theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'filled_black' : 'outline',
        size: 'large', shape: 'pill', text: 'continue_with', locale: 'ar', width: Math.min(holder.clientWidth || 360, 400)
      });
    };
    document.head.appendChild(s);
  })();

  // ---- Apple: needs the Services ID and key set up in Apple Developer and
  // Supabase first (see the note in the handoff). Off until then. ----
  const APPLE_WEB_ENABLED = false;
  const appleBtn = document.getElementById('appleBtn');
  if(appleBtn && APPLE_WEB_ENABLED){
    appleBtn.hidden = false;
    appleBtn.addEventListener('click', () => {
      sb.auth.signInWithOAuth({ provider: 'apple', options: {
        redirectTo: location.origin + '/login.html?oauth=1' + (wanted ? '&next=' + encodeURIComponent(wanted) : '')
      } });
    });
  }

  document.getElementById('forgotBtn').addEventListener('click', async () => {
    const email = emailEl.value.trim();
    if(!email){ show('أدخل بريدك الإلكتروني أولاً.'); emailEl.focus(); return; }
    const { error } = await sb.auth.resetPasswordForEmail(email, {
      redirectTo: location.origin + '/reset-password.html'
    });
    // Same message either way, so this can't be used to probe which
    // emails have accounts.
    if(error && error.status === 429){ show('محاولات كثيرة، حاول بعد قليل.'); return; }
    show('إذا كان البريد مسجّلاً، سيصلك رابط إعادة التعيين.', true);
  });
})();
