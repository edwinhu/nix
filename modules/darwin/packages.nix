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
  # Option 1: railwaycat emacs-macport with packages
  # ((emacsPackagesFor emacs-macport).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  # Option 2: emacs with native compilation + vterm (back to working config)
  ((emacsPackagesFor emacs-unstable).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  ffmpeg-full
  jankyborders
  sketchybar
  wezterm-cli
]
