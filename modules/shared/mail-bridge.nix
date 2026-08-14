# mail-bridge — the UVA Outlook mailbox, spoken as IMAP + sendmail(1).
# (gh:edwinhu/mail-bridge, PRIVATE; source via the mail-bridge-src flake input,
# SSH-fetched like nix-secrets/swlinux.)
#
# What it is: a loopback IMAP server on 127.0.0.1:1143 that translates IMAP to
# Outlook REST using the token held by the live Outlook Web tab, plus an
# `mail-bridge sendmail` shim for the send half. Native IMAP against that tenant
# is foreclosed (third-party OAuth consent is admin-gated), so this is what
# makes aerc and himalaya usable for work mail. See the omarchy host for the
# user service and both clients' configs.
#
# Built from source rather than a release asset, unlike superhuman-cli and
# obsidian-cli: there is no release CI here, and the flake input already pins a
# commit, so a build gives the same reproducibility without a manual upload
# step on every change. The cost is the two-derivation bun dance below.
{
  lib,
  stdenvNoCC,
  bun,
  src,
}:
let
  version = "0.3.0";

  # Bun's resolver needs the network, which the build sandbox forbids — so the
  # dependency tree is its own fixed-output derivation, the standard shape for
  # any node/bun package. `--frozen-lockfile` makes bun.lock authoritative, so
  # the hash below only changes when that file does.
  #
  # HOME/BUN_INSTALL_CACHE_DIR: bun otherwise writes to a real $HOME, which
  # doesn't exist in the sandbox. --ignore-scripts: no postinstall may run,
  # since arbitrary scripts would break the fixed output's reproducibility.
  # Only one runtime dep (chrome-remote-interface), so this stays small.
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "mail-bridge-node-modules";
    inherit version src;

    nativeBuildInputs = [ bun ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/cache
      bun install --production --frozen-lockfile --ignore-scripts --no-progress
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R node_modules/. $out/
      runHook postInstall
    '';

    dontFixup = true;

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-ZjhL+bTDuilt0no0fi/3hNU9uCZHRcrXp6HTUrtoo5w=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "mail-bridge";
  inherit version src;

  nativeBuildInputs = [ bun ];

  dontConfigure = true;

  # `--compile` produces one ~100 MB self-contained binary with the bun runtime
  # embedded. It needs no network for the HOST triple (a cross `--target=` does
  # fetch that runtime from npm and would fail here), so the sandbox is fine —
  # which is also why this package is built per-system rather than cross-built.
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export BUN_INSTALL_CACHE_DIR=$TMPDIR/cache
    ln -s ${nodeModules} node_modules
    bun build --compile src/cli.ts --outfile mail-bridge
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 mail-bridge $out/bin/mail-bridge
    runHook postInstall
  '';

  # A --compile'd bun binary embeds its own runtime; stripping corrupts the
  # appended bundle, and on this FHS host the ELF needs no patching either.
  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Outlook mailbox served as loopback IMAP + a sendmail(1) shim";
    homepage = "https://github.com/edwinhu/mail-bridge";
    license = lib.licenses.unfree; # private repo, no declared license
    mainProgram = "mail-bridge";
    platforms = lib.platforms.unix;
  };
}
