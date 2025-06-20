{ config, pkgs, lib, home-manager, homebrew-emacsmacport, catppuccin, ... }:

let
  user = "edwinhu";
in
{
  imports = [
   ./dock
  ];

  # It me
  users.users.${user} = {
    name = "${user}";
    home = "/Users/${user}";
    isHidden = false;
    shell = pkgs.zsh;
  };

  homebrew = {
    enable = true;
    casks = pkgs.callPackage ./casks.nix {};
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      #cleanup = "uninstall";
    };

    # These app IDs are from using the mas CLI app
    # mas = mac app store
    # https://github.com/mas-cli/mas
    #
    # $ nix shell nixpkgs#mas
    # $ mas search <app name>
    #
    # If you have previously added these apps to your Mac App Store profile (but not installed them on this system),
    # you may receive an error message "Redownload Unavailable with This Apple ID".
    # This message is safe to ignore. (https://github.com/dustinlyons/nixos-config/issues/83)

    # Nix is reinstalling these apps every time you run `darwin-rebuild switch`
    # https://github.com/nix-darwin/nix-darwin/issues/1323
    # run brew install mas to make sure you have > 2.0.0
    masApps = {
      "tailscale" = 1475387142;
      "microsoft to-do" = 1274495053;
      "amazon kindle" = 302584613;
      "microsoft word" = 462054704;
      "microsoft excel" = 462058435;
      "microsoft powerpoint" = 462062816;
    };
  };

  # Enable home-manager
  home-manager = {
    useGlobalPkgs = true;
    users.${user} = { pkgs, config, lib, ... }:{
      home = {
        stateVersion = "25.05"; # latest stable as of 20250527
        enableNixpkgsReleaseCheck = false;
        packages = pkgs.callPackage ./packages.nix {};
      };
      programs = {} // import ../shared/home-manager.nix { inherit config pkgs lib; };
    };
  };

  # Fully declarative dock using the latest from Nix Store
  local = { 
    dock = {
      enable = true;
      entries = [
        { path = "/Applications/WezTerm.app/"; }
        { path = "/Applications/Dia.app/"; }
        { path = "/Applications/Morgen.app/"; }
        { path = "/Applications/Visual Studio Code.app/"; }
        { path = "/Applications/Logseq.app/"; }
        { path = "/Applications/Obsidian.app/"; }
        { path = "/Applications/Bitwarden.app/"; }
        { path = "/Applications/Beeper Desktop.app/"; }
        {
          path = "${config.users.users.${user}.home}/Downloads";
          section = "others";
          options = "--sort dateadded --view grid --display stack";
        }
      ];
    };
  };
}
