# Source build for a pimalaya tool that ships its own package.nix.
#
# Upstream leaves `src` and `cargoHash` blank in package.nix (their default.nix
# fills them from the checkout), so both are supplied here: `src` is the pinned
# flake input, `cargoHash` is recorded by the caller. buildRustPackage reads
# cargoHash from its own arguments rather than from finalAttrs, so it cannot be
# patched in with overrideAttrs afterwards — hence the rustPlatform shim.
{ callPackage, rustPlatform, src, cargoHash, buildFeatures ? [ ] }:

callPackage "${src}/package.nix" {
  inherit buildFeatures;
  rustPlatform = rustPlatform // {
    buildRustPackage = f: rustPlatform.buildRustPackage (finalAttrs:
      let attrs = f finalAttrs; in
      attrs // {
        inherit src cargoHash;
        # upstream's meta.changelog reads src.tag, which a store-path src lacks
        meta = attrs.meta // { changelog = attrs.meta.homepage; };
      });
  };
}
