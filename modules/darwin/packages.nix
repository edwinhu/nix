{ pkgs }:

with pkgs;
let 
  shared-packages = import ../shared/packages.nix { inherit pkgs; };
  wezterm-cli = pkgs.writeShellScriptBin "wezterm" ''
    exec /Applications/WezTerm.app/Contents/MacOS/wezterm "$@"
  '';
in
shared-packages ++ [
  aerospace
  dockutil
  ((emacsPackagesFor emacs-macport).emacsWithPackages (epkgs: [ epkgs.vterm ])) 
  ffmpeg-full
  jankyborders
  sketchybar
  wezterm-cli
]
