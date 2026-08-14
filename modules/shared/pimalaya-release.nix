{ lib, stdenvNoCC, fetchurl, pname, version, hashes }:

let
  system = stdenvNoCC.hostPlatform.system;
  hash = hashes.${system} or
    (throw "${pname}: unsupported platform ${system}");
in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src = fetchurl {
    url = "https://github.com/pimalaya/${pname}/releases/download/v${version}/${pname}.${system}.tgz";
    inherit hash;
  };

  unpackPhase = ''
    runHook preUnpack
    mkdir source
    cd source
    tar -xzf $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${pname} $out/bin/${pname}
    cp -r share $out/share
    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/pimalaya/${pname}";
    license = lib.licenses.mpl20;
    mainProgram = pname;
    platforms = builtins.attrNames hashes;
  };
}
