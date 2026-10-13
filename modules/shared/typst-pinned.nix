# typst and tinymist pinned to the 0.14 line from upstream release binaries.
#
# typst 0.15.0 roughly doubles compile memory (typst/typst#8611). tinymist embeds its
# own typst, so it is pinned to v0.14.20, the last stable release on typst 0.14.2;
# pinning the CLI alone leaves previews on 0.15. Unpin both once #8611 ships.
{ lib, stdenvNoCC, fetchurl }:

let
  system = stdenvNoCC.hostPlatform.system;

  targets = {
    x86_64-linux = "x86_64-unknown-linux-musl";
    aarch64-linux = "aarch64-unknown-linux-musl";
    aarch64-darwin = "aarch64-apple-darwin";
    x86_64-darwin = "x86_64-apple-darwin";
  };
  target = targets.${system} or (throw "typst-pinned: unsupported platform ${system}");

  release = { pname, version, url, ext, hashes, homepage, license }:
    stdenvNoCC.mkDerivation {
      inherit pname version;
      src = fetchurl {
        url = "${url}/v${version}/${pname}-${target}.${ext}";
        hash = hashes.${system};
      };
      sourceRoot = "${pname}-${target}";
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 ${pname} $out/bin/${pname}
        runHook postInstall
      '';
      meta = {
        inherit homepage license;
        mainProgram = pname;
        platforms = builtins.attrNames targets;
      };
    };
in
{
  typst = release {
    pname = "typst";
    version = "0.14.2";
    url = "https://github.com/typst/typst/releases/download";
    ext = "tar.xz";
    homepage = "https://typst.app";
    license = lib.licenses.asl20;
    hashes = {
      x86_64-linux = "sha256-pgRMutKpVN65IRZ+JX4SCsChayAznsARIRlP+dOUmW0=";
      aarch64-linux = "sha256-SRsQGqQKOn6oKj+KYjLKu05qfiM4EAguWsgS1D/c1Ho=";
      aarch64-darwin = "sha256-RwqkmiKY0gtlwRmhDk/4gIVQRT4MtNhWJbicrwzt8Eg=";
      x86_64-darwin = "sha256-TpHY4eM6sWT5ScV2LgHuP6pYXIYVoqa9XjZ3+oUGskk=";
    };
  };

  tinymist = release {
    pname = "tinymist";
    version = "0.14.20";
    url = "https://github.com/Myriad-Dreamin/tinymist/releases/download";
    ext = "tar.gz";
    homepage = "https://github.com/Myriad-Dreamin/tinymist";
    license = lib.licenses.asl20;
    hashes = {
      x86_64-linux = "sha256-DDqQIrLx5qTxGqGjQ1wyTJ+J0bdwZc8XO8VG3V6ppaI=";
      aarch64-linux = "sha256-ndfRQROzE8OAnQMWCTPIYNQiFkAioulSw1x8reu95zs=";
      aarch64-darwin = "sha256-MyFUyKdwX/o25lZxscROvyfZ+g2103umYC2dM0Mv5fc=";
      x86_64-darwin = "sha256-FRY+VH52t0IL/8QrjABsZDHZZIpJplicpByRnitODhE=";
    };
  };
}
