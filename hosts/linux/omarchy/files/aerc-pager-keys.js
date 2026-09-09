// SMOOTH THE WHEEL. terminal-browser only scrolls by pixel-precise deltas
// when a NATIVE SCROLL HELPER feeds it high-resolution events -- and that
// helper is a Swift file its build compiles ONLY on macOS
// (engine/crates/pixel-core/build.rs returns early off darwin; release.sh
// leaves NATIVE_SCROLL_HELPER empty on Linux). With no helper the wheel
// takes input.ts's wheelTick() path: Math.sign() times WHEEL_DETENT_PX,
// which is 120px on Linux against 40 on macOS. Every notch is one coarse
// 120px jump, which is what reads as a laggy, stuttering wheel -- and it is
// equally coarse however the browser is launched, which is why the same
// scroll through aerc and run directly measure identically.
//
// Nothing here can supply the helper, but the page can animate the jump:
// swallow the wheel event and ease the same distance over a few frames.
let target = null;
let raf = 0;
window.addEventListener("wheel", (e) => {
  if (e.ctrlKey) return;               // leave zoom alone
  e.preventDefault();
  e.stopPropagation();
  const from = window.scrollY;
  if (target === null) target = from;
  // deltaY arrives as the 120px detent; scale it to something a page reads
  // as a scroll rather than a leap.
  target = Math.max(
    0,
    Math.min(document.body.scrollHeight, target + e.deltaY * 0.55),
  );
  if (raf) return;
  const step = () => {
    const now = window.scrollY;
    const rest = target - now;
    if (Math.abs(rest) < 1) {
      window.scrollTo({ top: target, behavior: "instant" });
      raf = 0;
      target = null;
      return;
    }
    window.scrollTo({ top: now + rest * 0.28, behavior: "instant" });
    raf = requestAnimationFrame(step);
  };
  raf = requestAnimationFrame(step);
}, { passive: false, capture: true });

// Capture phase, so a page that handles its own keys does not swallow these.
window.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  const line = Math.max(40, Math.round(window.innerHeight * 0.12));
  const half = Math.round(window.innerHeight * 0.5);
  let dy = null;
  let abs = null;
  switch (e.key) {
    case "j": dy = line; break;
    case "k": dy = -line; break;
    case "d": dy = half; break;
    case "u": dy = -half; break;
    case "g": abs = 0; break;
    case "G": abs = document.body.scrollHeight; break;
    // q closes the window. terminal-browser's own "q" shortcut does not
    // reach it once a page is focused -- reported as "q doesn't work", and
    // Ctrl-q does nothing either -- so bind it here, in the same capture
    // phase as the pager keys, and call the documented API:
    // globalThis.terminalBrowser.quit().
    case "q":
      e.preventDefault();
      e.stopPropagation();
      globalThis.terminalBrowser?.quit?.();
      return;
    default: return;
  }
  if (abs !== null) {
    window.scrollTo({ top: abs, behavior: "instant" });
  } else {
    window.scrollBy({ top: dy, behavior: "instant" });
  }
  e.preventDefault();
  e.stopPropagation();
}, true);
