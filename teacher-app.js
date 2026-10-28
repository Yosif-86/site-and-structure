// Teacher dashboard for the website: same screens, wording and look as the
// app's teacher dashboard (mobile_app/lib/screens/teacher_screen.dart).
// External file (script-src 'self'), so no CSP hash is needed.
(function(){
'use strict';

const sb = supabase.createClient(
  'https://qdarzhzttjpkgfihupgp.supabase.co',
  'sb_publishable_eNLSJi_xpL2fnrJsHKajeQ_sT9Kds9q'
);

// ---------- strings and small helpers ----------
const FALLBACK = {
  status_rejected: 'مرفوضة', back: 'رجوع', sign_out: 'تسجيل الخروج', theme: 'المظهر',
  dash_codes_title: 'أكواد الخصم', students_title: 'الطلاب', earnings_title: 'الأرباح',
  pending_edit_note: 'تعديلاتك على دورة منشورة تنتظر موافقة الإدارة، والطلاب يرون النسخة الحالية.',
  keep_open: 'أبقِ هذه الصفحة مفتوحة حتى يكتمل الرفع.', done: 'تم', delete_lecture_confirm: 'حذف هذه المحاضرة؟',
  stop_code_confirm: 'إيقاف هذا الكود؟', no_students_here: 'لا يوجد طلاب بعد.', course_mark: 'دورة',
  code_expired: 'منتهٍ', max_uses_hint: 'عدد الاستخدامات', pick_image: 'اختر صورة'
};
const TS = window.TS || {};
const t = (k) => (TS[k] != null ? TS[k] : (FALLBACK[k] != null ? FALLBACK[k] : k));
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const $ = (s, r) => (r || document).querySelector(s);
const digits = (v) => { const d = String(v == null ? '' : v).replace(/[^0-9]/g, ''); return d ? parseInt(d, 10) : 0; };
const grp = (n) => Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const iqd = (n) => `<bdi dir="ltr">${grp(n)} IQD</bdi>`;
const pct = (rate) => { const v = Math.round(rate * 10000) / 100; return v === Math.round(v) ? String(Math.round(v)) : String(v); };
const when = (iso) => { const d = new Date(iso); return isNaN(d) ? '—' : d.toISOString().slice(0, 16).replace('T', ' '); };
const slugify = (s) => ((s || '').toLowerCase().trim().replace(/[^a-z0-9؀-ۿ]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)) || 'course';
const MAX_POINTS = 12, MIN_POINT_ROWS = 3;
const DEFAULT_RATE = 0.15, MAX_RATE = 30;
const rateFrom = (p) => { const n = Number(p); return (p == null || isNaN(n) || n < 0 || n > MAX_RATE) ? DEFAULT_RATE : n / 100; };

// Line icons in the app's style (stroke, round caps).
const IC = {
  home: '<path d="M4 11l8-7 8 7v8.5a1.5 1.5 0 0 1-1.5 1.5H15v-6H9v6H5.5A1.5 1.5 0 0 1 4 19.5z"/>',
  courses: '<path d="M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5z"/><path d="M5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3M9 7.5h6"/>',
  users: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c.6-3.4 3-5 6-5s5.4 1.6 6 5"/><circle cx="17.5" cy="9" r="2.4"/><path d="M17 14.2c2.2.2 3.6 1.6 4 4.3"/>',
  money: '<circle cx="12" cy="12" r="9"/><path d="M12 7v10M9.5 9.5c0-1 1-1.7 2.5-1.7s2.5.7 2.5 1.8c0 2.2-5 1.2-5 3.6 0 1.1 1 1.8 2.5 1.8s2.5-.7 2.5-1.7"/>',
  wallet: '<rect x="3" y="6" width="18" height="13" rx="3"/><path d="M3 10h18M16 14.5h2"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="2.5"/><path d="M16 10.5l5-3v9l-5-3z"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  tag: '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8.5" r="1.3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6.5 7l1 13h9l1-13M10 11v6M14 11v6"/>',
  back: '<path d="M9.5 5.5L16 12l-6.5 6.5"/>',
  chevron: '<path d="M14.5 6L9 12l5.5 6"/>',
  calendar: '<rect x="4" y="5" width="16" height="15" rx="3"/><path d="M4 10h16M9 3v4M15 3v4"/>',
  close: '<path d="M6 6l12 12M18 6L6 18"/>',
  review: '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 16.9 6.8 19.7l1-5.9L3.5 9.7l5.9-.8z"/>',
  dashboard: '<rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="5" rx="2"/><rect x="13" y="10" width="8" height="11" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="1.8"/><path d="M4 18l5-5 4 4 3-3 4 4"/>',
  logout: '<path d="M10 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4M15 8l4 4-4 4M19 12H9"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/>',
  moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>'
};
const icon = (n, cls) => `<svg class="i ${cls || ''}" viewBox="0 0 24 24" aria-hidden="true">${IC[n] || ''}</svg>`;
const MARK = '<svg viewBox="211 249 400 400" aria-hidden="true"><defs><clipPath id="arcClip"><rect x="200" y="240" width="420" height="388"></rect></clipPath></defs><path fill="none" stroke="currentColor" stroke-width="44" stroke-linejoin="round" clip-path="url(#arcClip)" d="M347 456 L399 320 Q418 270 438 320 L540 575 C552 605 530 618 505 598 L420 532 C400 514 330 496 306 566 L280 645"></path></svg>';

// ---------- theme (follows the device until the teacher picks one) ----------
function applyTheme(mode){
  if(mode === 'light' || mode === 'dark') document.documentElement.setAttribute('data-theme', mode);
  else document.documentElement.removeAttribute('data-theme');
}
function currentIsDark(){
  const a = document.documentElement.getAttribute('data-theme');
  if(a) return a === 'dark';
  return !window.matchMedia('(prefers-color-scheme: light)').matches;
}
try{ const saved = localStorage.getItem('ss_theme'); if(saved === 'light' || saved === 'dark') applyTheme(saved); }catch(e){}
function toggleTheme(){
  const next = currentIsDark() ? 'light' : 'dark';
  applyTheme(next);
  try{ localStorage.setItem('ss_theme', next); }catch(e){}
  render();
}

// ---------- state ----------
const S = {
  user: null, view: 'overview', stack: [],
  courses: [], rows: [], rate: DEFAULT_RATE, prof: {},
  course: null, lectures: [], codes: [],
  form: { title: '', description: '', price: '' }, points: [], thumbFile: null, thumbPreview: null, thumbUrl: null,
  lf: { title: '', free: false, file: null }, uploading: false, upMsg: '', upPct: null,
  cf: { code: '', type: 'percent', value: '', max: '10', expires: '' }, err: {}, ok: {},
  pf: { zain: '', qi: '', qrFile: null }, saving: false, ready: false
};

let toastTimer = null;
function toast(msg){
  const el = $('#toast');
  el.innerHTML = `<div>${esc(msg)}</div>`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.innerHTML = ''; }, 3500);
}

