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
  patchelf,
  src,
}:
let
  version = "0.10.7";

  # The bun that BUILDS this is the bun that RUNS it: `--compile` embeds the
  # runtime in the binary. 1.3.13 answers IMAP `SEARCH TEXT` over the Gmail
  # archive in 14.5 s / 17.8 s; 1.3.14 answers the same searches against the
  # same source and database in 0.31 s / 0.38 s. nixpkgs is still on 1.3.13 at
  # every rev, so the caller must pass modules/shared/bun-pinned.nix. This
  # floor is what makes that non-optional.
  bunFloor = "1.3.14";

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
assert lib.assertMsg (lib.versionAtLeast bun.version bunFloor) (
  "mail-bridge: bun ${bun.version} < ${bunFloor}. Pass "
  + "modules/shared/bun-pinned.nix as `bun`; stock nixpkgs bun makes IMAP "
  + "SEARCH ~47x slower (14.5s vs 0.31s on the Gmail archive)."
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
  # --compile-executable-path is NOT cross-compilation here, it is a workaround.
  # Since 1.3.14 bun injects the bundle into a `.bun` ELF SECTION of the
  # template executable, and it defaults the template to ITSELF — i.e. to
  # nixpkgs' bun, which autoPatchelfHook has rewritten. That write then
  # miscomputes: the output is 190 MB instead of 95 MB and segfaults on every
  # argv, silently (the bundler exits 0). Pointing it at the unpatched upstream
  # binary restores the normal output byte-for-byte. See bun-pinned.nix.
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    export BUN_INSTALL_CACHE_DIR=$TMPDIR/cache
    ln -s ${nodeModules} node_modules
    bun build --compile \
      --compile-executable-path=${bun.pristine}/bin/bun \
      src/cli.ts --outfile mail-bridge
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
  # ARTIFACT. The binary cannot be executed here (its interpreter is the host's
  # /lib64 loader, absent from the sandbox), so both checks read the ELF.
  #
  #   1. `Bun/<version>` is the runtime stamp -- proves which bun got embedded.
  #   2. A non-/nix/store interpreter proves the PRISTINE template was used.
  #      A patchelf'd template leaves a /nix/store interpreter and, with it,
  #      the 190 MB segfaulting binary that the bundler reports as a success.
  #
  # Together they turn both silent failure modes into build failures.
  # Check 2 is ELF-only; a Mach-O output has no interpreter to read.
  nativeInstallCheckInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ patchelf ];
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    embedded=$(grep -a -o -m1 -E 'Bun/[0-9]+\.[0-9]+\.[0-9]+' $out/bin/mail-bridge | head -n1)
    echo "mail-bridge: runtime $embedded (bun ${bun.version}, floor ${bunFloor})"
    if [ "$embedded" != "Bun/${bun.version}" ]; then
      echo "mail-bridge: embedded runtime $embedded != Bun/${bun.version}" >&2
      exit 1
    fi
  ''
  + lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
    interp=$(patchelf --print-interpreter $out/bin/mail-bridge)
    echo "mail-bridge: interpreter $interp"
    case "$interp" in
      /nix/store/*)
        echo "mail-bridge: interpreter $interp is a nix path -- the --compile" >&2
        echo "template was the patchelf'd bun, so this binary is corrupt." >&2
        exit 1
        ;;
    esac
  ''
  + ''
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
