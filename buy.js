// Website course purchase (buy.html): anyone can browse the paid courses;
// buying needs the same account as the app. The price is always worked out
// by the server (api/wayl-checkout -> wayl_prepare_payment), never taken
// from this page. After Wayl the buyer lands on paid.html.
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

  var $ = function (id) { return document.getElementById(id); };
  var list = $('courses'), state = $('state'), who = $('who');
  var courseDlg = $('courseDlg'), authDlg = $('authDlg');

  var courses = [];
  var owned = {};       // slug -> true for active enrollments
  var user = null;
  var current = null;   // course open in the dialog
  var applied = null;   // { code, amount } after a valid discount code
  var busy = false;

  function digits(v) {
    var n = parseInt(String(v == null ? '' : v).replace(/\D/g, ''), 10);
    return isNaN(n) ? 0 : n;
  }
  function money(n) { return n.toLocaleString('en-US') + ' د.ع'; }
  function title(c) { return c.title || ''; }
  function teacher(c) { return c.teacher_name || ''; }
  function paid(c) { return !c.is_free && digits(c.price) > 0; }
  function thumb(c) {
    var u = String(c.thumbnail_url || '');
    return u.indexOf(STORAGE) === 0 ? u : '';
  }
  function setMsg(el, text, kind) {
    el.textContent = text || '';
    el.className = 'msg' + (kind ? ' ' + kind : '');
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
  function renderWho() {
    who.textContent = '';
    if (user) {
      var name = document.createElement('span');
      name.innerHTML = 'مسجّل باسم <b></b>';
      name.querySelector('b').textContent = user.email || '';
      var out = document.createElement('button');
      out.className = 'link-btn';
      out.type = 'button';
      out.textContent = 'تسجيل الخروج';
      out.onclick = function () {
        sb.auth.signOut().finally(function () { user = null; owned = {}; renderWho(); renderList(); });
      };
      who.append(name, out);
    } else {
      var inBtn = document.createElement('button');
      inBtn.className = 'link-btn';
      inBtn.type = 'button';
      inBtn.textContent = 'تسجيل الدخول';
      inBtn.onclick = function () { openAuth(); };
      who.append(inBtn);
    }
  }

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
    $('email').focus();
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

  $('googleBtn').addEventListener('click', function () {
    // Comes back to this page with the open course, see start().
    var back = location.origin + '/buy.html' + (current ? '?c=' + encodeURIComponent(current.slug) : '');
    sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: back } });
  });

  function afterSignIn() {
    return sb.auth.getUser().then(function (r) {
      user = r.data && r.data.user ? r.data.user : null;
      renderWho();
      return loadOwned();
    }).then(function () {
      renderList();
      if (current) openCourse(current);
    });
  }

  // ---------- courses ----------
  function renderList() {
    list.textContent = '';
    courses.forEach(function (c) {
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'course';
      var src = thumb(c);
      var img = document.createElement(src ? 'img' : 'div');
      if (src) { img.src = src; img.alt = ''; img.loading = 'lazy'; img.onerror = function () { img.removeAttribute('src'); }; }
      else img.className = 'ph';
      var body = document.createElement('div');
      body.className = 'body';
      var h = document.createElement('h3'); h.textContent = title(c);
      var t = document.createElement('div'); t.className = 'teacher'; t.textContent = teacher(c);
      var foot = document.createElement('div'); foot.className = 'foot';
      var p = document.createElement('span'); p.className = 'price';
      p.textContent = paid(c) ? money(digits(c.price)) : 'مجانية';
      foot.append(p);
      if (owned[c.slug]) {
        var o = document.createElement('span'); o.className = 'owned'; o.textContent = 'مشترك';
        foot.append(o);
      }
      body.append(h, t, foot);
      card.append(img, body);
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
    $('cTitle').textContent = title(c);
    $('cTeacher').textContent = teacher(c);
    $('cDesc').textContent = c.description || '';
    var mine = !!owned[c.slug], free = !paid(c);
    if (free) { $('cPrice').textContent = 'مجانية'; $('cOld').textContent = ''; } else showPrice();
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
        user = null; renderWho(); setMsg($('cMsg'), ''); openAuth(); return;
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
  courseDlg.addEventListener('close', function () { if (!authDlg.open) current = null; });

  // ---------- start ----------
  function start() {
    sb.auth.getUser().then(function (r) {
      user = r.data && r.data.user ? r.data.user : null;
      renderWho();
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
