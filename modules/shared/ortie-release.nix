{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "ortie";
  version = "2.3.0";
  hashes = {
    aarch64-darwin = "sha256-8DopAXaE067g4WByPOc8VmfUq/nuRCeKww5XZZGfP6c=";
    aarch64-linux = "sha256-8SSEFkYp/m/D+MWaGYnkjx0FuX7L/+fCuz7jProgk04=";
    x86_64-darwin = "sha256-Z2HF8Vn6dLr9HNFnTnzsr0ePWOVWuIlGNOM2j6IMrvM=";
    x86_64-linux = "sha256-G0IfKMsrx+as/pZN9UjVaN26s1m8eRxD5cT3sJGRDxA=";
  };
}
