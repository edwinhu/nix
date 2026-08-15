{ self, config, pkgs, lib, user, userInfo, agenix, ... }:

{
  imports = [
    ../shared/stylix.nix
    # Faithful docx->PDF via real Word in a QEMU Win11 x64 + KVM guest.
    # Imported so the options exist; enable per host once the guest is stood up:
    #   programs.wordRender.enable = true;  (see ../shared/word-render/README.md)
    ../shared/word-render.nix
    # herdr's agent skill, from the same flake input as the binary.
    ../shared/herdr-skill.nix
  ];

  # Linux-specific Stylix configuration (Qt theming)
  stylix.targets.qt = {
    enable = true;
    platform = "qtct";
  };

  # Linux-specific configurations
  home = {
    username = user;
    homeDirectory = "/home/${user}";
    
    # Linux-specific packages
    packages = with pkgs; [
      # Add Linux-specific packages here
      xdg-utils
      inotify-tools
      imagemagick
      # libreoffice removed 2026-06-10: Word Quartz handles docx rendering; shared
      # packages keep only the lightweight x2t converter.
      agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
      # Qt configuration tools for Stylix
      libsForQt5.qt5ct
      kdePackages.qt6ct
      libsForQt5.qtstyleplugin-kvantum
      kdePackages.qtstyleplugin-kvantum
    ] ++ (import ../shared/packages.nix { inherit pkgs; });
    
    sessionVariables = {
      # Add Linux-specific environment variables
      SHELL = "${pkgs.zsh}/bin/zsh";
      EDITOR = "nvim";
      VISUAL = "nvim";
      ALTERNATE_EDITOR = "";
    };

    # rv (R package manager) is now a real derivation — modules/shared/rv.nix,
    # wired through the overlay in flake.nix and listed in shared/packages.nix.
    # (It used to be an activation script that curl-piped an installer URL that
    # upstream deleted, failing silently.)

    # Idempotent bootstrap for the AI CLIs: writes mise stubs into ~/.local/bin.
    # Each stub re-resolves its tool on run, so this never pins a version;
    # `nix run ~/nix#update-ai-tools` forces a bump past mise's release
    # cooldown. mise must be on PATH explicitly — the activation PATH doesn't
    # include the nix profile.
    # AI_TOOLS_SKIP drops tools this host has no use for from the default set
    # (declared as userInfo.aiToolsSkip in flake.nix).
    activation.installAITools = lib.hm.dag.entryAfter ["writeBoundary"] ''
      $DRY_RUN_CMD env \
        PATH="$HOME/.local/bin:$HOME/.bun/bin:${pkgs.mise}/bin:${pkgs.curl}/bin:${pkgs.coreutils}/bin:/usr/bin:/bin" \
        AI_TOOLS_SKIP="${lib.concatStringsSep " " (userInfo.aiToolsSkip or [])}" \
        ${pkgs.bash}/bin/bash ${self}/scripts/setup-ai-tools.sh || true
    '';
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable fonts for Linux
  fonts.fontconfig.enable = true;

  # Program configurations - shell config managed by dotfiles
  programs = import ../shared/home-manager.nix { inherit config pkgs lib user userInfo; };

  # Linux-specific services
  services = {
    # Syncthing - continuous file synchronization
    syncthing = {
      enable = true;
      tray.enable = false;  # No system tray on headless systems
    };
  };
}
