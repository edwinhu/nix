{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "cardamum";
  version = "0.3.0";
  hashes = {
    aarch64-darwin = "sha256-VrfKMoAhcLW4Z0tG9kYPILcdwStUwgMrtGUzuS67Hww=";
    aarch64-linux = "sha256-8lS/y1BtJaR0dlYhjn1pQKEFn1mh4nyeGs5XUH/8NYE=";
    x86_64-darwin = "sha256-sRbzeRx1DfF9fnKDTIwtkXALEr7g+F7yrHjT5AvTegs=";
    x86_64-linux = "sha256-n5EygdEwy5gqRYAwiSpr0RSKboD4wKnkUpX6kL+HT1c=";
  };
}
