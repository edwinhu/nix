#!/usr/bin/env python3
"""Rebuild the Tampermonkey provisioning bundle and its hash.

Tampermonkey's `jsonImport` managed policy (see hosts/linux/omarchy/default.nix)
takes {url, hash}. The hash is not a checksum of the file bytes -- it is computed
over the PARSED JSON, so whitespace and key order in the served file don't matter:

    leaf   -> sha256("<typeof>:<value>")     e.g. sha256("string:// ==UserScript==...")
    array  -> sha256(concat(hash(child) for child in array))
    object -> sha256(concat(hash(value) for key in sorted(keys)))   # keys NOT hashed

Prefixed "1:" for the format version. Verified against Tampermonkey 5.5.0's
background.js (functions No/Do) and against what GitHub actually serves.

Usage:  ./tampermonkey-provisioning-hash.py script1.user.js script2.user.js ...
"""
import base64, hashlib, json, sys, pathlib

SCRIPT_URLS = {
    "lseg-workspace-banner.user.js":
        "https://gist.githubusercontent.com/edwinhu/14c99c2fba85dc519b837c6281506332/raw/lseg-workspace-banner.user.js",
    "vitalsource-readwise-sync.user.js":
        "https://gist.githubusercontent.com/edwinhu/100a4adf3665aa10831a20357d340721/raw/vitalsource-readwise-sync.user.js",
    "casebookconnect-readwise-sync.user.js":
        "https://gist.githubusercontent.com/edwinhu/267354686b69f2c1be81027e786259fd/raw/casebookconnect-readwise-sync.user.js",
}

def _h(x: str) -> str:
    return hashlib.sha256(x.encode("utf-8")).hexdigest()

def tm_hash(v) -> str:
    if v is None:                   return _h("object:null")
    if isinstance(v, bool):         return _h("boolean:" + ("true" if v else "false"))
    if isinstance(v, str):          return _h("string:" + v)
    if isinstance(v, (int, float)): return _h("number:" + repr(v))
    if isinstance(v, list):         return _h("".join(tm_hash(e) for e in v))
    if isinstance(v, dict):         return _h("".join(tm_hash(v[k]) for k in sorted(v)))
    raise TypeError(f"unsupported: {type(v)}")

def main(paths):
    scripts = []
    for p in paths:
        f = pathlib.Path(p)
        url = SCRIPT_URLS.get(f.name)
        if not url:
            sys.exit(f"no @updateURL known for {f.name}; add it to SCRIPT_URLS")
        # source MUST be base64 of the UTF-8 bytes. Tampermonkey does
        #   decodeURIComponent(escape(atob(source)))
        # and that atob() sits OUTSIDE the installer's try/catch, so raw text
        # throws InvalidCharacterError, kills the extension's init as an uncaught
        # rejection, and provisioning dies silently after "start downloading".
        scripts.append({"file_url": url,
                        "source": base64.b64encode(f.read_bytes()).decode("ascii")})
    bundle = {"version": "1", "scripts": scripts}
    out = pathlib.Path("tampermonkey-provisioning.json")
    out.write_text(json.dumps(bundle, indent=2))
    print(f"wrote {out} ({len(scripts)} scripts)")
    print(f'hash: 1:{tm_hash(bundle)}')
    print("\nUpload the JSON to its gist, then put the hash in "
          "hosts/linux/omarchy/files/chromium-tampermonkey-policy.json")
    print("NOTE: the gist RAW url is CDN-cached for 5 minutes. Verify the update "
          "landed with `gh api gists/<id>` rather than curling the raw url.")

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    main(sys.argv[1:])
