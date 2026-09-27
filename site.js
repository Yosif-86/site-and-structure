// Shared script for the public pages. External file (script-src 'self'), so
// editing it never needs a CSP hash update in vercel.json.

// TODO(Yosif): fill these in at launch. Left empty on purpose: an empty
// store link shows "coming soon", an empty contact hides that contact,
// so nothing ships pointing at a wrong or dead address.
const PLAY_STORE_URL = '';
const APP_STORE_URL = '';
const SUPPORT_EMAIL = '';
const SUPPORT_WHATSAPP = ''; // Iraqi format, e.g. 07XXXXXXXXX

(function(){
  // Password-reset emails that fall back to the Site URL land here with the
  // recovery token in the hash; hand them to the page that can use it.
  if(/(^|[#&])type=recovery(&|$)/.test(location.hash)){
    location.replace('/reset-password.html' + location.hash);
    return;
  }

  function setStore(id, url){
    const el = document.getElementById(id);
    if(!el) return;
    if(url){
      el.href = url;
      el.removeAttribute('aria-disabled');
      const soon = el.querySelector('[data-soon]');
      if(soon) soon.textContent = soon.getAttribute('data-ready');
    }
  }
  setStore('playLink', PLAY_STORE_URL);
  setStore('appStoreLink', APP_STORE_URL);

  function whatsappUrl(phone){
    let d = String(phone).replace(/[^0-9]/g, '');
    if(d.startsWith('0')) d = '964' + d.slice(1);
    return 'https://wa.me/' + d;
  }
  document.querySelectorAll('[data-contact="email"]').forEach(el => {
    if(!SUPPORT_EMAIL) return;
    el.hidden = false;
    const a = el.tagName === 'A' ? el : el.querySelector('a');
    if(a) a.href = 'mailto:' + SUPPORT_EMAIL;
    const v = el.querySelector('[data-value]');
    if(v) v.textContent = SUPPORT_EMAIL;
  });
  document.querySelectorAll('[data-contact="whatsapp"]').forEach(el => {
    if(!SUPPORT_WHATSAPP) return;
    el.hidden = false;
    const a = el.tagName === 'A' ? el : el.querySelector('a');
    if(a){ a.href = whatsappUrl(SUPPORT_WHATSAPP); a.target = '_blank'; a.rel = 'noopener'; }
    const v = el.querySelector('[data-value]');
    if(v) v.textContent = SUPPORT_WHATSAPP;
  });
  // Blocks that only make sense when at least one contact exists.
  if(SUPPORT_EMAIL || SUPPORT_WHATSAPP){
    document.querySelectorAll('[data-if-contact]').forEach(el => { el.hidden = false; });
    document.querySelectorAll('[data-if-no-contact]').forEach(el => { el.hidden = true; });
  }

  const y = document.getElementById('year');
  if(y) y.textContent = new Date().getFullYear();
})();
