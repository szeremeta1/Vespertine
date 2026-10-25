/* Vespertine site: link events for the self-hosted Umami at stats.szeremeta.org. No cookies, no storage, no personal data.
 * One delegated listener turns clicks on links into named events, so every App Store, download, GitHub and
 * outbound link is counted without per-link markup:
 *   app-store-click   apps.apple.com / itunes.apple.com        {placement, ct, locale}
 *   testflight-click  testflight.apple.com                     {placement, locale}
 *   download          release assets and files (.dmg .zip ...)  {file, version, placement, locale}
 *   github-click      other github.com links                   {kind, placement, locale}
 *   email-click       mailto: (no address recorded)            {placement, locale}
 *   outbound-click    any other external host                  {host, placement, locale}
 *   brew-copy         the Copy button next to the Homebrew command {placement, locale}
 * placement = the nearest [data-placement], else the enclosing header / nav / footer / main.
 */
(function () {
  var FILE = /\.(dmg|pkg|zip|ipa|apk|exe|msi|pdf|csv|xlsx|docx|mp3|mp4)$/i;

  function placement(a) {
    var p = a.closest("[data-placement]");
    if (p) return p.getAttribute("data-placement");
    var r = a.closest("header,nav,footer,main");
    return r ? r.tagName.toLowerCase() : "page";
  }

  function classify(a) {
    var u;
    try { u = new URL(a.href, location.href); } catch (e) { return null; }
    var where = placement(a);
    var data = { placement: where, locale: document.documentElement.lang || "" };
    if (u.protocol === "mailto:") return ["email-click", data];
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    var file = u.pathname.split("/").pop();
    var external = u.hostname !== location.hostname;
    if (/(^|\.)(apps|itunes)\.apple\.com$/.test(u.hostname)) {
      data.ct = u.searchParams.get("ct") || "";
      return ["app-store-click", data];
    }
    if (u.hostname === "testflight.apple.com") return ["testflight-click", data];
    if (/\/releases\/download\//.test(u.pathname) || FILE.test(file)) {
      data.file = file;
      var v = file.match(/(\d+\.\d+(?:\.\d+)*)/);
      if (v) data.version = v[1];
      return ["download", data];
    }
    if (/(^|\.)github\.com$/.test(u.hostname)) {
      data.kind = /\/releases/.test(u.pathname) ? "release" : /\/issues/.test(u.pathname) ? "issues" : /\/blob\/|\/tree\//.test(u.pathname) ? "docs" : "repo";
      return ["github-click", data];
    }
    if (external) {
      data.host = u.hostname;
      return ["outbound-click", data];
    }
    return null;
  }

  function onClick(e) {
    if (!window.umami || !e.target || !e.target.closest) return;
    var copy = e.target.closest("button[data-copy]");
    if (copy) { window.umami.track("brew-copy", { placement: placement(copy), locale: document.documentElement.lang || "" }); return; }
    var a = e.target.closest("a[href]");
    if (!a || a.hasAttribute("data-umami-event")) return; // an explicit data-umami-event wins
    if (e.type === "auxclick" && e.button !== 1) return; // middle click only
    var hit = classify(a);
    if (hit) window.umami.track(hit[0], hit[1]);
  }

  document.addEventListener("click", onClick, true);
  document.addEventListener("auxclick", onClick, true);
})();
