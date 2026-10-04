{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "himalaya";
  version = "2.2.1";
  hashes = {
    aarch64-darwin = "sha256-pdl6H3u8pF5Yvd3j+fFzJfYUyc1tXxf6vzjdywMIaas=";
    aarch64-linux = "sha256-HcIcPdbZSJKeIuXK5JudCzsw/4j6/UST/URgxiUunZA=";
    x86_64-darwin = "sha256-JOImvGvM/q3IlgiVP/wPy0ZiPR1M1GiXNMus4kPMjS4=";
    x86_64-linux = "sha256-XFuickwWL4LQoMcbbAMiTtRPi+97FKzl2gY1068mZaA=";
  };
}
