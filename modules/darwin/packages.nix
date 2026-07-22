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
  # Moonlight — client for the sunshine host on omarchy (hosts/linux/omarchy).
  # Ships a real Moonlight.app bundle, so it lands in /Applications/Nix Apps/
  # like the other GUI packages; `moonlight` is also on PATH. Add the host by
  # its Tailscale IP (100.122.125.84) — Moonlight's automatic discovery is mDNS,
  # which does not cross the tailnet.
  moonlight-qt
]