// ---------- navigation ----------
function go(view){
  S.stack.push(S.view);
  S.view = view;
  S.err = {}; S.ok = {};
  history.pushState({ v: view }, '');
  render();
  window.scrollTo(0, 0);
}
function back(){
  const prev = S.stack.pop();
  S.view = prev || 'overview';
  S.err = {}; S.ok = {};
  render();
  window.scrollTo(0, 0);
}
window.addEventListener('popstate', () => {
  if(S.view === 'overview') return;
  const prev = S.stack.pop();
  S.view = prev || 'overview';
  render();
});

// ---------- data ----------
async function loadAll(){
  const uid = S.user.id;
  const [p, c, st] = await Promise.all([
    sb.from('profiles').select('full_name, platform_rate, teacher_zaincash_phone, teacher_qi_account_number, teacher_qi_qr_url').eq('id', uid).maybeSingle(),
    sb.from('courses').select('*').eq('teacher_id', uid).order('created_at', { ascending: false }),
    sb.rpc('get_teacher_students')
  ]);
  S.prof = p.data || {};
  S.rate = rateFrom(S.prof.platform_rate);
  S.pf.zain = S.prof.teacher_zaincash_phone || '';
  S.pf.qi = S.prof.teacher_qi_account_number || '';
  S.courses = c.data || [];
  S.rows = st.data || [];
}
const amountsOf = (r) => {
  const price = r.list_price != null ? Number(r.list_price) : digits(r.course_price);
  const paid = r.amount_paid != null ? Number(r.amount_paid) : price;
  const discount = r.discount_amount != null ? Number(r.discount_amount) : (price > paid ? price - paid : 0);
  return { price, paid, discount };
};
const activeRows = () => S.rows.filter((r) => r.status === 'active');
function statEarnings(){
  const bySlug = {}; S.courses.forEach((c) => { bySlug[c.slug] = c; });
  return activeRows().reduce((sum, r) => {
    const c = bySlug[r.course_slug];
    if(!c || c.is_free) return sum;
    const a = amountsOf(r);
    if(r.pay_to_teacher) return sum + a.paid;
    const cut = Math.min(Math.round(a.price * S.rate), a.paid);
    return sum + (a.paid - cut);
  }, 0);
}
function statStudents(){
  return new Set(activeRows().map((r) => r.email || r.phone || r.enrollment_id)).size;
}
const paymentSet = () => !!((S.prof.teacher_zaincash_phone || '').trim() || (S.prof.teacher_qi_account_number || '').trim() || S.prof.teacher_qi_qr_url);
const attention = () => S.courses.filter((c) => c.status === 'draft').length +
  S.courses.filter((c) => c.edit_status === 'rejected').length + (paymentSet() ? 0 : 1);

// ---------- view helpers ----------
const section = (title, trailing) => `<div class="section"><span>${esc(title)}</span>${trailing || ''}</div>`;
const pill = (label, tone) => `<span class="pill ${tone || 'neutral'}">${esc(label)}</span>`;
const btn = (label, act, o) => {
  o = o || {};
  const cls = ['btn', o.primary ? 'primary' : '', o.danger ? 'danger' : '', o.block ? 'block' : ''].join(' ');
  return `<button class="${cls}" data-act="${act}" ${o.id ? `data-id="${esc(o.id)}"` : ''} ${o.disabled ? 'disabled' : ''}>${o.icon ? icon(o.icon) : ''}${esc(label)}</button>`;
};
const empty = (ic, msg) => `<div class="empty"><div class="c">${icon(ic)}</div><div>${esc(msg)}</div></div>`;
const badge = (ic, c, sm) => `<div class="badge ${sm ? 'sm' : ''} c-${c}">${icon(ic)}</div>`;
const avatar = (name) => `<div class="avatar"><span>${esc(((name || '').trim()[0] || '·').toUpperCase())}</span></div>`;
const statusTone = (s) => ({ published: 'good', pending: 'warn', pending_review: 'warn', rejected: 'bad' }[s] || 'neutral');
const statusLabel = (s) => t('status_' + s);
const errBox = (k) => (S.err[k] ? `<div class="err">${esc(S.err[k])}</div>` : '');
const okBox = (k) => (S.ok[k] ? `<div class="ok">${esc(S.ok[k])}</div>` : '');
const fill = (s, m) => Object.keys(m).reduce((a, k) => a.split('{' + k + '}').join(m[k]), s);
const capText = (s) => fill(s, { max: pct(1 - S.rate), cut: pct(S.rate), mine: pct(1 - S.rate), pct: pct(S.rate) });

// ---------- chrome ----------
const TITLES = { overview: 'teacher_dashboard', courses: 'stat_courses', course: 'edit_course', codes: 'discount_codes', students: 'stat_students', earnings: 'stat_earnings', profile: 'settings_payment_info' };
function renderBar(){
  const bar = $('#bar');
  const isHome = S.view === 'overview';
  const title = S.view === 'course' ? t(S.course ? 'edit_course' : 'new_course_title') : t(TITLES[S.view] || 'teacher_dashboard');
  bar.innerHTML =
    (isHome ? `<div class="mark">${MARK}</div>` : `<button class="iconbtn" data-act="back" aria-label="${esc(t('back'))}">${icon('back')}</button>`) +
    `<div class="title">${esc(title)}</div>` +
    `<button class="iconbtn" data-act="theme" aria-label="${esc(t('theme'))}">${icon(currentIsDark() ? 'sun' : 'moon')}</button>` +
    `<button class="iconbtn" data-act="signout" aria-label="${esc(t('sign_out'))}">${icon('logout')}</button>`;
}

