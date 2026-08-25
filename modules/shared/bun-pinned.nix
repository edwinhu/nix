# bun, pinned ahead of nixpkgs.
#
# Two consumers, not one: mail-bridge builds against it (modules/shared/
# mail-bridge.nix), and modules/shared/packages.nix:18 instantiates it into
# `home.packages` — so this pin is also the interactive `bun` in every user
# profile on every host, Macs included. A bump moves both.
#
# Why: mail-bridge compiled by bun 1.3.13 runs IMAP `SEARCH TEXT` over the
# Gmail archive at 14.5 s (invoice) / 17.8 s (virginia). The identical source
# and database compiled by bun 1.3.14 answer the same two searches in 0.31 s /
# 0.38 s — a ~47x regression that lives in the embedded runtime, not in
# mail-bridge. A `bun build --compile` binary carries its own runtime, so the
# bun used at BUILD time is the bun that serves every query.
#
# Why an override and not a lock bump: nixpkgs has never carried 1.3.14. Both
# nixos-unstable and master are still on 1.3.13 (`bun: 1.3.11 -> 1.3.13`, Apr
# 2026); upstream shipped 1.3.14 on 2026-05-13. So no rev of nixpkgs fixes
# this, and a lock bump would move the whole host package set for nothing.
# Overriding version+src on nixpkgs' own bun derivation is the narrowest
# boundary that works: unpack, autoPatchelf, install and completions all stay
# upstream's, and every other package keeps stock bun.
#
# Bump procedure: change `version`, then re-hash each zip with
#   nix-prefetch-url --type sha256 \
#     https://github.com/oven-sh/bun/releases/download/bun-v$V/<name>.zip
# Never bump downwards past the floor mail-bridge asserts (`bunFloor` in
# modules/shared/mail-bridge.nix) — that floor is the authoritative one and it
# has risen since 1.3.14; read it there rather than trusting a number here.
#
# Retired at 1.4.0: `passthru.pristine`. Between 1.3.14 and 1.4, bun injected
# the compiled bundle into a `.bun` ELF SECTION of the template executable and
# chose the writable PT_LOAD segment to extend by TABLE ORDER, which is not the
# segment containing `.bun` once patchelf has rewritten the headers. Since bun
# defaults the template to ITSELF, and nixpkgs' bun is autopatchelf'd, the
# default path produced a 190 MB binary that segfaulted on every argv while the
# bundler exited 0. The workaround was a second derivation holding the SAME
# upstream binary unpacked but neither patchelf'd nor stripped, handed to
# `--compile-executable-path=`. 1.4 selects that segment by VADDR CONTAINMENT of
# the `.bun` section, so a patchelf'd template is fine and the pristine copy is
# no longer needed. (1.3.13 appended rather than injecting, which is why the
# recipe predating all of this survived.)
{
  lib,
  bun,
  fetchurl,
  stdenvNoCC,
}:

let
  version = "1.4.0";

  # Asset names match nixpkgs' own per-system choice, including the
  # x86_64-darwin baseline build.
  assets = {
    "aarch64-darwin" = {
      asset = "bun-darwin-aarch64";
      hash = "sha256-xmnpf2Fk4cluBwF0jbmN+ndJKQjL2DlMdVcTSnNd44E=";
    };
    "aarch64-linux" = {
      asset = "bun-linux-aarch64";
      hash = "sha256-SxozLuhhmD65O8/m93D/+U4+MbLDiL2uo8jtNeWO7Q4=";
    };
    "x86_64-darwin" = {
      asset = "bun-darwin-x64-baseline";
      hash = "sha256-2pufG0unZsbymXEfON+qmGI+HtnECJaqU9uAPFLsH6A=";
    };
    "x86_64-linux" = {
      asset = "bun-linux-x64";
      hash = "sha256-LQP7X7g6yLVnrKCigbLOGhoZ1Ij1bClo2Iw/Jekv5FI=";
    };
  };

  sources = lib.mapAttrs (
    _: a:
    fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/${a.asset}.zip";
      inherit (a) hash;
    }
  ) assets;

  system = stdenvNoCC.hostPlatform.system;
in
bun.overrideAttrs (prev: {
  inherit version;

  src = sources.${system} or (throw "bun-pinned: unsupported system ${system}");

  passthru = prev.passthru // { inherit sources; };

  # Cheap, decidable proof the override actually landed: without it a silently
  # ignored `version` would leave stock bun in place and the perf regression
  # would come straight back.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    got=$($out/bin/bun --revision 2>/dev/null || $out/bin/bun --version)
    case "$got" in
      ${version}*) echo "bun-pinned: $got" ;;
      *) echo "bun-pinned: expected ${version}, got '$got'" >&2; exit 1 ;;
    esac
    runHook postInstallCheck
  '';
})
