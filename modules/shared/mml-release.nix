{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "mml";
  version = "1.1.1";
  hashes = {
    aarch64-darwin = "sha256-7g0ocfyQ6K3uxCRHH/itDbSDj6Lw6/xTP46VoTraZ0c=";
    aarch64-linux = "sha256-BPaNgWzB7beSkuVhRK4SqdLyGwLNWFYE9FuXM8l1lvY=";
    x86_64-darwin = "sha256-Afy4iZPLn5nY0YE1kHQbgS4XySAccF5/4lfZbE2BwFo=";
    x86_64-linux = "sha256-Zz4hx4t7y1oUQtOVTCnnRNdyham3pQDD6N7xo2jZv3k=";
  };
}