function render(){
  if(!S.ready) return;
  renderBar();
  const v = VIEWS[S.view] || VIEWS.overview;
  $('#main').innerHTML = v();
}

// ---------- views ----------
const VIEWS = {};

VIEWS.overview = () => {
  const d = new Date();
  const date = `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}`;
  const tile = (ic, c, v, l, act, alert) => `
    <button class="glass tap tile" data-act="${act}">
      <div class="top">${badge(ic, c)}<span class="sp"></span>${alert ? '<span class="dot"></span>' : icon('chevron')}</div>
      <div class="v heading">${v}</div><div class="l">${esc(l)}</div>
    </button>`;
  return `
    <div class="glass hero">
      <div class="wm">${MARK}</div>
      <div class="date">${icon('calendar')}<span class="code">${date}</span></div>
      <h1>${esc(t('teacher_dashboard'))}</h1>
      <div class="sub">${esc(t('dash_teacher_sub'))}</div>
      <div class="stats">
        <button class="stat" data-act="go-courses"><div class="v heading">${S.courses.length}</div><div class="l">${esc(t('stat_courses'))}</div></button>
        <button class="stat" data-act="go-students"><div class="v heading">${statStudents()}</div><div class="l">${esc(t('stat_students'))}</div></button>
        <button class="stat" data-act="go-earnings"><div class="v heading">${iqd(statEarnings())}</div><div class="l">${esc(t('stat_earnings'))}</div></button>
        <button class="stat" data-act="go-profile"><div class="v heading">${attention()}</div><div class="l">${esc(t('dash_needs_attention'))}</div></button>
      </div>
    </div>
    ${section(t('dash_quick_actions'))}
    <div class="grid">
      ${tile('courses', 'teal', S.courses.length, t('stat_courses'), 'go-courses')}
      ${tile('users', 'byline', statStudents(), t('stat_students'), 'go-students')}
      ${tile('money', 'red', iqd(statEarnings()), t('stat_earnings'), 'go-earnings')}
      ${tile('wallet', 'teal', paymentSet() ? '✓' : '—', t('settings_payment_info'), 'go-profile', !paymentSet())}
    </div>
    <div style="height:16px"></div>
    ${btn(t('create_course'), 'new-course', { primary: true, icon: 'plus', block: true })}`;
};

VIEWS.courses = () => `
  ${btn(t('create_course'), 'new-course', { primary: true, icon: 'plus', block: true })}
  <div style="height:12px"></div>
  ${S.courses.length ? `<div class="stack">${S.courses.map(courseCard).join('')}</div>` : empty('courses', t('no_courses_teacher'))}`;

function courseCard(c){
  const pend = c.edit_status === 'pending_review';
  const rej = c.edit_status === 'rejected' && c.edit_reject_reason;
  return `
  <div class="glass">
    <div class="dc">
      ${c.thumbnail_url ? `<img class="thumb" src="${esc(c.thumbnail_url)}" alt="">` : '<div class="thumb"></div>'}
      <div class="body">
        <div class="t">${esc(c.title || '—')}</div>
        <div class="s">${c.is_free ? esc(t('card_free')) : iqd(digits(c.price))}</div>
      </div>
      ${pill(statusLabel(c.status), statusTone(c.status))}
    </div>
    ${pend ? `<div style="margin-top:10px">${pill(t('edit_pending'), 'warn')}</div>` : ''}
    ${rej ? `<div class="err">${esc(t('edit_rejected'))}: ${esc(c.edit_reject_reason)}</div>` : ''}
    <div class="actions">
      ${c.status === 'draft' ? btn(t('submit_for_review'), 'submit-review', { primary: true, icon: 'check', id: c.id }) : ''}
      ${btn(t('btn_edit'), 'edit-course', { icon: 'edit', id: c.id })}
      ${btn(t('btn_codes'), 'open-codes', { icon: 'tag', id: c.id })}
      ${btn(t('btn_delete'), 'delete-course', { danger: true, icon: 'trash', id: c.id })}
    </div>
  </div>`;
}

VIEWS.course = () => {
  const f = S.form;
  const filled = S.points.map((p) => p.trim()).filter(Boolean);
  const price = digits(f.price);
  const share = price > 0 ? Math.round(price * S.rate) : 0;
  const preview = S.thumbPreview || S.thumbUrl;
  const info = `
  <div class="glass panel">
    <div class="panel-h">${badge('edit', 'red', true)}<div class="t">${esc(t(S.course ? 'edit_course' : 'new_course_title'))}</div></div>
    ${S.course && S.course.status === 'published' ? `<div class="hint" style="margin-bottom:12px">${esc(t('pending_edit_note'))}</div>` : ''}
    <div class="boxes">
      <div class="box"><div class="bl">${esc(t('label_title'))}</div>
        <textarea rows="2" data-bind="form.title">${esc(f.title)}</textarea></div>
      <div class="box"><div class="bl">${esc(t('what_you_learn'))}</div>
        <button class="tagbtn" data-act="edit-points">
          <div class="n">${filled.length ? `<bdi dir="ltr">${filled.length} / ${MAX_POINTS}</bdi>` : esc(t('learning_point_add'))}</div>
          ${filled.length ? `<div class="p">${esc(filled.slice(0, 2).join(' · '))}</div>` : ''}
        </button></div>
    </div>
    <div class="boxes" style="margin-top:10px">
      <div class="box"><div class="bl">${esc(t('label_thumbnail'))}</div>
        <div class="pick" data-act="pick-thumb">
          ${preview ? `<img src="${esc(preview)}" alt=""><span class="chg">${esc(t('btn_change'))}</span>`
                    : `<div class="ph"><div class="c">${icon('image')}</div>${esc(t('label_thumbnail'))}</div>`}
        </div>
        <input type="file" id="thumbInput" accept="image/*" hidden></div>
      <div class="box"><div class="bl">${esc(t('label_price'))}</div>
        <input type="text" inputmode="numeric" dir="ltr" data-bind="form.price" value="${esc(f.price)}"></div>
    </div>
    <div style="margin-top:12px"><label class="f">${esc(t('label_description'))}</label>
      <textarea rows="4" data-bind="form.description">${esc(f.description)}</textarea></div>
    ${price > 0 ? `<div class="split">
      <div class="c-teal" style="--c:var(--muted)">${esc(fill(t('split_platform'), { pct: pct(S.rate) }))}<b>${iqd(share)}</b></div>
      <div style="--c:var(--teal)">${esc(fill(t('split_yours'), { pct: pct(1 - S.rate) }))}<b>${iqd(price - share)}</b></div></div>` : ''}
    ${errBox('course')}
    <div class="rowbtns">
      <button class="btn primary" data-act="save-course" ${S.saving ? 'disabled' : ''}>${esc(t('save'))}</button>
      <button class="btn" data-act="back">${esc(t('cancel'))}</button>
    </div>
  </div>`;
  return info + (S.course ? curriculumCard() : '');
};

