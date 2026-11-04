{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "carillon";
  version = "0.2.0";
  hashes = {
    aarch64-darwin = "sha256-pSztrGGyJXav4i2JcMJKM20FWGfPfXQSFWzblies8r8=";
    aarch64-linux = "sha256-Faxu4t9G0Y320s5ON4LjSxczzHTHL8MrC8FN7KD6634=";
    x86_64-darwin = "sha256-/Xm/aMdsjuyH4T20JnXI0UsrFTeuyO2m11Wklf7s/C8=";
    x86_64-linux = "sha256-pO3qf9x586BGG0owFLMfaNbs380cZAr+96aUhwCz1sU=";
  };
}
