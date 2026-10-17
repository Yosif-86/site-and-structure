// Website course purchase (buy.html), styled like the app: anyone can
// browse the courses; buying needs the same account as the app. The price
// is always worked out by the server (api/wayl-checkout ->
// wayl_prepare_payment), never taken from this page. After Wayl the buyer
// lands on paid.html.
//
// Like staff-login.js, signing in here does NOT claim a device slot
// (/api/check-device): this page only buys, it never shows course content,
// so it must not kick the student's phone off its single device slot.
(function () {
  var sb = supabase.createClient(
    'https://qdarzhzttjpkgfihupgp.supabase.co',
    'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q'
  );
  var STORAGE = 'https://qdarzhzttjpkgfihupgp.supabase.co/';
  var SVG = 'http://www.w3.org/2000/svg';
  // Same line icons as the app (widgets/arc_icons.dart).
  var ICONS = {
    lessons: ['M6.5 4.5 H17.5 Q19.5 4.5 19.5 6.5 V17.5 Q19.5 19.5 17.5 19.5 H6.5 Q4.5 19.5 4.5 17.5 V6.5 Q4.5 4.5 6.5 4.5 Z', 'M10.3 9 L15 12 L10.3 15 Z'],
    files: ['M8 5 H6.5 Q5 5 5 6.5 V19 Q5 20.5 6.5 20.5 H17.5 Q19 20.5 19 19 V6.5 Q19 5 17.5 5 H16', 'M9 3.5 H15 V6.5 H9 Z', 'M9 13.5 L11.2 15.7 L15.2 11.5'],
    clock: ['M12 3.2 A8.8 8.8 0 1 1 11.99 3.2 Z', 'M12 7.5 V12 L15 14']
  };

  var $ = function (id) { return document.getElementById(id); };
  var list = $('courses'), state = $('state');
  var courseDlg = $('courseDlg'), authDlg = $('authDlg'), meDlg = $('meDlg');

  var courses = [];
  var stats = {};       // course id -> { lessons, files, seconds }
  var owned = {};       // slug -> true for active enrollments
  var user = null;
  var current = null;   // course open in the sheet
  var applied = null;   // { code, amount } after a valid discount code
  var busy = false;

  function digits(v) {
    var n = parseInt(String(v == null ? '' : v).replace(/\D/g, ''), 10);
    return isNaN(n) ? 0 : n;
  }
  function money(n) { return n.toLocaleString('en-US') + ' د.ع'; }
  function paid(c) { return !c.is_free && digits(c.price) > 0; }
  function thumb(c) {
    var u = String(c.thumbnail_url || '');
    return u.indexOf(STORAGE) === 0 ? u : '';
  }
  function setMsg(el, text, kind) {
    el.textContent = text || '';
    el.className = 'msg' + (kind ? ' ' + kind : '');
  }
  function duration(sec) {
    var m = Math.round(sec / 60), h = Math.floor(m / 60);
    if (h && m % 60) return h + ' س ' + (m % 60) + ' د';
    return h ? h + ' س' : Math.max(m, 1) + ' د';
  }
  function icon(name, cls) {
    var s = document.createElementNS(SVG, 'svg');
    s.setAttribute('viewBox', '0 0 24 24');
    if (cls) s.setAttribute('class', cls);
    (ICONS[name] || []).forEach(function (d) {
      var p = document.createElementNS(SVG, 'path');
      p.setAttribute('d', d);
      s.appendChild(p);
    });
    return s;
  }
  function chip(name, text) {
    var c = document.createElement('span');
    c.className = 'chip';
    var t = document.createElement('span');
    t.textContent = text;
    c.append(icon(name), t);
    return c;
  }
  function chipsFor(c) {
    var st = stats[c.id] || {};
    var out = [];
    if (st.lessons) out.push(chip('lessons', st.lessons + ' درس'));
    if (st.files) out.push(chip('files', st.files + ' ملف'));
    if (st.seconds) out.push(chip('clock', duration(st.seconds)));
    return out;
  }

  var ERRORS = {
    already_enrolled: 'أنت مشترك في هذه الدورة بالفعل. افتحها من التطبيق.',
    course_free: 'هذه الدورة مجانية، سجّل فيها من التطبيق.',
    course_unavailable: 'هذه الدورة غير متاحة حاليًا.',
    code_invalid: 'كود الخصم غير صالح لهذه الدورة.',
    amount_too_low: 'المبلغ أقل من الحد الأدنى للدفع.',
    payment_provider_error: 'تعذّر فتح صفحة الدفع الآن. حاول بعد قليل.',
    payments_not_configured: 'الدفع الإلكتروني غير متاح حاليًا.'
  };

  // ---------- account ----------
  function renderAvatar() {
    var a = $('avatar');
    a.classList.toggle('in', !!user);
    if (user) {
      var name = (user.user_metadata && (user.user_metadata.full_name || user.user_metadata.name)) || user.email || '';
      a.textContent = (name.trim()[0] || '؟').toUpperCase();
      a.setAttribute('aria-label', 'حسابك');
    } else {
      a.textContent = '';
      a.append(icon('profile'));
      a.setAttribute('aria-label', 'تسجيل الدخول');
    }
  }
  ICONS.profile = ['M12 4.7 A3.6 3.6 0 1 1 11.99 4.7 Z', 'M4.8 20.2 C5.4 16.6 8.4 14.6 12 14.6 C15.6 14.6 18.6 16.6 19.2 20.2'];

  $('avatar').addEventListener('click', function () {
    if (!user) { openAuth(); return; }
    $('meEmail').textContent = user.email || '';
    meDlg.showModal();
  });
  $('signOut').addEventListener('click', function () {
    sb.auth.signOut().finally(function () {
      user = null; owned = {};
      meDlg.close(); renderAvatar(); renderList();
    });
  });

  function loadOwned() {
    owned = {};
    if (!user) return Promise.resolve();
    return sb.from('enrollments').select('course_slug').eq('user_id', user.id).eq('status', 'active')
      .then(function (r) { (r.data || []).forEach(function (e) { owned[e.course_slug] = true; }); })
      .catch(function () {});
  }

  function openAuth() {
    setMsg($('authMsg'), '');
    authDlg.showModal();
  }

  $('authForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var email = $('email').value.trim(), password = $('password').value;
    if (!email || !password) { setMsg($('authMsg'), 'أدخل البريد الإلكتروني وكلمة المرور.', 'err'); return; }
    var btn = $('loginBtn');
    btn.setAttribute('aria-disabled', 'true');
    setMsg($('authMsg'), 'جارٍ تسجيل الدخول…');
    sb.auth.signInWithPassword({ email: email, password: password }).then(function (r) {
      btn.removeAttribute('aria-disabled');
      if (r.error) {
        setMsg($('authMsg'), /invalid/i.test(r.error.message)
          ? 'البريد الإلكتروني أو كلمة المرور غير صحيحة.' : 'تعذّر تسجيل الدخول. حاول مرة أخرى.', 'err');
        return;
      }
      $('password').value = '';
      authDlg.close();
      afterSignIn();
    });
  });

  // Google sign-in. With GIS_READY on, Google's own button runs on this
  // domain and hands Supabase an ID token, so Google's account picker says
  // "to continue to arcplatformiq.com" (like the app's native sign-in)
  // instead of the supabase.co address the redirect flow shows. Needs
  // https://arcplatformiq.com in the web OAuth client's Authorized
  // JavaScript origins (Google Cloud, project arc-platform-39b9e).
  var GIS_READY = false;
  var GOOGLE_WEB_CLIENT = '982425355302-nn9u5ksh0jhmv44cd8vvv049bbc69ad0.apps.googleusercontent.com';

  function googleRedirect() {
    // Comes back to this page with the open course, see start().
    var back = location.origin + '/buy.html' + (current ? '?c=' + encodeURIComponent(current.slug) : '');
    sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: back } });
  }
  $('googleBtn').addEventListener('click', googleRedirect);

  function hex(buf) {
    return Array.prototype.map.call(new Uint8Array(buf), function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }
  function setupGis() {
    if (!GIS_READY || !window.crypto || !crypto.subtle) return;
    var raw = hex(crypto.getRandomValues(new Uint8Array(16)));
    var s = document.createElement('script');
    s.src = 'https://accounts.google.com/gsi/client';
    s.async = true;
    s.onload = function () {
      crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw)).then(function (h) {
        // Google puts sha256(nonce) in the token; Supabase checks it against raw.
        google.accounts.id.initialize({
          client_id: GOOGLE_WEB_CLIENT,
          nonce: hex(h),
          ux_mode: 'popup',
          context: 'signin',
          callback: function (resp) {
            setMsg($('authMsg'), 'جارٍ تسجيل الدخول…');
            sb.auth.signInWithIdToken({ provider: 'google', token: resp.credential, nonce: raw }).then(function (r) {
              if (r.error) { setMsg($('authMsg'), 'تعذّر تسجيل الدخول بجوجل. حاول مرة أخرى.', 'err'); return; }
              authDlg.close();
              afterSignIn();
            });
          }
        });
        var holder = $('gisBtn');
        google.accounts.id.renderButton(holder, {
          type: 'standard', theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'filled_black' : 'outline',
          size: 'large', shape: 'pill', text: 'continue_with', locale: 'ar', width: Math.min(holder.clientWidth || 360, 400)
        });
        holder.hidden = false;
        $('googleBtn').hidden = true;
      });
    };
    // If Google's script cannot load, the redirect button stays.
    document.head.appendChild(s);
  }
  setupGis();

  function afterSignIn() {
    return sb.auth.getUser().then(function (r) {
      user = r.data && r.data.user ? r.data.user : null;
      renderAvatar();
      return loadOwned();
    }).then(function () {
      renderList();
      if (current) openCourse(current);
    });
  }

  // ---------- courses ----------
  function renderList() {
    list.textContent = '';
    $('count').textContent = String(courses.length);
    courses.forEach(function (c) {
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'course';
      var src = thumb(c);
      var img = document.createElement(src ? 'img' : 'div');
      img.className = 'thumb';
      if (src) { img.src = src; img.alt = ''; img.loading = 'lazy'; }
      var info = document.createElement('div');
      info.className = 'info';
      var h = document.createElement('h3'); h.textContent = c.title || '';
      h.dir = 'auto';
      if (/^[\x00-\x7F]*$/.test(c.title || '')) h.classList.add('latin');
      var chips = document.createElement('div'); chips.className = 'chips';
      chipsFor(c).forEach(function (x) { chips.append(x); });
      var price = document.createElement('div');
      var p = document.createElement('span');
      p.className = 'price num' + (paid(c) ? '' : ' free');
      p.textContent = paid(c) ? money(digits(c.price)) : 'مجاني';
      price.append(p);
      if (owned[c.slug]) {
        var o = document.createElement('span'); o.className = 'owned'; o.textContent = 'مشترك';
        price.append(o);
      }
      info.append(h, chips, price);
      var chev = document.createElementNS(SVG, 'svg');
      chev.setAttribute('viewBox', '0 0 24 24');
      chev.setAttribute('class', 'chev');
      var cp = document.createElementNS(SVG, 'path');
      cp.setAttribute('d', 'M14.5 6 L8.5 12 L14.5 18');
      chev.appendChild(cp);
      card.append(img, info, chev);
      card.onclick = function () { openCourse(c); };
      list.append(card);
    });
    state.style.display = courses.length ? 'none' : '';
    if (!courses.length) state.textContent = 'لا توجد دورات متاحة حاليًا.';
  }

  function showPrice() {
    var full = digits(current.price);
    if (applied) {
      $('cPrice').textContent = money(applied.amount);
      $('cOld').textContent = money(full);
    } else {
      $('cPrice').textContent = money(full);
      $('cOld').textContent = '';
    }
  }

  function openCourse(c) {
    current = c;
    applied = null;
    $('cCode').value = '';
    var src = thumb(c);
    $('cImg').style.display = src ? '' : 'none';
    if (src) $('cImg').src = src;
    $('cTitle').textContent = c.title || '';
    $('cTeacher').textContent = c.teacher_name ? 'المدرّس: ' + c.teacher_name : '';
    var chips = $('cChips');
    chips.textContent = '';
    chipsFor(c).forEach(function (x) { chips.append(x); });
    $('cDesc').textContent = c.description || '';
    var mine = !!owned[c.slug], free = !paid(c);
    $('cPrice').className = 'price num' + (free ? ' free' : '');
    if (free) { $('cPrice').textContent = 'مجاني'; $('cOld').textContent = ''; } else showPrice();
    $('cBuy').style.display = mine || free ? 'none' : '';
    $('codeRow').style.display = mine || free ? 'none' : '';
    setMsg($('cMsg'), mine ? ERRORS.already_enrolled : free ? ERRORS.course_free : '', mine || free ? 'ok' : '');
    if (!courseDlg.open) courseDlg.showModal();
  }

  $('cApply').addEventListener('click', function () {
    var code = $('cCode').value.trim().toUpperCase();
    if (!code || busy) return;
    if (!user) { openAuth(); return; }
    busy = true;
    setMsg($('cMsg'), 'جارٍ التحقق من الكود…');
    sb.rpc('preview_discount_code', { p_code: code, p_course_id: current.id }).then(function (r) {
      busy = false;
      var row = (r.data || [])[0];
      if (r.error || !row) { applied = null; showPrice(); setMsg($('cMsg'), ERRORS.code_invalid, 'err'); return; }
      var full = digits(current.price);
      var off = row.discount_type === 'percent'
        ? Math.round(full * Number(row.discount_value) / 100) : Math.round(Number(row.discount_value));
      applied = { code: code, amount: Math.max(0, full - Math.min(off, full)) };
      showPrice();
      setMsg($('cMsg'), 'تم تطبيق الخصم.', 'ok');
    });
  });

  $('cBuy').addEventListener('click', function () {
    if (busy) return;
    if (!user) { openAuth(); return; }
    busy = true;
    var btn = $('cBuy');
    btn.setAttribute('aria-disabled', 'true');
    setMsg($('cMsg'), 'جارٍ فتح صفحة الدفع…');
    sb.auth.getSession().then(function (s) {
      var token = s.data && s.data.session ? s.data.session.access_token : '';
      if (!token) throw { status: 401 };
      return fetch('/api/wayl-checkout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
        body: JSON.stringify({ courseSlug: current.slug, code: applied ? applied.code : undefined })
      });
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, j: j }; });
    }).then(function (res) {
      if (res.status === 200 && res.j.url && /^https:\/\//.test(res.j.url)) {
        location.href = res.j.url;
        return;
      }
      throw res;
    }).catch(function (res) {
      busy = false;
      btn.removeAttribute('aria-disabled');
      if (res && res.status === 401) {
        user = null; renderAvatar(); setMsg($('cMsg'), ''); openAuth(); return;
      }
      var key = res && res.j && res.j.error;
      if (key === 'already_enrolled') { owned[current.slug] = true; renderList(); }
      setMsg($('cMsg'), ERRORS[key] || (res && res.status === 429
        ? 'محاولات كثيرة، انتظر دقيقة ثم حاول.' : 'تعذّر بدء الدفع. تحقق من الإنترنت وحاول مرة أخرى.'), 'err');
    });
  });

  document.querySelectorAll('[data-close]').forEach(function (b) {
    b.addEventListener('click', function () { b.closest('dialog').close(); });
  });
  // Tap outside a sheet closes it.
  [courseDlg, authDlg, meDlg].forEach(function (d) {
    d.addEventListener('click', function (e) { if (e.target === d) d.close(); });
  });
  courseDlg.addEventListener('close', function () { if (!authDlg.open) current = null; });

  // Lesson count, total length and file count per course, like the app's cards.
  function loadStats(ids) {
    if (!ids.length) return Promise.resolve();
    return Promise.all([
      sb.from('lectures').select('course_id, duration_seconds, r2_path').in('course_id', ids),
      sb.from('course_files').select('course_id, status').in('course_id', ids)
    ]).then(function (res) {
      (res[0].data || []).forEach(function (l) {
        if (!l.r2_path) return;
        var s = stats[l.course_id] || (stats[l.course_id] = { lessons: 0, files: 0, seconds: 0 });
        s.lessons += 1;
        s.seconds += Number(l.duration_seconds) || 0;
      });
      (res[1].data || []).forEach(function (f) {
        if (f.status !== 'published') return;
        var s = stats[f.course_id] || (stats[f.course_id] = { lessons: 0, files: 0, seconds: 0 });
        s.files += 1;
      });
    }).catch(function () {});
  }

  // ---------- start ----------
  function start() {
    renderAvatar();
    sb.auth.getUser().then(function (r) {
      user = r.data && r.data.user ? r.data.user : null;
      renderAvatar();
      return Promise.all([
        loadOwned(),
        sb.from('courses')
          .select('id, slug, title, price, is_free, thumbnail_url, teacher_name, description')
          .eq('status', 'published')
          .order('created_at', { ascending: false })
      ]);
    }).then(function (res) {
      var r = res[1];
      if (r.error) throw r.error;
      // Paid courses first; free ones are listed too (taken from the app).
      courses = (r.data || []).slice().sort(function (a, b) { return paid(b) - paid(a); });
      return loadStats(courses.map(function (c) { return c.id; }));
    }).then(function () {
      renderList();
      // Back from Google sign-in: reopen the course that was being bought.
      var slug = new URLSearchParams(location.search).get('c');
      var back = courses.filter(function (c) { return c.slug === slug; })[0];
      if (back) openCourse(back);
    }).catch(function () {
      state.textContent = 'تعذّر تحميل الدورات. حدّث الصفحة.';
    });
  }
  start();
})();
