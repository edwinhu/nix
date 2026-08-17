{ lib, stdenv, fetchurl, makeBinaryWrapper }:

# Upstream's prebuilt x86_64-linux tarball rather than nixpkgs' source build.
# nixpkgs is pinned at 0.3.3, whose newClient leaves Client.document nil
# (fixed upstream in 54355ae6); aerc's text/html filter segfaulted on it.
# The release binaries are fully static, so no autoPatchelf is needed.
stdenv.mkDerivation (finalAttrs: {
  pname = "chawan";
  version = "0.4.4";

  src = fetchurl {
    url = "https://git.sr.ht/~bptato/chawan/refs/download/v${finalAttrs.version}/chawan-0-4-4-linux-amd64.tar.xz";
    hash = "sha256-p3cZzm/pXmTrdoKfNi6TK8vc2VrR/OBOEV3nzYmEL8c=";
  };

  nativeBuildInputs = [ makeBinaryWrapper ];

  # The tarball ships upstream's Makefile alongside the binaries; without this
  # the generic builder tries to compile from source and fails on pkg-config.
  dontConfigure = true;
  dontBuild = true;

  # Static ELFs: patchelf has nothing to rewrite and stripping risks breaking them.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    # cha locates its protocol handlers relative to $out/bin/../libexec,
    # so bin/ and libexec/ must stay siblings.
    mkdir -p $out
    cp -r target/release/bin target/release/libexec $out/

    for page in doc/*.[0-9]; do
      section=''${page##*.}
      install -Dm644 "$page" "$out/share/man/man$section/$(basename "$page")"
    done

    runHook postInstall
  '';

  postInstall = ''
    wrapProgram $out/bin/mancha --set MANCHA_CHA $out/bin/cha
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/cha --version | grep -q "v${finalAttrs.version}"
    runHook postInstallCheck
  '';

  meta = {
    description = "Lightweight and featureful terminal web browser";
    homepage = "https://sr.ht/~bptato/chawan/";
    changelog = "https://git.sr.ht/~bptato/chawan/refs/v${finalAttrs.version}";
    license = lib.licenses.unlicense;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cha";
  };
})
