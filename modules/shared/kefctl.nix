{ pkgs }:

# kefctl — TUI and CLI for KEF W2-platform speakers (LSX II, LS50 Wireless II,
# LS60 Wireless) over their HTTP JSON API, with mDNS discovery.
#
# Built from the GitHub tag: upstream publishes to the AUR and crates.io
# keywords but cuts no GitHub Releases, and fetchFromGitHub takes the
# auto-generated tag archive.
#
# No native dependencies to pin: reqwest is on rustls (via
# rustls-platform-verifier), not OpenSSL, and mdns-sd is pure Rust.

pkgs.rustPlatform.buildRustPackage rec {
  pname = "kefctl";
  version = "0.7.0";

  src = pkgs.fetchFromGitHub {
    owner = "douglas";
    repo = "kefctl";
    rev = "v${version}";
    hash = "sha256-kaGyNjrRh5Pl2jupXCUs+5y3oeUSijNfPmPD4e5kSVg=";
  };

  cargoHash = "sha256-pkNclIRg9ULyGErEhjMaDiiYK6zEOtXewiW/8xXDNi0=";

  # Omarchy 4 moved the theme. Upstream reads the Omarchy 3 layout, which does
  # not exist on this machine, so without this patch load_omarchy() returns None
  # and every panel falls back to the built-in ANSI defaults — themed only in
  # the sense that the terminal palette is.
  #
  # Two independent changes, both verified against
  # ~/.local/state/omarchy/current/theme/colors.toml on the Catppuccin theme:
  #
  #   - Path: ~/.config/omarchy/current/theme → ~/.local/state/omarchy/current/theme.
  #     The ~/.config symlink is simply gone after the quattro upgrade.
  #   - Keys: the quattro colors.toml has no color1/color2/color3/color8. It
  #     names them red/green/yellow/muted. `accent` and `foreground` kept their
  #     names, which is why a path-only fix would still leave every status
  #     colour on the ANSI fallback. The old keys stay as an or_else fallback so
  #     the derivation is still correct against an Omarchy 3 tree.
  postPatch = ''
    substituteInPlace src/ui/theme.rs \
      --replace-fail '".config/omarchy/current/theme/colors.toml"' \
                     '".local/state/omarchy/current/theme/colors.toml"' \
      --replace-fail 'get("color1")' 'get("red").or_else(|| get("color1"))' \
      --replace-fail 'get("color2")' 'get("green").or_else(|| get("color2"))' \
      --replace-fail 'get("color3")' 'get("yellow").or_else(|| get("color3"))' \
      --replace-fail 'get("color8")' 'get("muted").or_else(|| get("color8"))'
  '';

  meta = with pkgs.lib; {
    description = "TUI controller for KEF W2 speakers (LSX II, LS50 Wireless II, LS60 Wireless)";
    homepage = "https://github.com/douglas/kefctl";
    license = licenses.mit;
    mainProgram = "kefctl";
    platforms = platforms.unix;
  };
}
