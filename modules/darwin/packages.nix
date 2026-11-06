{ pkgs, profile ? "full" }:

with pkgs;
let
  shared-packages = import ../shared/packages.nix { inherit pkgs profile; };

  darwinLayers = {
  # macOS status bar, borders, dock management.
  # libreoffice-bin  # Moved to homebrew cask to reduce rsync time (783 MB app bundle)
  # aerospace  # Disabled: trying omniwm
  desktop = [
    dockutil
    jankyborders
    sketchybar
  ];

  # tmc/nlm — NotebookLM CLI + MCP server, built from upstream source.
  #
  # voxtype — dictation + meeting transcription (replaced the granola cask);
  # overlay package from modules/darwin/voxtype.nix.
  media = [ voxtype ];
};

inherit (import ../shared/profiles.nix) layersFor layerNames;
in
assert lib.assertMsg
  (lib.all (n: lib.elem n layerNames) (builtins.attrNames darwinLayers))
  "darwin/packages.nix: declares a layer that profiles.nix does not name";
shared-packages
++ lib.concatMap (name: darwinLayers.${name} or []) (layersFor profile)
