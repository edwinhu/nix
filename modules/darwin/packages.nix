{ pkgs }:

with pkgs;
let
  shared-packages = import ../shared/packages.nix { inherit pkgs; };
in
shared-packages ++ [
  # libreoffice-bin  # Moved to homebrew cask to reduce rsync time (783 MB app bundle)
  # aerospace  # Disabled: trying omniwm
  dockutil
  jankyborders
  sketchybar
  # tmc/nlm — NotebookLM CLI + MCP server, built from upstream source.
  (import ./nlm.nix { inherit pkgs; })
]
