# the-companion - Web UI for Claude Code agents
# npm package that requires bun as runtime
# Dependencies managed via buildNpmPackage (package-lock.json + npmDepsHash)
{ lib, buildNpmPackage, fetchurl, bun, makeWrapper }:

let
  version = "0.61.0";
in buildNpmPackage {
  pname = "the-companion";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/the-companion/-/the-companion-${version}.tgz";
    hash = "sha256-rhCQ15WgaGM0eP2JabujvkZ9I+i4NfPy0abXBczU7wA=";
  };

  npmDepsHash = "sha256-m7g8YvhT5KQRKHxiQONjarW472/fDnV0DFOJOXrQ3eQ=";

  unpackPhase = ''
    tar xzf $src --strip-components=1
  '';

  postPatch = ''
    cp ${./the-companion-package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;
  npmInstallFlags = [ "--production" "--ignore-scripts" ];

  # Override the default install phase (which uses npm pack + npm install -g)
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/the-companion
    cp -r . $out/lib/the-companion/

    # Make writable so substituteInPlace can modify in place
    chmod -R u+w $out/lib/the-companion/dist

    # Replace upstream orange theme-color with Catppuccin Mocha Crust
    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail \
      '<meta name="theme-color" content="#d97757" />' \
      '<meta name="theme-color" content="#11111b" media="(prefers-color-scheme: dark)" />
    <meta name="theme-color" content="#eff1f5" media="(prefers-color-scheme: light)" />'

    # Inject Catppuccin Mocha theme overrides into index.html
    substituteInPlace $out/lib/the-companion/dist/index.html \
      --replace-fail '</head>' '    <style>
      /* Catppuccin Mocha theme override */
      .dark {
        --color-cc-bg: #1e1e2e;        /* Base */
        --color-cc-fg: #cdd6f4;        /* Text */
        --color-cc-card: #181825;      /* Mantle */
        --color-cc-primary: #cba6f7;   /* Mauve */
        --color-cc-primary-hover: #b4befe; /* Lavender */
        --color-cc-user-bubble: #313244; /* Surface0 */
        --color-cc-border: #45475a40;  /* Surface1 + alpha */
        --color-cc-muted: #a6adc8;     /* Subtext0 */
        --color-cc-sidebar: #11111b;   /* Crust */
        --color-cc-input-bg: #181825;  /* Mantle */
        --color-cc-code-bg: #11111b;   /* Crust */
        --color-cc-code-fg: #cdd6f4;   /* Text */
        --color-cc-hover: #cdd6f40a;
        --color-cc-active: #cdd6f412;
        --color-cc-success: #a6e3a1;   /* Green */
        --color-cc-error: #f38ba8;     /* Red */
        --color-cc-warning: #f9e2af;   /* Yellow */
      }
      .dark .diff-file-header { background: #313244; }
      .dark .diff-line-add { background: #a6e3a114; }
      .dark .diff-line-del { background: #f38ba814; }
      .dark .diff-word-add { background: #a6e3a133; }
      .dark .diff-word-del { background: #f38ba833; }
      /* Maple Mono NF everywhere */
      :root {
        --font-sans: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --font-mono: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
        --default-font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
        --default-mono-font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
      body {
        font-family: "Maple Mono NF", ui-sans-serif, system-ui, sans-serif !important;
      }
      code, pre, kbd, samp, .font-mono, [class*="monospace"] {
        font-family: "Maple Mono NF", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
      }
    </style>
  </head>'

    # Replace hardcoded orange accent (#d97757) with Catppuccin Mauve in CSS
    for cssfile in $out/lib/the-companion/dist/assets/index-*.css; do
      sed -i 's/#d97757/#cba6f7/g' "$cssfile"
    done

    # Patch terminal dark-mode background to Catppuccin Mocha Base
    for jsfile in $out/lib/the-companion/dist/assets/index-*.js; do
      sed -i 's/#141413/#1e1e2e/g' "$jsfile"
      # Set terminal font to Maple Mono NF at 16px
      sed -i "s/fontFamily:\"monospace\",fontSize:15/fontFamily:\"'Maple Mono NF', monospace\",fontSize:16/g" "$jsfile"
    done

    mkdir -p $out/bin
    makeWrapper ${bun}/bin/bun $out/bin/the-companion \
      --add-flags "$out/lib/the-companion/bin/cli.ts" \
      --set NODE_ENV production

    runHook postInstall
  '';

  nativeBuildInputs = [ makeWrapper ];

  meta = {
    description = "Web UI for launching and interacting with Claude Code agents";
    homepage = "https://github.com/The-Vibe-Company/companion";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "the-companion";
  };
}
