{ pkgs }:

with pkgs;
let
  shared-packages = import ../shared/packages.nix { inherit pkgs; };
in
shared-packages ++ [
  # libreoffice-bin  # Moved to homebrew cask to reduce rsync time (783 MB app bundle)
  # aerospace  # Disabled: trying omniwm
  dockutil
  # Option 1: railwaycat emacs-macport (current)
  ((emacsPackagesFor emacs-macport).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  # Option 2: emacs with native compilation
  # ((emacsPackagesFor emacs-unstable).emacsWithPackages (epkgs: [ epkgs.vterm ]))
  # jankyborders  # Replaced by omniwm
  sketchybar
  zathuraApp
]
