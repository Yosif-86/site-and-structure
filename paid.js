// Landing page after a Wayl payment (redirectionUrl). Wayl appends
// referenceId and orderid; the server confirms the payment with Wayl
// itself before the course is turned on, so this page only reports.
(function () {
  var params = new URLSearchParams(location.search);
  var ref = params.get('referenceId') || params.get('ref') || '';
  var title = document.getElementById('payTitle');
  var text = document.getElementById('payText');
  var openApp = document.getElementById('openApp');

  function show(t, s, app) {
    title.textContent = t;
    text.textContent = s;
    openApp.style.display = app ? "" : "none";
  }

  if (!/^arc_[0-9a-f-]{36}$/i.test(ref)) {
    show('لم نجد عملية دفع', 'افتح التطبيق وتحقق من دوراتك.', true);
    return;
  }

  var tries = 0;
  function check() {
    tries += 1;
    fetch('/api/wayl-webhook?ref=' + encodeURIComponent(ref))
      .then(function (r) { return r.json().catch(function () { return {}; }); })
      .then(function (j) {
        if (j.status === 'paid') {
          show('تم الدفع بنجاح ✅', 'تم تفعيل الدورة على حسابك. افتح التطبيق وابدأ التعلم.', true);
        } else if (j.status === 'failed') {
          show('لم تكتمل عملية الدفع', 'لم يُخصم أي مبلغ. يمكنك المحاولة مرة أخرى من التطبيق.', true);
        } else if (tries < 12) {
          setTimeout(check, 2500);
        } else {
          show('الدفع قيد المعالجة', 'إذا خُصم المبلغ ستتفعّل الدورة خلال دقائق، وسيصلك إشعار.', true);
        }
      })
      .catch(function () {
        if (tries < 12) setTimeout(check, 2500);
        else show('تعذّر التحقق الآن', 'إذا خُصم المبلغ ستتفعّل الدورة خلال دقائق، وسيصلك إشعار.', true);
      });
  }
  check();
})();
