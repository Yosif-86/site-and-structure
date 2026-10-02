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
    const dest = destination(await staffProfile(session.user.id));
    if(dest) location.replace(dest);
  })();

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = emailEl.value.trim();
    const password = passEl.value;
    if(!email || !password){ show('أدخل بريدك الإلكتروني وكلمة المرور.'); return; }
    btn.disabled = true;
    show('');
    try{
      const { data, error } = await sb.auth.signInWithPassword({ email, password });
      if(error){ show('البريد الإلكتروني أو كلمة المرور غير صحيحة.'); return; }
      const dest = destination(await staffProfile(data.user.id));
      if(!dest){
        await sb.auth.signOut();
        show('هذه الصفحة للإدارة والمدرّسين فقط. سجّل الدخول من التطبيق.');
        return;
      }
      await logLoginEvent(data.user.id, data.user.email);
      location.replace(dest);
    }finally{
      btn.disabled = false;
    }
  });

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
