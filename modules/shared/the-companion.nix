# the-companion - Web UI for Claude Code agents
# All WS stability fixes (RC1-RC10) merged upstream in 0.74.0.
# Only local patches: Catppuccin Mocha theme + Maple Mono NF font.
{ lib, buildNpmPackage, fetchurl, bun, makeWrapper, stdenv, maple-mono }:

let
  version = "0.93.0";

  base = buildNpmPackage {
    pname = "the-companion-base";
    inherit version;

    src = fetchurl {
      url = "https://registry.npmjs.org/the-companion/-/the-companion-${version}.tgz";
      hash = "sha256-0fKh7MYvf89LtrqwaJCzt5ko0gE8v0gI9sENOOmslU8=";
    };

    npmDepsHash = "sha256-tqMrVwtDvtmZwjNMoApTXL2+ETOLKxHt1eioUv4asrU=";

    unpackPhase = ''
      tar xzf $src --strip-components=1
    '';

    postPatch = ''
      cp ${./the-companion-package-lock.json} package-lock.json
    '';

    dontNpmBuild = true;
    npmInstallFlags = [ "--production" "--ignore-scripts" ];

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/the-companion
      cp -r . $out/lib/the-companion/
      runHook postInstall
    '';

    meta.description = "the-companion base (npm tarball)";
  };

in stdenv.mkDerivation {
  pname = "the-companion";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/the-companion

    # Symlink everything from npm base
    for f in ${base}/lib/the-companion/*; do
      ln -s "$f" $out/lib/the-companion/
    done

    # Copy bin/, server/, and dist/ so Bun resolves ../dist relative to
    # the real path of server/index.ts (not the symlink target in base).
    # Without this, Bun follows symlinks and serves the unpatched base dist/.
    # See RC6 in companion memory.
    for dir in bin server dist; do
      rm $out/lib/the-companion/$dir
      cp -r ${base}/lib/the-companion/$dir $out/lib/the-companion/$dir
      chmod -R u+w $out/lib/the-companion/$dir
    done

    # ── Bundle Maple Mono NF font (Chrome can't reliably load local() fonts on macOS) ──
    mkdir -p $out/lib/the-companion/dist/fonts
    for weight in Regular Bold Italic BoldItalic; do
      cp ${maple-mono.NF}/share/fonts/truetype/MapleMono-NF-$weight.ttf \
         $out/lib/the-companion/dist/fonts/
    done

    # ── Catppuccin Mocha theme overrides ──

    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail \
      '<meta name="theme-color" content="#d97757" />' \
      '<meta name="theme-color" content="#11111b" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="#eff1f5" media="(prefers-color-scheme: light)" />'

    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail '</head>' '    <style>
      .dark {
        --color-cc-bg: #1e1e2e;
        --color-cc-fg: #cdd6f4;
        --color-cc-card: #181825;
        --color-cc-primary: #cba6f7;
        --color-cc-primary-hover: #b4befe;
        --color-cc-user-bubble: #313244;
        --color-cc-border: #45475a40;
        --color-cc-muted: #a6adc8;
        --color-cc-sidebar: #11111b;
        --color-cc-input-bg: #181825;
        --color-cc-code-bg: #11111b;
        --color-cc-code-fg: #cdd6f4;
        --color-cc-hover: #cdd6f40a;
        --color-cc-active: #cdd6f412;
        --color-cc-success: #a6e3a1;
        --color-cc-error: #f38ba8;
        --color-cc-warning: #f9e2af;
      }
      .dark .diff-file-header { background: #313244; }
      .dark .diff-line-add { background: #a6e3a114; }
      .dark .diff-line-del { background: #f38ba814; }
      .dark .diff-word-add { background: #a6e3a133; }
      .dark .diff-word-del { background: #f38ba833; }
      @font-face {
        font-family: "Maple Mono NF";
        src: url("/fonts/MapleMono-NF-Regular.ttf") format("truetype");
        font-weight: 400;
        font-style: normal;
        font-display: swap;
      }
      @font-face {
        font-family: "Maple Mono NF";
        src: url("/fonts/MapleMono-NF-Bold.ttf") format("truetype");
        font-weight: 700;
        font-style: normal;
        font-display: swap;
      }
      @font-face {
        font-family: "Maple Mono NF";
        src: url("/fonts/MapleMono-NF-Italic.ttf") format("truetype");
        font-weight: 400;
        font-style: italic;
        font-display: swap;
      }
      @font-face {
        font-family: "Maple Mono NF";
        src: url("/fonts/MapleMono-NF-BoldItalic.ttf") format("truetype");
        font-weight: 700;
        font-style: italic;
        font-display: swap;
      }
      :root {
        --font-sans: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --font-mono: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
        --default-font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --default-mono-font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
      body { font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important; }
      code, pre, kbd, samp, .font-mono, [class*="monospace"] {
        font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
    </style>
  </head>'

    for cssfile in $out/lib/the-companion/dist/assets/index-*.css; do
      sed -i 's/#d97757/#cba6f7/g' "$cssfile"
    done

    for jsfile in $out/lib/the-companion/dist/assets/index-*.js; do
      sed -i 's/#141413/#1e1e2e/g' "$jsfile"
      sed -i "s/fontFamily:\"monospace\",fontSize:15/fontFamily:\"'Maple Mono NF', monospace\",fontSize:16/g" "$jsfile"
    done

    mkdir -p $out/bin
    makeWrapper ${bun}/bin/bun $out/bin/the-companion \
      --add-flags "$out/lib/the-companion/bin/cli.ts" \
      --set NODE_ENV production \
      --set BUN_RUNTIME_TRANSPILER_CACHE_PATH 0

    runHook postInstall
  '';

  meta = {
    description = "Web UI for launching and interacting with Claude Code agents";
    homepage = "https://github.com/The-Vibe-Company/companion";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "the-companion";
  };
}