function curriculumCard(){
  const lec = S.lectures;
  return `
  <div style="height:14px"></div>
  <div class="glass panel">
    <div class="panel-h">${badge('video', 'red', true)}<div class="t">${esc(t('curriculum'))} · ${esc(S.course.title || '')}</div></div>
    ${lec.length ? `<div class="stack">${lec.map((l, i) => lectureRow(l, i)).join('')}</div>` : empty('video', t('no_lectures_teacher'))}
    <div class="section" style="padding-top:20px"><span>${esc(t('btn_add'))}</span></div>
    <div class="gap">
      <input type="text" data-bind="lf.title" value="${esc(S.lf.title)}" placeholder="${esc(t('label_lecture_title'))}">
      <div class="pick" data-act="pick-video" style="height:96px">
        <div class="ph"><div class="c">${icon('video')}</div>${esc(S.lf.file ? S.lf.file.name : t('label_video_file'))}</div>
      </div>
      <input type="file" id="videoInput" accept="video/mp4,video/quicktime,video/webm,video/x-matroska" hidden>
      <label class="check"><input type="checkbox" data-bind="lf.free" ${S.lf.free ? 'checked' : ''}>${esc(t('label_free_lecture'))}</label>
    </div>
    ${S.upPct != null ? `<div class="prog"><i style="width:${Math.round(S.upPct * 100)}%"></i></div>` : ''}
    ${S.upMsg ? `<div class="${S.err.lecture ? 'err' : 'ok'}">${esc(S.upMsg)}</div>` : errBox('lecture')}
    <div style="margin-top:10px">${btn(t('btn_add'), 'add-lecture', { primary: true, block: true, disabled: S.uploading })}</div>
    <div class="hint" style="text-align:center;margin-top:8px">${esc(t('upload_background_hint'))}<br>${esc(t('keep_open'))}</div>
  </div>`;
}

function lectureRow(l, i){
  const live = !!l.r2_path;
  return `
  <div class="glass">
    <div class="dc">
      <div class="badge sm" style="--c:var(--red)"><span class="code" style="font-size:13px">${String(i + 1).padStart(2, '0')}</span></div>
      <div class="body"><div class="t">${esc(l.title || '—')}</div>${l.is_free ? `<div class="m teal">${esc(t('free_tag'))}</div>` : ''}</div>
      ${pill(live ? t('status_live') : t('lecture_pending_review'), live ? 'good' : 'warn')}
    </div>
    <div class="actions">
      ${i > 0 ? btn(t('btn_move_up'), 'lec-up', { id: l.id }) : ''}
      ${i < S.lectures.length - 1 ? btn(t('btn_move_down'), 'lec-down', { id: l.id }) : ''}
      ${btn(t('btn_delete'), 'lec-del', { danger: true, icon: 'trash', id: l.id })}
    </div>
  </div>`;
}

VIEWS.codes = () => {
  const c = S.course || {};
  const cf = S.cf;
  return `
  ${section(`${t('discount_codes')} · ${c.title || ''}`)}
  ${S.codes.length ? `<div class="stack">${S.codes.map(codeRow).join('')}</div>` : empty('tag', t('no_codes'))}
  <div style="height:14px"></div>
  <div class="glass panel">
    <div class="panel-h">${badge('tag', 'red', true)}<div class="t">${esc(t('create_code'))}</div></div>
    <div class="hint" style="margin-bottom:12px">${esc(capText(t('discount_cap_hint')))}</div>
    <div class="gap">
      <div><label class="f">${esc(t('label_code'))}</label><input type="text" dir="ltr" data-bind="cf.code" value="${esc(cf.code)}" style="text-transform:uppercase"></div>
      <div class="row2">
        <div><label class="f">${esc(t('label_discount_type'))}</label>
          <select data-bind="cf.type"><option value="percent" ${cf.type === 'percent' ? 'selected' : ''}>${esc(t('percent'))}</option>
          <option value="fixed" ${cf.type === 'fixed' ? 'selected' : ''}>${esc(t('fixed'))}</option></select></div>
        <div><label class="f">${esc(t('label_discount_value'))}</label><input type="text" inputmode="decimal" dir="ltr" data-bind="cf.value" value="${esc(cf.value)}"></div>
      </div>
      <div class="row2">
        <div><label class="f">${esc(t('label_max_uses'))}</label><input type="text" inputmode="numeric" dir="ltr" data-bind="cf.max" value="${esc(cf.max)}"></div>
        <div><label class="f">${esc(t('label_expires'))}</label><input type="date" dir="ltr" data-bind="cf.expires" value="${esc(cf.expires)}"></div>
      </div>
    </div>
    ${errBox('code')}
    <div style="margin-top:14px">${btn(t('btn_add'), 'add-code', { primary: true, block: true, disabled: S.saving })}</div>
  </div>`;
};

