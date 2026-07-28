// ==UserScript==
// @name         LSEG Workspace — hide unsupported-browser banner
// @namespace    https://github.com/edwinhu/nix
// @version      1.0.0
// @description  Hide Workspace Web's permanent "BROWSER NOT SUPPORTED" strip on Chromium.
// @match        https://workspace.refinitiv.com/*
// @run-at       document-start
// @all-frames   true
// @grant        GM_addStyle
// ==/UserScript==

/* Workspace Web renders a 44px warning strip because Chromium is not on LSEG's
 * supported-browser list. The sniff is navigator.userAgentData.brands (empty on
 * Chromium); the UA string itself already reports Chrome/150, so no UA override
 * clears it. Everything works behind it, CodeBook kernels included.
 *
 * Scoped to .unsupported-browser, NOT .thin-banner — the same banner system
 * carries BREAKING NEWS and alerts, which must keep working.
 *
 * @all-frames matters: the strip lives in the same-origin
 * /rap/webcontainer/<ver>/thin.htm child frame, not the top document.
 */
(function () {
  'use strict';
  const css = '.thin-banner.unsupported-browser { display: none !important; }';
  if (typeof GM_addStyle === 'function') { GM_addStyle(css); return; }
  const s = document.createElement('style');
  s.textContent = css;
  (document.head || document.documentElement).appendChild(s);
})();
