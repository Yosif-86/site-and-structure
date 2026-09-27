// Signup field rules, shared by index.html, course.html and
// reset-password.html. Mirrors mobile_app/lib/services/signup_rules.dart and
// is enforced again in the database (add-signup-validation.sql) and by the
// Supabase Auth password policy -- this copy only gives a clear message early.
// Loaded as a separate file (script-src 'self') so it needs no CSP hash.
(function(){
  // Allowlist, not a temp-mail blocklist: new disposable domains appear
  // daily, known providers don't. *.edu.iq university addresses are allowed.
  const ALLOWED_EMAIL_DOMAINS = [
    'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com',
    'msn.com', 'yahoo.com', 'ymail.com', 'icloud.com', 'me.com', 'mac.com',
    'proton.me', 'protonmail.com', 'aol.com'
  ];

  function isValidEmailShape(email){
    return /^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$/.test(String(email || '').trim());
  }

  function isAllowedEmailDomain(email){
    const e = String(email || '').trim();
    const at = e.lastIndexOf('@');
    if(at < 0) return false;
    const domain = e.slice(at + 1).toLowerCase();
    return ALLOWED_EMAIL_DOMAINS.includes(domain) || domain.endsWith('.edu.iq');
  }

  // 8+ chars with an uppercase letter, a lowercase letter and a digit.
  function isStrongPassword(p){
    p = String(p || '');
    return p.length >= 8 && /[A-Z]/.test(p) && /[a-z]/.test(p) && /[0-9]/.test(p);
  }

  // Returns 07XXXXXXXXX (11 digits) or null. Accepts spaces/dashes,
  // Arabic-Indic digits and +964 / 00964 / 964 forms.
  // 075 Korek, 077 Asiacell, 078/079 Zain.
  function normalizeIraqiPhone(raw){
    let d = String(raw || '')
      .replace(/[٠-٩]/g, c => String(c.charCodeAt(0) - 0x0660))
      .replace(/[۰-۹]/g, c => String(c.charCodeAt(0) - 0x06F0))
      .replace(/[^0-9]/g, '');
    if(d.startsWith('00964')) d = '0' + d.slice(5);
    if(d.startsWith('964')) d = '0' + d.slice(3);
    if(d.length === 10 && d.startsWith('7')) d = '0' + d;
    return /^07[5789][0-9]{8}$/.test(d) ? d : null;
  }

  window.SignupRules = { isValidEmailShape, isAllowedEmailDomain, isStrongPassword, normalizeIraqiPhone };
})();
