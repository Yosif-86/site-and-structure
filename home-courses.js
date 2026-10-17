// Landing page: the latest published courses as preview cards. A card
// opens the course on the purchase page (/buy?c=slug), where it expands
// into the full sheet. Read-only, public data (published courses and
// their lecture/file counts are anon-readable by design).
(function () {
  var box = document.getElementById('homeCourses');
  if (!box || !window.supabase) return;
  var sb = supabase.createClient(
    'https://qdarzhzttjpkgfihupgp.supabase.co',
    'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q'
  );
  var STORAGE = 'https://qdarzhzttjpkgfihupgp.supabase.co/';
  var SVG = 'http://www.w3.org/2000/svg';

  function digits(v) {
    var n = parseInt(String(v == null ? '' : v).replace(/\D/g, ''), 10);
    return isNaN(n) ? 0 : n;
  }
  function paid(c) { return !c.is_free && digits(c.price) > 0; }
  function duration(sec) {
    var m = Math.round(sec / 60), h = Math.floor(m / 60);
    if (h && m % 60) return h + ' س ' + (m % 60) + ' د';
    return h ? h + ' س' : Math.max(m, 1) + ' د';
  }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function personIcon() {
    var s = document.createElementNS(SVG, 'svg');
    s.setAttribute('viewBox', '0 0 24 24');
    ['M12 4.7 A3.6 3.6 0 1 1 11.99 4.7 Z', 'M4.8 20.2 C5.4 16.6 8.4 14.6 12 14.6 C15.6 14.6 18.6 16.6 19.2 20.2']
      .forEach(function (d) { var p = document.createElementNS(SVG, 'path'); p.setAttribute('d', d); s.appendChild(p); });
    return s;
  }

  function render(courses, stats) {
    box.textContent = '';
    if (!courses.length) {
      document.getElementById('courses').hidden = true;
      return;
    }
    courses.forEach(function (c) {
      var a = el('a', 'ccard');
      a.href = '/buy?c=' + encodeURIComponent(c.slug);
      var cover = el('div', 'cover');
      var src = String(c.thumbnail_url || '');
      if (src.indexOf(STORAGE) === 0) {
        var img = el('img');
        img.src = src; img.alt = ''; img.loading = 'lazy';
        cover.append(img);
      }
      cover.append(el('span', 'badge' + (paid(c) ? '' : ' free'), paid(c) ? 'دورة مدفوعة' : 'مجانية'));
      var body = el('div', 'cbody');
      var h = el('h3', null, c.title || '');
      body.append(h);
      if (c.teacher_name) {
        var who = el('div', 'who');
        who.append(personIcon(), el('span', null, c.teacher_name));
        body.append(who);
      }
      var st = stats[c.id];
      if (st) {
        var chips = el('div', 'chips');
        if (st.lessons) chips.append(el('span', 'chip', st.lessons + ' درس'));
        if (st.files) chips.append(el('span', 'chip', st.files + ' ملف'));
        if (st.seconds) chips.append(el('span', 'chip', duration(st.seconds)));
        body.append(chips);
      }
      body.append(el('div', 'cprice' + (paid(c) ? '' : ' free'),
        paid(c) ? digits(c.price).toLocaleString('en-US') + ' د.ع' : 'مجاني'));
      a.append(cover, body);
      box.append(a);
    });
  }

  sb.from('courses')
    .select('id, slug, title, price, is_free, thumbnail_url, teacher_name')
    .eq('status', 'published')
    .order('created_at', { ascending: false })
    .limit(6)
    .then(function (r) {
      if (r.error) throw r.error;
      var courses = r.data || [];
      var ids = courses.map(function (c) { return c.id; });
      if (!ids.length) { render([], {}); return; }
      return Promise.all([
        sb.from('lectures').select('course_id, duration_seconds, r2_path').in('course_id', ids),
        sb.from('course_files').select('course_id, status').in('course_id', ids)
      ]).then(function (res) {
        var stats = {};
        function s(id) { return stats[id] || (stats[id] = { lessons: 0, files: 0, seconds: 0 }); }
        (res[0].data || []).forEach(function (l) {
          if (!l.r2_path) return;
          s(l.course_id).lessons += 1;
          s(l.course_id).seconds += Number(l.duration_seconds) || 0;
        });
        (res[1].data || []).forEach(function (f) { if (f.status === 'published') s(f.course_id).files += 1; });
        render(courses, stats);
      }, function () { render(courses, {}); });
    })
    .catch(function () { document.getElementById('courses').hidden = true; });
})();