function codeRow(c){
  const val = c.discount_type === 'percent' ? `${c.discount_value}%` : iqd(Number(c.discount_value));
  return `
  <div class="glass">
    <div class="dc">${badge('tag', 'byline')}
      <div class="body"><div class="t code" dir="ltr" style="font-size:15px">${esc(c.code)}</div>
        <div class="s">${val} · ${c.used_count}/${c.max_uses} ${esc(t('codes_used'))}</div></div>
      ${pill(c.is_active ? t('status_active_code') : t('status_inactive'), c.is_active ? 'good' : 'neutral')}
    </div>
    ${c.is_active ? `<div class="actions">${btn(t('btn_stop'), 'stop-code', { danger: true, icon: 'close', id: c.id })}</div>` : ''}
  </div>`;
}

VIEWS.students = () => {
  const rows = S.rows;
  if(!rows.length) return empty('users', t('no_students'));
  const distinct = statStudents();
  return `${section(`${t('stat_students')} (${distinct})`)}<div class="stack">${rows.map((r) => {
    const active = r.status === 'active';
    const name = r.full_name || r.email || '—';
    const contact = [r.email, r.phone].filter(Boolean).join(' · ');
    return `<div class="glass"><div class="dc">${avatar(name)}
      <div class="body"><div class="t">${esc(name)}</div><div class="s">${esc(r.course_title || '—')}</div>
        ${contact ? `<div class="m">${esc(contact)}</div>` : ''}
        <div class="m">${esc(when(r.created_at))} · ${iqd(amountsOf(r).paid)}</div></div>
      ${pill(active ? t('status_active') : t('status_pending'), active ? 'good' : 'warn')}</div></div>`;
  }).join('')}</div>`;
};

VIEWS.earnings = () => {
  const act = activeRows();
  if(!act.length) return empty('money', t('earnings_none'));
  const bySlug = {};
  act.forEach((r) => { (bySlug[r.course_slug] = bySlug[r.course_slug] || []).push(r); });
  const share = (r) => {
    const a = amountsOf(r);
    if(r.pay_to_teacher) return { platform: 0, mine: a.paid };
    const platform = Math.min(Math.round(a.price * S.rate), a.paid);
    return { platform, mine: a.paid - platform };
  };
  let collected = 0, platform = 0, mine = 0;
  act.forEach((r) => { const s = share(r); collected += amountsOf(r).paid; platform += s.platform; mine += s.mine; });
  return `
  <div class="glass hero"><div class="wm">${MARK}</div>
    <h1 style="margin-top:0">${esc(t('stat_earnings'))}</h1><div class="sub">${esc(t('earnings_sub'))}</div>
    <div class="stats">
      <div class="stat" style="cursor:default"><div class="v heading">${iqd(collected)}</div><div class="l">${esc(t('rev_collected'))}</div></div>
      <div class="stat" style="cursor:default"><div class="v heading">${iqd(platform)}</div><div class="l">${esc(t('rev_platform_cut'))}</div></div>
      <div class="stat" style="cursor:default"><div class="v heading">${iqd(mine)}</div><div class="l">${esc(t('earnings_yours'))}</div></div>
    </div></div>
  ${Object.keys(bySlug).map((slug) => {
    const list = bySlug[slug];
    return section(`${list[0].course_title || '—'} (${list.length})`) + `<div class="stack">${list.map((r) => {
      const a = amountsOf(r), s = share(r);
      const name = r.full_name || r.email || '—';
      return `<div class="glass"><div class="dc">${avatar(name)}<div class="body"><div class="t">${esc(name)}</div>
        <div class="m">${esc(when(r.created_at))}</div>
        <div class="m">${esc(t('pay_lbl_price'))}: ${iqd(a.price)}</div>
        ${a.discount > 0 ? `<div class="m">${esc(t('pay_lbl_discount'))}: -${iqd(a.discount)}</div>` : ''}
        <div class="m">${esc(t('pay_lbl_paid'))}: ${iqd(a.paid)}</div>
        ${s.platform > 0 ? `<div class="m">${esc(t('rev_platform_cut'))}: ${iqd(s.platform)}</div>` : ''}</div>
        <div class="code" style="color:var(--teal)">${iqd(s.mine)}</div></div></div>`;
    }).join('')}</div>`;
  }).join('')}`;
};

VIEWS.profile = () => `
  <div class="glass panel">
    <div class="panel-h">${badge('wallet', 'teal', true)}<div class="t">${esc(t('my_payment_number'))}</div></div>
    <div class="hint" style="margin-bottom:12px">${esc(t('payment_required_hint'))}</div>
    <div class="gap">
      <div><label class="f">${esc(t('label_zaincash_phone'))}</label><input type="tel" dir="ltr" data-bind="pf.zain" value="${esc(S.pf.zain)}"></div>
      <div><label class="f">${esc(t('label_qi_account'))}</label><input type="text" inputmode="numeric" dir="ltr" data-bind="pf.qi" value="${esc(S.pf.qi)}"></div>
      <div><label class="f">${esc(t('label_qi_qr'))}</label>
        <div class="pick" data-act="pick-qr" style="height:130px">
          ${S.pf.qrPreview || S.prof.teacher_qi_qr_url ? `<img src="${esc(S.pf.qrPreview || S.prof.teacher_qi_qr_url)}" alt=""><span class="chg">${esc(t('btn_change'))}</span>`
            : `<div class="ph"><div class="c">${icon('image')}</div>${esc(t('pick_qr'))}</div>`}
        </div>
        <input type="file" id="qrInput" accept="image/*" hidden></div>
    </div>
    ${errBox('profile')}${okBox('profile')}
    <div style="margin-top:14px">${btn(t('save'), 'save-profile', { primary: true, block: true, disabled: S.saving })}</div>
  </div>`;

