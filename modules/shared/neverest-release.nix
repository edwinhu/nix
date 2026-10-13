{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "neverest";
  version = "0.3.0";
  hashes = {
    aarch64-darwin = "sha256-bgjlW3/Jk8BTYyOZkl3M3g462pwj/zaaSlwdaCk5gtY=";
    aarch64-linux = "sha256-Yjt/IicYYefud738PXCcyHBEbqLjuMExIptwtOzfwDY=";
    x86_64-darwin = "sha256-W2lwhuR3S+up9uLQiMKE7NXkIj1AAc8e+EakyamV75E=";
    x86_64-linux = "sha256-819kOz2C4l3WBrCXf4lKSVuYhlTA8OAlOKGbaXiZYNk=";
  };
}
