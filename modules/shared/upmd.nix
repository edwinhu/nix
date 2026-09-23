{ pkgs }:

# upmd — runs the fenced code blocks of a Markdown file as named, dependency-
# ordered tasks, each in its own pty, beside the prose (runbooks). Not in
# nixpkgs; this takes upstream's cargo-dist release binary. The Linux build is
# glibc-dynamic, so autoPatchelfHook points it at the nix loader.

let
  inherit (pkgs) lib stdenvNoCC;
  version = "0.2.7";
  targets = {
    x86_64-linux = { triple = "x86_64-unknown-linux-gnu"; hash = "sha256-EBM216j0ZIo7+JTVY2h18d89IZcZ1HAJbFYuDPTWuao="; };
    aarch64-linux = { triple = "aarch64-unknown-linux-gnu"; hash = "sha256-ITx3pgLTNihQj96pzEuy5iOAMOV1KLdIylE39wVC56A="; };
    x86_64-darwin = { triple = "x86_64-apple-darwin"; hash = "sha256-PJ/TOVpP02Wi2u9MD1UHWanLDz8F9sfUS0VgQoaJ6UQ="; };
    aarch64-darwin = { triple = "aarch64-apple-darwin"; hash = "sha256-HpIBnGEUQudaLAHw06QNBpn8gDb4i+b8s1M+AIH8irc="; };
  };
  t = targets.${stdenvNoCC.hostPlatform.system}
    or (throw "upmd: unsupported platform ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "upmd";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/rezigned/upmd/releases/download/v${version}/upmd-${t.triple}.tar.xz";
    inherit (t) hash;
  };

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 upmd $out/bin/upmd
    runHook postInstall
  '';

  meta = {
    description = "Run tasks and workflows from Markdown";
    homepage = "https://github.com/rezigned/upmd";
    license = lib.licenses.mit;
    mainProgram = "upmd";
    platforms = builtins.attrNames targets;
  };
}