// ---------- course actions ----------
function resetCourseForm(c){
  const pend = c && c.edit_status === 'pending_review' && c.pending_edit && typeof c.pending_edit === 'object' ? c.pending_edit : null;
  const src = Object.assign({}, c || {}, pend || {});
  S.form = { title: src.title || '', description: src.description || '', price: c ? grp(digits(src.price)) : '' };
  const pts = Array.isArray(src.learning_points) ? src.learning_points.filter((x) => typeof x === 'string') : [];
  S.points = pts.slice(0, MAX_POINTS);
  while(S.points.length < MIN_POINT_ROWS) S.points.push('');
  S.thumbUrl = src.thumbnail_url || null; S.thumbFile = null; S.thumbPreview = null;
  S.lf = { title: '', free: false, file: null }; S.upMsg = ''; S.upPct = null;
  S.err = {};
}
function openCourse(id){
  S.course = id ? S.courses.find((c) => c.id === id) || null : null;
  resetCourseForm(S.course);
  S.lectures = [];
  go('course');
  if(S.course) loadLectures();
}
async function loadLectures(){
  if(!S.course) return;
  const { data } = await sb.from('lectures').select('*').eq('course_id', S.course.id).order('order_index').order('created_at');
  S.lectures = data || [];
  if(S.view === 'course') render();
}

async function saveCourse(){
  if(S.saving) return;
  const f = S.form, t0 = t;
  S.err = {};
  const title = f.title.trim();
  if(!title){ S.err.course = t0('err_title_required'); return render(); }
  if(!String(f.price).trim()){ S.err.course = t0('err_price_required'); return render(); }
  const description = f.description.trim();
  const price = digits(f.price);
  const points = S.points.map((p) => p.trim()).filter(Boolean).slice(0, MAX_POINTS).map((p) => p.slice(0, 200));
  S.saving = true; render();
  try{
    let thumbnailUrl = S.thumbUrl;
    if(S.thumbFile){
      const path = `${S.user.id}/${Date.now()}-${S.thumbFile.name}`;
      const up = await sb.storage.from('course-thumbnails').upload(path, S.thumbFile);
      if(up.error) throw up.error;
      thumbnailUrl = sb.storage.from('course-thumbnails').getPublicUrl(path).data.publicUrl;
    }
    const c = S.course;
    if(c && c.status === 'published'){
      const { error } = await sb.from('courses').update({
        pending_edit: { title, description, price, thumbnail_url: thumbnailUrl, learning_points: points },
        edit_status: 'pending_review'
      }).eq('id', c.id);
      if(error) throw error;
      toast(t('edit_request_sent'));
    } else if(c){
      const upd = { title, description, price, is_free: price === 0, thumbnail_url: thumbnailUrl };
      if(points.length || (Array.isArray(c.learning_points) && c.learning_points.length)) upd.learning_points = points;
      const { error } = await sb.from('courses').update(upd).eq('id', c.id);
      if(error) throw error;
    } else {
      const ins = {
        slug: slugify(title) + '-' + Math.random().toString(36).slice(2, 8), title, description, price,
        is_free: price === 0, thumbnail_url: thumbnailUrl, teacher_id: S.user.id, status: 'draft'
      };
      if(points.length) ins.learning_points = points;
      const { error } = await sb.from('courses').insert(ins);
      if(error) throw error;
    }
    await loadAll();
    S.saving = false;
    back();
  }catch(e){
    S.saving = false;
    S.err.course = (e && e.message) || String(e);
    render();
  }
}

async function submitReview(id){
  const c = S.courses.find((x) => x.id === id);
  if(!c || !confirm(t('confirm_submit_review').replace('{title}', c.title || ''))) return;
  const { error } = await sb.from('courses').update({ status: 'pending_review' }).eq('id', id);
  if(error){ toast(error.message); return; }
  await loadAll(); render();
}
async function deleteCourse(id){
  const c = S.courses.find((x) => x.id === id);
  if(!c) return;
  let students = 0;
  if(c.status === 'published') students = S.rows.filter((r) => r.course_slug === c.slug && r.status === 'active').length;
  const msg = (students > 0 ? t('confirm_delete_course_students').replace('{n}', students) : t('confirm_delete_course')).replace('{title}', c.title || '');
  if(!confirm(msg)) return;
  const { error } = await sb.from('courses').delete().eq('id', id);
  if(error){ toast(error.message); return; }
  await loadAll(); render();
}

// ---------- lectures: videos go straight to Cloudflare R2 in 8 MB parts ----------
const R2_PART = 8 * 1024 * 1024;
async function r2Authorize(courseId, lectureId){
  const { data: { session } } = await sb.auth.getSession();
  if(!session) throw new Error('not signed in');
  const res = await fetch('/api/r2-upload', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session.access_token },
    body: JSON.stringify({ action: 'upload', courseId, lectureId })
  });
  if(!res.ok) throw new Error('authorize failed (' + res.status + ')');
  return res.json();
}
function r2Url(a, q){
  const u = new URL(a.url);
  const p = Object.assign({ token: a.token, expires: String(a.expires), uid: a.uid }, q);
  Object.keys(p).forEach((k) => u.searchParams.set(k, p[k]));
  return u.toString();
}
async function r2Upload(file, courseId, lectureId, onProgress){
  let a = await r2Authorize(courseId, lectureId);
  const create = await fetch(r2Url(a, { op: 'create' }), { method: 'POST' });
  if(!create.ok) throw new Error('create failed (' + create.status + ')');
  const uploadId = (await create.json()).uploadId;
  const parts = [];
  try{
    let partNumber = 1;
    for(let offset = 0; offset < file.size; offset += R2_PART){
      const blob = file.slice(offset, Math.min(offset + R2_PART, file.size));
      let etag = null;
      for(let attempt = 1; !etag; attempt++){
        try{
          const res = await fetch(r2Url(a, { op: 'part', uploadId, partNumber: String(partNumber) }), {
            method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: blob
          });
          if(res.status === 401 || res.status === 403){ a = await r2Authorize(courseId, lectureId); throw new Error('permission refreshed'); }
          if(!res.ok) throw new Error('part failed (' + res.status + ')');
          etag = (await res.json()).etag;
        }catch(e){
          if(attempt >= 6) throw e;
          await new Promise((r) => setTimeout(r, attempt * 3000));
        }
      }
      parts.push({ partNumber, etag });
      partNumber++;
      onProgress(Math.min(1, (offset + blob.size) / file.size));
    }
    const done = await fetch(r2Url(a, { op: 'complete', uploadId }), {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(parts)
    });
    if(!done.ok) throw new Error('complete failed (' + done.status + ')');
  }catch(e){
    fetch(r2Url(a, { op: 'abort', uploadId }), { method: 'POST' }).catch(() => {});
    throw e;
  }
}
window.addEventListener('beforeunload', (e) => { if(S.uploading){ e.preventDefault(); e.returnValue = ''; } });

