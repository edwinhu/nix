# mail-bridge — the UVA Outlook mailbox, spoken as IMAP + sendmail(1).
# (gh:edwinhu/mail-bridge, PRIVATE; source via the mail-bridge-src flake input,
# SSH-fetched like nix-secrets/joycon-pad.)
#
# What it is: a loopback IMAP server on 127.0.0.1:1143 that translates IMAP to
# Outlook REST using the token held by the live Outlook Web tab, plus an
# `mail-bridge sendmail` shim for the send half. Native IMAP against that tenant
# is foreclosed (third-party OAuth consent is admin-gated), so this is what
# makes aerc and himalaya usable for work mail. See the omarchy host for the
# user service and both clients' configs.
#
# Built from source rather than a release asset, unlike obsidian-cli: there is
# no release CI here, and the flake input already pins a
# commit, so a build gives the same reproducibility without a manual upload
# step on every change. The cost is the two-derivation bun dance below.
{
  lib,
  stdenvNoCC,
  bun,
  src,
}:
let
  version = "0.10.10";

  # The floor is load-bearing twice over, and the second reason is CORRECTNESS,
  # not speed.
  #
  #   Performance: the bun that BUILDS this is the bun that RUNS it, since
  #   `--compile` embeds the runtime. 1.3.13 answers IMAP `SEARCH TEXT` over the
  #   Gmail archive in 14.5 s / 17.8 s; 1.3.14 answers the same searches against
  #   the same source and database in 0.31 s / 0.38 s.
  #
  #   Correctness: below 1.4, bun's default `--compile` template is ITSELF —
  #   i.e. nixpkgs' autopatchelf'd bun — and injecting the bundle into that
  #   yields a 190 MB binary that segfaults on every argv while the bundler
  #   exits 0. This package used to dodge that with an unpatched template
  #   (see buildPhase below); that workaround is gone, so a sub-1.4 bun
  #   would now silently produce the corrupt binary. See bun-pinned.nix.
  #
  # nixpkgs carries neither version at any rev, so the caller must pass
  # modules/shared/bun-pinned.nix. This floor is what makes that non-optional.
  bunFloor = "1.4.0";

  # Bun's resolver needs the network, which the build sandbox forbids — so the
  # dependency tree is its own fixed-output derivation, the standard shape for
  # any node/bun package. `--frozen-lockfile` makes bun.lock authoritative, so
  # the hash below only changes when that file does.
  #
  # HOME/BUN_INSTALL_CACHE_DIR: bun otherwise writes to a real $HOME, which
  # doesn't exist in the sandbox. --ignore-scripts: no postinstall may run,
  # since arbitrary scripts would break the fixed output's reproducibility.
  # `dependencies` is now {} — zero runtime deps — so this stays small.
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
assert lib.assertMsg (lib.versionAtLeast bun.version bunFloor) (
  "mail-bridge: bun ${bun.version} < ${bunFloor}. Pass "
  + "modules/shared/bun-pinned.nix as `bun`; stock nixpkgs bun makes IMAP "
  + "SEARCH ~47x slower (14.5s vs 0.31s on the Gmail archive), and below 1.4 "
  + "its default --compile template silently yields a segfaulting binary."
);
stdenvNoCC.mkDerivation {
  pname = "mail-bridge";
  inherit version src;

  nativeBuildInputs = [ bun ];

  dontConfigure = true;

  # `--compile` produces one ~95 MB self-contained binary with the bun runtime
  # embedded. It needs no network for the HOST triple (a cross `--target=` does
  # fetch that runtime from npm and would fail here), so the sandbox is fine —
  # which is also why this package is built per-system rather than cross-built.
  #
  # This used to pass a --compile-executable-path pointing at bun.pristine, an
  # unpatched copy of the same upstream bun. Not cross-compilation — a
  # workaround. Between 1.3.14 and 1.4, bun injected the bundle into a `.bun`
  # ELF SECTION of the template and picked the writable PT_LOAD segment to
  # extend by table order, which patchelf's header rewrite invalidates; since
  # the template defaults to bun ITSELF, and nixpkgs' bun is autopatchelf'd, the
  # default produced a 190 MB binary that segfaulted on every argv while the
  # bundler exited 0. 1.4 picks that segment by vaddr containment of `.bun`, so
  # the default self-template is correct again and the workaround is retired
  # (`bunFloor` above is what keeps a sub-1.4 bun from reviving the bug).
  #
  # Consequence worth naming: the artifact now inherits the patchelf'd
  # template's interpreter, i.e. a /nix/store loader rather than /lib64. That is
  # normal for nix-built software — and it is what lets installCheck below
  # actually RUN the binary inside the sandbox.
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

  # The eval assert above constrains the bun DERIVATION; these constrain the
  # ARTIFACT.
  #
  #   1. `Bun/<version>` grepped out of the file is the runtime stamp -- proves
  #      which bun got embedded.
  #   2. Running `archive doctor`. This is the one that matters: the failure
  #      mode being guarded is a bundler that exits 0 having written a binary
  #      that segfaults on every argv, and NOTHING that merely reads the file
  #      distinguishes that from a sound one. Only execution does.
  #
  # There used to be a third check asserting a non-/nix/store ELF interpreter,
  # as a proxy for "the pristine template was used". It is deleted, not
  # inverted: the interpreter identifies which template compiled the binary,
  # never whether the binary works, so an assertion in either polarity is a
  # proxy that can pass over a broken artifact.
  #
  # Executing here is possible precisely BECAUSE the workaround is gone. With
  # the pristine template the artifact's interpreter was the host's /lib64
  # loader, absent from the sandbox; inheriting the patchelf'd bun's /nix/store
  # loader makes the binary runnable inside the build.
  #
  # `archive doctor` is chosen for being read-only and needing no account, no
  # network and no state: it reports on the archive database, creating one under
  # $HOME if absent, and exits non-zero on a broken runtime.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    embedded=$(grep -a -o -m1 -E 'Bun/[0-9]+\.[0-9]+\.[0-9]+' $out/bin/mail-bridge | head -n1)
    echo "mail-bridge: runtime $embedded (bun ${bun.version}, floor ${bunFloor})"
    if [ "$embedded" != "Bun/${bun.version}" ]; then
      echo "mail-bridge: embedded runtime $embedded != Bun/${bun.version}" >&2
      exit 1
    fi

    size=$(stat -c%s $out/bin/mail-bridge 2>/dev/null || stat -f%z $out/bin/mail-bridge)
    echo "mail-bridge: artifact $size bytes"
    if [ "$size" -gt 150000000 ]; then
      echo "mail-bridge: $size bytes -- a sound artifact is ~82 MB, the" >&2
      echo "segment-selection corruption produces ~190 MB." >&2
      exit 1
    fi

    export HOME=$TMPDIR
    if ! $out/bin/mail-bridge archive doctor; then
      echo "mail-bridge: the built binary could not run \`archive doctor\`" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Outlook mailbox served as loopback IMAP + a sendmail(1) shim";
    homepage = "https://github.com/edwinhu/mail-bridge";
    license = lib.licenses.unfree; # private repo, no declared license
    mainProgram = "mail-bridge";
    platforms = lib.platforms.unix;
  };
}
