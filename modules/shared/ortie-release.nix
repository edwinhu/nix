{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "ortie";
  version = "2.1.0";
  hashes = {
    aarch64-darwin = "sha256-MfL8HAxQRr4XcUlELZW74zmrrgY06X0w5O8T4N041k4=";
    aarch64-linux = "sha256-yj/VZdWp01jqDvgxo0R6EFGiCFe3WRFfSZmjRsixuOU=";
    x86_64-darwin = "sha256-hZVjJLjRvDhv8T+1k37SBmm3WevMtqk4onX0idFRtjE=";
    x86_64-linux = "sha256-t1UtYNWU0JpBD+hpcy+uWMIDg2hTqBXcQ5HPAQnDpfg=";
  };
}
