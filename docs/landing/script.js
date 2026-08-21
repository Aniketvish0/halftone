/* Halftone landing. theme toggle, scroll-shrink fallback, shot reveals. */
(function () {
  "use strict";

  var root = document.documentElement;
  var THEMES = ["day", "afternoon", "night"];
  var STORAGE_KEY = "halftone-theme";
  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- Theme ---------- */

  function systemTheme() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "night" : "day";
  }

  function applyTheme(theme, persist) {
    if (THEMES.indexOf(theme) === -1) theme = systemTheme();
    root.setAttribute("data-theme", theme);
    if (persist) {
      try { localStorage.setItem(STORAGE_KEY, theme); } catch (e) { /* private mode */ }
    }
    document.querySelectorAll(".theme-toggle button").forEach(function (btn) {
      btn.setAttribute("aria-pressed", String(btn.dataset.setTheme === theme));
    });
  }

  var stored = null;
  try { stored = localStorage.getItem(STORAGE_KEY); } catch (e) { /* private mode */ }
  applyTheme(stored || systemTheme(), false);

  document.querySelectorAll(".theme-toggle button").forEach(function (btn) {
    btn.addEventListener("click", function () {
      applyTheme(btn.dataset.setTheme, true);
    });
  });

  // Follow OS changes only while the user hasn't chosen explicitly.
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
    var chosen = null;
    try { chosen = localStorage.getItem(STORAGE_KEY); } catch (e) {}
    if (!chosen) applyTheme(systemTheme(), false);
  });

  /* ---------- Scroll-shrink fallback ---------- */
  // Native CSS scroll-driven animation is used when supported; otherwise
  // drive the same transform/opacity curve from rAF-throttled scroll events.

  var supportsScrollTimeline =
    typeof CSS !== "undefined" &&
    CSS.supports &&
    CSS.supports("animation-timeline: scroll()");

  var frame = document.getElementById("hero-frame");

  if (frame && !supportsScrollTimeline && !reducedMotion) {
    frame.classList.add("js-shrink");
    var ticking = false;

    var update = function () {
      ticking = false;
      var range = window.innerHeight * 0.62;
      var t = Math.min(Math.max(window.scrollY / range, 0), 1);
      frame.style.setProperty("--shrink-scale", String(1 - 0.07 * t));
      frame.style.setProperty("--shrink-radius", (24 * t).toFixed(1) + "px");
      frame.style.setProperty("--shrink-opacity", String(1 - 0.12 * t));
    };

    window.addEventListener("scroll", function () {
      if (!ticking) {
        ticking = true;
        window.requestAnimationFrame(update);
      }
    }, { passive: true });

    update();
  }

  /* ---------- Screenshot reveals ---------- */

  var shots = document.querySelectorAll(".shot");

  if (reducedMotion || !("IntersectionObserver" in window)) {
    shots.forEach(function (el) { el.classList.add("in"); });
  } else {
    var seen = 0;
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          // Small stagger when several enter at once.
          var delay = Math.min(seen++ % 3, 2) * 90;
          var el = entry.target;
          setTimeout(function () { el.classList.add("in"); }, delay);
          io.unobserve(el);
        }
      });
    }, { rootMargin: "0px 0px -10% 0px", threshold: 0.15 });

    shots.forEach(function (el) { io.observe(el); });
  }
})();
