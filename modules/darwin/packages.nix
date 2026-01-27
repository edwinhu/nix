{ pkgs }:

with pkgs;
let
  shared-packages = import ../shared/packages.nix { inherit pkgs; };
in
shared-packages ++ [
  libreoffice-bin  # Headless spreadsheet recalculation via soffice
  aerospace
  dockutil
  # Option 1: railwaycat emacs-macport (current)
  ((emacsPackagesFor emacs-macport).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  # Option 2: emacs with native compilation
  # ((emacsPackagesFor emacs-unstable).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  jankyborders
  sketchybar
  zathuraApp
]
