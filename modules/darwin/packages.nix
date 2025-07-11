{ pkgs }:

with pkgs;
let shared-packages = import ../shared/packages.nix { inherit pkgs; }; in
shared-packages ++ [
  aerospace
  dockutil
  ((emacsPackagesFor emacs-macport).emacsWithPackages (epkgs: [ epkgs.vterm ])) 
  jankyborders
  sketchybar  
]