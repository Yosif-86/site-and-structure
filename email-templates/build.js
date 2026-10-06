// Builds the Supabase Auth email templates (Arabic, Arc branding) into
// email-templates/*.html. Paste each file into Supabase: Authentication,
// Emails, Templates (subject from SUBJECTS below).
// Run: node email-templates/build.js

const fs = require('fs');
const path = require('path');

const LOGO = 'https://arcplatformiq.com/email-logo.png';
const SITE = 'https://arcplatformiq.com';
const SUPPORT = 'support@arcplatformiq.com';

const ORANGE = '#E8622C';
const INK = '#14120F';
const TEXT = '#2B2722';
const MUTED = '#7A726A';

function layout({ title, intro, button, link, code, note }) {
  const btn = button
    ? `<tr><td align="center" style="padding:8px 0 24px">
         <a href="${link}" style="display:inline-block;background:${ORANGE};color:#ffffff;text-decoration:none;font-weight:bold;font-size:16px;padding:14px 32px;border-radius:10px">${button}</a>
       </td></tr>`
    : '';
  const codeBox = code
    ? `<tr><td align="center" style="padding:4px 0 24px">
         <div dir="ltr" style="display:inline-block;background:#FFF4EC;border:1px solid #F3C9B2;color:${INK};font-family:Consolas,'Courier New',monospace;font-size:30px;font-weight:bold;letter-spacing:8px;padding:14px 26px;border-radius:10px">${code}</div>
       </td></tr>`
    : '';
  const fallback = button
    ? `<tr><td style="padding:0 0 18px;font-size:13px;line-height:1.8;color:${MUTED}">
         إذا لم يعمل الزر، انسخ هذا الرابط والصقه في المتصفح:<br>
         <a href="${link}" dir="ltr" style="color:${ORANGE};word-break:break-all">${link}</a>
       </td></tr>`
    : '';
  return `<!doctype html>
<html lang="ar" dir="rtl">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title></head>
<body style="margin:0;padding:0;background:#F4F1EC">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F1EC">
  <tr><td align="center" style="padding:28px 12px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" dir="rtl" style="max-width:520px;background:#ffffff;border-radius:16px;overflow:hidden;font-family:Tahoma,Arial,sans-serif;text-align:right">
      <tr><td align="center" style="background:${INK};padding:22px 16px">
        <img src="${LOGO}" width="72" height="72" alt="منصة آرك" style="display:block;border:0;border-radius:14px">
      </td></tr>
      <tr><td style="padding:28px 28px 8px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          <tr><td style="font-size:21px;font-weight:bold;color:${INK};padding:0 0 12px">${title}</td></tr>
          <tr><td style="font-size:15px;line-height:1.9;color:${TEXT};padding:0 0 20px">${intro}</td></tr>
          ${codeBox}
          ${btn}
          ${fallback}
          <tr><td style="font-size:13px;line-height:1.8;color:${MUTED};padding:0 0 22px">${note}</td></tr>
        </table>
      </td></tr>
      <tr><td style="background:#FAF8F5;border-top:1px solid #EEE9E2;padding:16px 28px;font-size:12px;line-height:1.8;color:${MUTED};text-align:center">
        منصة آرك · Arc Platform<br>
        <a href="${SITE}" style="color:${MUTED}">arcplatformiq.com</a> · للمساعدة: <a href="mailto:${SUPPORT}" style="color:${MUTED}">${SUPPORT}</a>
      </td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>
`;
}

const IGNORE = 'إذا لم تطلب هذا، تجاهل هذه الرسالة ولن يتغير شيء في حسابك.';

const TEMPLATES = {
  'confirm-signup': {
    subject: 'تأكيد بريدك الإلكتروني في منصة آرك',
    html: layout({
      title: 'أهلاً بك في منصة آرك',
      intro: 'شكراً لتسجيلك. اضغط الزر أدناه لتأكيد بريدك الإلكتروني وتفعيل حسابك.',
      button: 'تأكيد البريد الإلكتروني',
      link: '{{ .ConfirmationURL }}',
      note: IGNORE,
    }),
  },
  'invite': {
    subject: 'دعوة للانضمام إلى منصة آرك',
    html: layout({
      title: 'لديك دعوة إلى منصة آرك',
      intro: 'تمت دعوتك لإنشاء حساب في منصة آرك. اضغط الزر أدناه لقبول الدعوة.',
      button: 'قبول الدعوة',
      link: '{{ .ConfirmationURL }}',
      note: 'إذا لم تكن تتوقع هذه الدعوة، يمكنك تجاهل الرسالة.',
    }),
  },
  'magic-link': {
    subject: 'رمز تسجيل الدخول إلى منصة آرك',
    html: layout({
      title: 'رمز تسجيل الدخول',
      intro: 'استخدم هذا الرمز لإكمال تسجيل الدخول. الرمز صالح لفترة قصيرة ولا تشاركه مع أحد.',
      code: '{{ .Token }}',
      note: IGNORE + ' إذا وصلك هذا الرمز دون أن تحاول الدخول، غيّر كلمة المرور.',
    }),
  },
  'change-email': {
    subject: 'تأكيد تغيير البريد الإلكتروني في منصة آرك',
    html: layout({
      title: 'تأكيد البريد الإلكتروني الجديد',
      intro: 'طلبت تغيير بريد حسابك من <span dir="ltr">{{ .Email }}</span> إلى <span dir="ltr">{{ .NewEmail }}</span>. اضغط الزر أدناه لتأكيد التغيير.',
      button: 'تأكيد التغيير',
      link: '{{ .ConfirmationURL }}',
      note: IGNORE,
    }),
  },
  'reset-password': {
    subject: 'إعادة تعيين كلمة المرور في منصة آرك',
    html: layout({
      title: 'إعادة تعيين كلمة المرور',
      intro: 'وصلنا طلب لإعادة تعيين كلمة مرور حسابك. اضغط الزر أدناه لاختيار كلمة مرور جديدة.',
      button: 'إعادة تعيين كلمة المرور',
      link: '{{ .ConfirmationURL }}',
      note: IGNORE,
    }),
  },
  'reauthentication': {
    subject: 'رمز التحقق من منصة آرك',
    html: layout({
      title: 'رمز التحقق',
      intro: 'أدخل هذا الرمز لتأكيد العملية.',
      code: '{{ .Token }}',
      note: IGNORE,
    }),
  },
};

const out = __dirname;
for (const [name, t] of Object.entries(TEMPLATES)) {
  fs.writeFileSync(path.join(out, `${name}.html`), t.html);
}
fs.writeFileSync(path.join(out, 'subjects.json'),
  JSON.stringify(Object.fromEntries(Object.entries(TEMPLATES).map(([k, t]) => [k, t.subject])), null, 2) + '\n');
console.log('built', Object.keys(TEMPLATES).join(', '));