async function addLecture(){
  if(S.uploading || !S.course) return;
  S.err.lecture = ''; S.upMsg = '';
  const title = S.lf.title.trim();
  if(!title){ S.err.lecture = t('err_lecture_title_required'); return render(); }
  if(!S.lf.file){ S.err.lecture = t('err_video_required'); return render(); }
  const course = S.course, file = S.lf.file, isFree = S.lf.free;
  const lectureId = crypto.randomUUID();
  S.uploading = true; S.upPct = 0; render();
  try{
    await r2Upload(file, course.id, lectureId, (p) => {
      S.upPct = p; S.upMsg = Math.round(p * 100) + '%';
      const bar = $('.prog > i'); if(bar) bar.style.width = Math.round(p * 100) + '%';
      else render();
    });
    const { data: last } = await sb.from('lectures').select('order_index').eq('course_id', course.id)
      .order('order_index', { ascending: false }).limit(1).maybeSingle();
    const orderIndex = last && last.order_index != null ? last.order_index + 1 : 0;
    const { error } = await sb.from('lectures').insert({
      id: lectureId, course_id: course.id, title, is_free: isFree, order_index: orderIndex,
      pending_upload_path: 'r2:videos/' + lectureId + '/source.mp4'
    });
    if(error) throw error;
    S.lf = { title: '', free: false, file: null };
    S.upMsg = t('upload_done').replace('{title}', title);
  }catch(e){
    S.err.lecture = 'x'; S.upMsg = t('err_video_upload_failed') + ' ' + ((e && e.message) || '');
  }
  S.uploading = false; S.upPct = null;
  await loadLectures(); render();
}
async function moveLecture(id, dir){
  const i = S.lectures.findIndex((l) => l.id === id), j = i + dir;
  if(i < 0 || j < 0 || j >= S.lectures.length) return;
  const a = S.lectures[i], b = S.lectures[j];
  // Renumber the whole list so the swap is real even if positions were equal.
  const list = S.lectures.slice(); list[i] = b; list[j] = a;
  const calls = list.map((l, k) => sb.from('lectures').update({ order_index: k }).eq('id', l.id));
  const res = await Promise.all(calls);
  if(res.some((r) => r.error)) toast(res.find((r) => r.error).error.message);
  await loadLectures();
}
async function deleteLecture(id){
  if(!confirm(t('delete_lecture_confirm'))) return;
  const { error } = await sb.from('lectures').delete().eq('id', id);
  if(error){ toast(error.message); return; }
  await loadLectures();
}

// ---------- codes ----------
function openCodes(id){
  S.course = S.courses.find((c) => c.id === id) || null;
  S.cf = { code: '', type: 'percent', value: '', max: '10', expires: '' };
  S.codes = [];
  go('codes');
  loadCodes();
}
async function loadCodes(){
  if(!S.course) return;
  const { data } = await sb.from('discount_codes').select('*').eq('course_id', S.course.id).order('created_at', { ascending: false });
  S.codes = data || [];
  if(S.view === 'codes') render();
}
async function addCode(){
  if(S.saving || !S.course) return;
  const cf = S.cf; S.err = {};
  const code = cf.code.trim().toUpperCase();
  if(!code){ S.err.code = t('err_code_required'); return render(); }
  const value = Number(String(cf.value).trim());
  if(!value || value <= 0){ S.err.code = t('err_value_required'); return render(); }
  const price = digits(S.course.price);
  const maxShare = 1 - S.rate;
  const tooBig = cf.type === 'percent' ? value > maxShare * 100 : (price > 0 && value > price * maxShare);
  if(tooBig){ S.err.code = capText(t('err_discount_too_large')); return render(); }
  const maxUses = cf.max.trim() === '' ? 1 : parseInt(cf.max, 10);
  if(!maxUses || maxUses < 1){ S.err.code = t('err_max_uses_invalid'); return render(); }
  if(!cf.expires){ S.err.code = t('label_expires'); return render(); }
  const end = new Date(cf.expires + 'T23:59:59');
  S.saving = true; render();
  const { error } = await sb.from('discount_codes').insert({
    course_id: S.course.id, code, discount_type: cf.type, discount_value: value, max_uses: maxUses,
    expires_at: end.toISOString(), created_by: S.user.id
  });
  S.saving = false;
  if(error){
    S.err.code = /discount_too_large/.test(error.message) ? capText(t('err_discount_too_large')) : error.message;
    return render();
  }
  S.cf = { code: '', type: 'percent', value: '', max: '10', expires: '' };
  await loadCodes(); render();
}
async function stopCode(id){
  if(!confirm(t('stop_code_confirm'))) return;
  const { error } = await sb.from('discount_codes').update({ is_active: false }).eq('id', id);
  if(error){ toast(error.message); return; }
  await loadCodes();
}

// ---------- payment info ----------
async function saveProfile(){
  if(S.saving) return;
  S.err = {}; S.ok = {};
  const zain = S.pf.zain.trim(), qi = S.pf.qi.trim();
  if(!zain && !qi){ S.err.profile = t('err_payment_method_required'); return render(); }
  if(zain && !/^07\d{9}$/.test(zain.replace(/[^0-9]/g, ''))){ S.err.profile = t('err_invalid_zain'); return render(); }
  const qd = qi.replace(/[^0-9]/g, '');
  if(qi && (qd.length < 8 || qd.length > 20)){ S.err.profile = t('err_invalid_qi'); return render(); }
  S.saving = true; render();
  try{
    let qrUrl = null;
    if(S.pf.qrFile){
      const path = `${S.user.id}/${Date.now()}-${S.pf.qrFile.name}`;
      const up = await sb.storage.from('payment-qr').upload(path, S.pf.qrFile);
      if(up.error) throw up.error;
      qrUrl = sb.storage.from('payment-qr').getPublicUrl(path).data.publicUrl;
    }
    const upd = { teacher_zaincash_phone: zain || null, teacher_qi_account_number: qi || null };
    if(qrUrl) upd.teacher_qi_qr_url = qrUrl;
    const { error } = await sb.from('profiles').update(upd).eq('id', S.user.id);
    if(error) throw error;
    S.pf.qrFile = null; S.pf.qrPreview = null;
    await loadAll();
    S.ok.profile = t('saved');
  }catch(e){ S.err.profile = (e && e.message) || String(e); }
  S.saving = false; render();
}

