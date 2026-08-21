# bun, pinned ahead of nixpkgs — for mail-bridge only.
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
# Keep >= 1.3.14; mail-bridge asserts that floor.
#
# passthru.pristine: the SAME upstream binary, unpacked but NOT autopatchelf'd
# and NOT stripped. It is never executed -- it exists to be handed to
# `bun build --compile --compile-executable-path=`, because 1.3.14 injects the
# bundle into a `.bun` ELF SECTION of the template executable and that write is
# corrupted by patchelf's rewrite: a patchelf'd template yields a 190 MB binary
# that segfaults on any argv, while the pristine template yields the normal
# 95 MB one. (1.3.13 appended instead, which is why the old recipe survived.)
{
  lib,
  bun,
  fetchurl,
  stdenvNoCC,
  unzip,
}:

let
  version = "1.3.14";

  # Asset names match nixpkgs' own per-system choice, including the
  # x86_64-darwin baseline build.
  assets = {
    "aarch64-darwin" = {
      asset = "bun-darwin-aarch64";
      hash = "sha256-2LliIYKK1vl6x6wKt+lYcjQa92MAHogD6CZ2UsJlJiA=";
    };
    "aarch64-linux" = {
      asset = "bun-linux-aarch64";
      hash = "sha256-on/7Y6gxA3WDbg1vZorhf6jY0YuIw3yCHGUzGXOhmjs=";
    };
    "x86_64-darwin" = {
      asset = "bun-darwin-x64-baseline";
      hash = "sha256-PjWtb1OXGpg0v55nhuKt9ytfGSHMmpxf3gc9KXKUQHY=";
    };
    "x86_64-linux" = {
      asset = "bun-linux-x64";
      hash = "sha256-lR7iruhV8IWVruxiJSJqKY0/6oOj3NZGXAnLzN9+hI8=";
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

  # Unpack only. No autoPatchelfHook, no strip, no fixup that touches the ELF:
  # every byte must stay where upstream put it or `.bun` section injection
  # miscomputes. Not runnable inside the build sandbox (its interpreter is the
  # host's /lib64 loader) and it does not need to be -- it is read, not run.
  pristine = stdenvNoCC.mkDerivation {
    pname = "bun-pristine";
    inherit version;
    src = sources.${system} or (throw "bun-pinned: unsupported system ${system}");

    nativeBuildInputs = [ unzip ];
    dontConfigure = true;
    dontBuild = true;
    dontPatchELF = true;
    dontStrip = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 ./bun $out/bin/bun
      runHook postInstall
    '';

    meta = bun.meta // {
      description = "Upstream bun ${version}, unpatched — a --compile template only";
    };
  };
in
bun.overrideAttrs (prev: {
  inherit version;

  src = sources.${system} or (throw "bun-pinned: unsupported system ${system}");

  passthru = prev.passthru // { inherit sources pristine; };

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
