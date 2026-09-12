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
  # Moonlight — client for the sunshine host on omarchy (hosts/linux/omarchy).
  # Ships a real Moonlight.app bundle, so it lands in /Applications/Nix Apps/
  # like the other GUI packages; `moonlight` is also on PATH. Add the host by
  # its Tailscale IP (100.122.125.84) — Moonlight's automatic discovery is mDNS,
  # which does not cross the tailnet.
  media = [ moonlight-qt ];
};

inherit (import ../shared/profiles.nix) layersFor layerNames;
in
assert lib.assertMsg
  (lib.all (n: lib.elem n layerNames) (builtins.attrNames darwinLayers))
  "darwin/packages.nix: declares a layer that profiles.nix does not name";
shared-packages
++ lib.concatMap (name: darwinLayers.${name} or []) (layersFor profile)
