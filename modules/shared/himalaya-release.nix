{ callPackage }:

callPackage ./pimalaya-release.nix {
  pname = "himalaya";
  version = "2.1.0";
  hashes = {
    aarch64-darwin = "sha256-paeHt8Tb8GVAjndykI/HXHmWJvTOurjpx4+v4+L6WFw=";
    aarch64-linux = "sha256-xBratLwiC6gWzb+GWl343Ds1iznsWLS+DtL2Tkax0YI=";
    x86_64-darwin = "sha256-DmFgRwnn6EtRQuvryFxS176zjwn/01BvrmBBJFw10qc=";
    x86_64-linux = "sha256-aDoquOFTTwHmvaOmniBNVkwx+/viBRH8e8YLZ/LoWIQ=";
  };
}