// ---------- learning points sheet ----------
function openPoints(){
  const bg = document.createElement('div');
  bg.className = 'sheet-bg';
  const draw = () => {
    bg.innerHTML = `<div class="sheet" role="dialog">
      <div style="font-size:15px;font-weight:700">${esc(t('what_you_learn'))}</div>
      <div class="hint" style="margin:2px 0 10px">${esc(t('learning_points_helper'))}</div>
      ${S.points.map((p, i) => `<div class="prow"><input type="text" maxlength="200" data-pt="${i}" value="${esc(p)}" placeholder="${esc(t('learning_point_n'))} ${i + 1}">
        <button class="iconbtn" data-ptdel="${i}" aria-label="${esc(t('remove'))}">${icon('close')}</button></div>`).join('')}
      ${S.points.length < MAX_POINTS ? `<button class="btn" data-ptadd="1">${icon('plus')}${esc(t('learning_point_add'))}</button>` : ''}
      <div class="rowbtns"><button class="btn primary" data-ptdone="1">${esc(t('done'))}</button></div></div>`;
  };
  draw();
  bg.addEventListener('input', (e) => { const i = e.target.getAttribute('data-pt'); if(i != null) S.points[+i] = e.target.value; });
  bg.addEventListener('click', (e) => {
    const del = e.target.closest('[data-ptdel]'), add = e.target.closest('[data-ptadd]'), done = e.target.closest('[data-ptdone]');
    if(del){ const i = +del.getAttribute('data-ptdel'); if(S.points.length > MIN_POINT_ROWS) S.points.splice(i, 1); else S.points[i] = ''; draw(); }
    else if(add){ if(S.points.length < MAX_POINTS) S.points.push(''); draw(); }
    else if(done || e.target === bg){ bg.remove(); render(); }
  });
  document.body.appendChild(bg);
}

// ---------- events ----------
function setBound(path, value){
  const [group, key] = path.split('.');
  if(S[group]) S[group][key] = value;
}
document.addEventListener('input', (e) => {
  const p = e.target.getAttribute && e.target.getAttribute('data-bind');
  if(!p) return;
  const v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
  setBound(p, v);
  if(p === 'form.price'){
    // Group digits as they are typed; the split chips follow the price.
    const caret = digits(v);
    const shown = caret ? grp(caret) : '';
    e.target.value = shown; S.form.price = shown;
    const keep = e.target;
    render();
    const again = $('[data-bind="form.price"]'); if(again && keep){ again.focus(); again.setSelectionRange(shown.length, shown.length); }
  }
});
document.addEventListener('change', (e) => {
  const id = e.target.id;
  const file = e.target.files && e.target.files[0];
  if(id === 'thumbInput' && file){
    S.thumbFile = file;
    const r = new FileReader(); r.onload = () => { S.thumbPreview = r.result; render(); }; r.readAsDataURL(file);
  } else if(id === 'videoInput' && file){ S.lf.file = file; render(); }
  else if(id === 'qrInput' && file){
    S.pf.qrFile = file;
    const r = new FileReader(); r.onload = () => { S.pf.qrPreview = r.result; render(); }; r.readAsDataURL(file);
  } else if(e.target.getAttribute && e.target.getAttribute('data-bind')){
    setBound(e.target.getAttribute('data-bind'), e.target.type === 'checkbox' ? e.target.checked : e.target.value);
  }
});
document.addEventListener('click', async (e) => {
  const el = e.target.closest('[data-act]');
  if(!el) return;
  const act = el.getAttribute('data-act'), id = el.getAttribute('data-id');
  switch(act){
    case 'back': back(); break;
    case 'theme': toggleTheme(); break;
    case 'signout': await sb.auth.signOut(); location.replace('login.html?next=teacher'); break;
    case 'go-courses': go('courses'); break;
    case 'go-students': go('students'); break;
    case 'go-earnings': go('earnings'); break;
    case 'go-profile': S.err = {}; S.ok = {}; go('profile'); break;
    case 'new-course': openCourse(null); break;
    case 'edit-course': openCourse(id); break;
    case 'open-codes': openCodes(id); break;
    case 'submit-review': submitReview(id); break;
    case 'delete-course': deleteCourse(id); break;
    case 'save-course': saveCourse(); break;
    case 'edit-points': openPoints(); break;
    case 'pick-thumb': $('#thumbInput').click(); break;
    case 'pick-video': $('#videoInput').click(); break;
    case 'pick-qr': $('#qrInput').click(); break;
    case 'add-lecture': addLecture(); break;
    case 'lec-up': moveLecture(id, -1); break;
    case 'lec-down': moveLecture(id, 1); break;
    case 'lec-del': deleteLecture(id); break;
    case 'add-code': addCode(); break;
    case 'stop-code': stopCode(id); break;
    case 'save-profile': saveProfile(); break;
  }
});

// ---------- start ----------
(async function init(){
  const { data: { session } } = await sb.auth.getSession();
  if(!session){ location.replace('login.html?next=teacher'); return; }
  S.user = session.user;
  const { data: prof } = await sb.from('profiles').select('is_teacher').eq('id', S.user.id).maybeSingle();
  if(!prof || !prof.is_teacher){ location.replace('login.html?next=teacher'); return; }
  await loadAll();
  S.ready = true;
  history.replaceState({ v: 'overview' }, '');
  render();
})();
})();
