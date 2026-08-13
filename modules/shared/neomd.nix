# neomd — keyboard-first TUI email: compose in Neovim, render as Markdown.
# (gh:ssp-data/neomd)
#
# PREBUILT RELEASE TARBALL, not buildGoModule, and deliberately. Building from
# source needs a `vendorHash` that has to be recomputed on every bump, and that
# exact class of hash-pinning broke this config twice in one day (himalaya's
# cargoHash, mail-bridge's node-modules outputHash). One `sha256` and no vendor
# step is the cheaper contract. Same shape as omniwm/tsui/codex-native here, and
# the same thing the AUR's `neomd-bin` does.
#
# NOTE the release lag: v0.8.7 is 2026-07-20 while master moved 2026-08-07, so
# this is a few weeks behind the README's newest features. Bump the version and
# the hash together; `nix-prefetch-url --type sha256 <url>` prints the new one.
{ lib, stdenv, fetchurl, autoPatchelfHook, makeWrapper }:

let
  version = "0.8.7";
  # Only the two Linux arches are wired: this config's Linux hosts are x86_64,
  # and aarch64 is here so a future box needs a hash, not a rewrite.
  sources = {
    x86_64-linux = {
      url = "https://github.com/ssp-data/neomd/releases/download/v${version}/neomd_${version}_linux_amd64.tar.gz";
      sha256 = "12kpi3m8piaxscrq2bdz175pykval9ghzlay6r3jmss87k79mgq9";
    };
  };
  src = sources.${stdenv.hostPlatform.system}
    or (throw "neomd: no prebuilt release wired for ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "neomd";
  inherit version;

  src = fetchurl { inherit (src) url sha256; };

  # The tarball is a flat archive (the binary at its root), so there is no
  # single top-level directory for the default unpack phase to cd into.
  sourceRoot = ".";

  # A Go binary is static apart from the dynamic loader, which autoPatchelf
  # points at this system's.
  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 neomd $out/bin/neomd

    # The Personal account sends through Gmail SMTP directly (the bridge's
    # submission path is Graph-only), so it needs the same app password aerc
    # uses. neomd expands `password = "$VAR"` at startup, so the secret is read
    # from the agenix runtime file HERE rather than being written into the
    # config -- the config is world-readable in the nix store, the secret is not.
    wrapProgram $out/bin/neomd \
      --run 'export NEOMD_GMAIL_PASS="$(cat "$XDG_RUNTIME_DIR/agenix/aerc-gmail-app-password" 2>/dev/null)"'
    runHook postInstall
  '';

  meta = with lib; {
    description = "Keyboard-first TUI email: write in Neovim, render as Markdown, screen senders first";
    homepage = "https://github.com/ssp-data/neomd";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "neomd";
  };
}
