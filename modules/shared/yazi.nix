# yazi: previewers for tabular data and notebooks, plus fuzzy search.
#
# Two of the three plugins come from nixpkgs' `yaziPlugins` rather than a
# hand-rolled source pin — duckdb is packaged there at upstream's current main
# (3f8c8633, 2025-05-29; upstream has not moved since), rich-preview at
# 2026-02-11. That is an attribute reference instead of a hash to maintain.
#
#   duckdb        — csv/tsv/parquet/xlsx and duckdb databases, rendered as
#                   tables by the duckdb engine itself.
#   rich-preview  — Jupyter notebooks and reStructuredText, via rich-cli.
#   fazif         — fd/ripgrep/rga searches piped through fzf, bound under `b`.
#
# rich-preview, not nbpreview.yazi: neither nbpreview's plugin nor the
# `nbpreview` CLI it shells out to is in nixpkgs, so adopting it would mean
# packaging a PyPI application in order to cover strictly fewer file types.
{ pkgs, ... }:
let
  # rich-preview IS in nixpkgs, but pinned at 2026-02-11 — two commits behind
  # upstream, and one of them is "Fix orphaned rich process and overly-aggressive
  # stderr fallback". A leaked `rich` per preview is worth not shipping, so this
  # overrides the packaged source rather than waiting for nixpkgs to catch up.
  # Drop this and go back to pkgs.yaziPlugins.rich-preview once nixpkgs is past
  # 2026-08-07.
  richPreview = pkgs.yaziPlugins.rich-preview.overrideAttrs (_: {
    version = "0-unstable-2026-08-07";
    src = pkgs.fetchFromGitHub {
      owner = "AnirudhG07";
      repo = "rich-preview.yazi";
      rev = "02597c4a129a36e3ab013b1fd052cf0f555d5490";
      hash = "sha256-8QfBzKyNmKFxwtOmhhpnxUZBRmrN3mPWV/n/0MZlsYo=";
    };
  });

  # fazif is not in nixpkgs, so this is the one source pin here.
  #
  # Three of its four scripts are `#!/usr/bin/env zsh` (faziffdr is `sh`), and
  # zsh was not installed on this host — without it every binding dies with
  # `env: zsh: No such file or directory`. zsh is therefore added to
  # home.packages below. The scripts resolve fd/rg/rga/fzf/bat/eza from PATH
  # themselves; all six are already in modules/shared/packages.nix.
  fazif = pkgs.stdenvNoCC.mkDerivation {
    pname = "fazif.yazi";
    version = "0-unstable-2026-08-22";

    src = pkgs.fetchFromGitHub {
      owner = "Shallow-Seek";
      repo = "fazif.yazi";
      rev = "7f05d7bbf81ae3656555ab917ec3e9630e4ead03";
      hash = "sha256-PC+skIire/oxIffci18wX1af14qQex/nQ4iiB7gd22Q=";
    };

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r main.lua faziffd faziffdr fazifrg fazifrga $out/
      chmod +x $out/faziffd $out/faziffdr $out/fazifrg $out/fazifrga
      runHook postInstall
    '';

    # main.lua:33 builds the script path from $HOME, not from its own location,
    # so the scripts have to be reachable at
    # ~/.config/yazi/plugins/fazif.yazi/<name> and executable there. The
    # xdg.configFile symlink below satisfies that; this check only proves the
    # derivation itself shipped them runnable.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      for s in faziffd faziffdr fazifrg fazifrga; do
        [ -x "$out/$s" ] || { echo "fazif: $s is not executable" >&2; exit 1; }
      done
      runHook postInstallCheck
    '';
  };
in
{
  home.packages = [
    pkgs.duckdb # the engine duckdb.yazi drives
    pkgs.rich-cli # ditto for rich-preview
    pkgs.zsh # fazif's scripts are `#!/usr/bin/env zsh`; not a login shell here
  ];

  xdg.configFile = {
    "yazi/plugins/duckdb.yazi".source = pkgs.yaziPlugins.duckdb;
    "yazi/plugins/rich-preview.yazi".source = richPreview;
    "yazi/plugins/fazif.yazi".source = fazif;

    # duckdb.yazi requires an explicit setup call; the other two need none.
    "yazi/init.lua".text = ''
      require("duckdb"):setup()
    '';

    # `url =` is the glob key current yazi expects. duckdb.yazi's README still
    # documents `name =`, which matches nothing on yazi 26.x and makes the
    # plugin look broken rather than misconfigured.
    #
    # The extension split is deliberate and is NOT what either README proposes:
    #   * duckdb's README also claims `*.txt`, which would route every plain
    #     text file through a SQL engine. Dropped.
    #   * `*.json` and `*.md` are claimed by BOTH previewers. They are left to
    #     yazi's own, which already handles them; moving one line between the
    #     lists below is how to change that.
    "yazi/yazi.toml".text = ''
      [plugin]
      prepend_previewers = [
        { url = "*.csv",     run = "duckdb" },
        { url = "*.tsv",     run = "duckdb" },
        { url = "*.parquet", run = "duckdb" },
        { url = "*.xlsx",    run = "duckdb" },
        { url = "*.db",      run = "duckdb" },
        { url = "*.duckdb",  run = "duckdb" },

        { url = "*.ipynb",   run = "rich-preview" },
        { url = "*.rst",     run = "rich-preview" },
      ]

      # Preloading is what makes a large csv paint without a visible stall.
      # Only the formats duckdb reads off disk; multi = false because each
      # preload opens its own connection.
      prepend_preloaders = [
        { url = "*.csv",     run = "duckdb", multi = false },
        { url = "*.tsv",     run = "duckdb", multi = false },
        { url = "*.parquet", run = "duckdb", multi = false },
        { url = "*.xlsx",    run = "duckdb", multi = false },
      ]
    '';

    # fazif is keymap-driven and needs nothing in yazi.toml. `prepend_keymap`
    # is additive, so yazi's own bindings all survive. `b` is unbound by
    # default in the manager layer.
    "yazi/keymap.toml".text = ''
      [[mgr.prepend_keymap]]
      on = [ "b", "d" ]
      run = "plugin fazif faziffd"
      desc = "Find files/directories with fd and fzf"

      [[mgr.prepend_keymap]]
      on = [ "b", "r" ]
      run = "plugin fazif fazifrg"
      desc = "Find content in files with ripgrep and fzf"

      [[mgr.prepend_keymap]]
      on = [ "b", "a" ]
      run = "plugin fazif fazifrga"
      desc = "Find content in documents with ripgrep-all and fzf"
    '';
  };
}
