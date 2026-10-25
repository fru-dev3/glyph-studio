// Pre-bundle error net — shows fatal boot/render errors instead of a blank
// window before main.tsx loads. External (not inline) so the CSP can keep a
// strict script-src 'self' (no 'unsafe-inline').
(function () {
  function dump(msg) {
    var el = document.getElementById("root") || document.body;
    if (el)
      el.innerHTML =
        '<pre style="white-space:pre-wrap;padding:20px;margin:0;font:12px ui-monospace,Menlo,monospace;color:#b3261e;background:#faf8f1;height:100vh;overflow:auto">Glyph Studio hit an error:\n\n' +
        String(msg).replace(/</g, "&lt;") +
        "</pre>";
  }
  window.addEventListener("error", function (e) {
    dump((e.error && (e.error.stack || e.error.message)) || e.message || "error");
  });
  window.addEventListener("unhandledrejection", function (e) {
    dump("Unhandled rejection:\n" + ((e.reason && (e.reason.stack || e.reason.message)) || e.reason));
  });
})();
